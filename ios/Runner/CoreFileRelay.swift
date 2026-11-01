import Flutter
import Foundation

/// Carries core calls to the tunnel extension as files in the App Group.
///
/// `sendProviderMessage` is the documented way to reach the packet-tunnel
/// provider, and this app used it for every core call. On the tested device it
/// never delivered anything: each call came back empty within milliseconds --
/// which Apple documents as "the system wasn't able to pass the message" -- and
/// the extension's own startup log, which records every step it takes, held not
/// one line about a call arriving. A tunnel whose core had just reported itself
/// live was therefore unreachable from the app, and every profile operation
/// failed with "Core did not answer ...".
///
/// The App Group container has no such problem: both processes already append to
/// the same log file inside it, and the core boots from the config the app wrote
/// there. So a call travels the same way: `ipc/req-<id>.json` for the extension,
/// `ipc/res-<id>.json` back. One timer polls for the answers of the calls that
/// are outstanding, so no thread is ever parked on a slow call.
final class CoreFileRelay {

    static let shared = CoreFileRelay()

    /// How often outstanding calls are checked. The extension answers in
    /// milliseconds once its core is live, so this only bounds the latency.
    private static let pollInterval: TimeInterval = 0.02

    /// How long a call waits before it is reported as unanswered. A tunnel that
    /// is up has a live core within seconds, and a call nobody picks up should
    /// fail while the user is still looking at the screen rather than after a
    /// minute.
    private static let timeout: TimeInterval = 25

    /// Extra time granted once the extension says it has the call in hand. It
    /// may still be waiting for QuickSetup to compile a first rule set, which
    /// takes tens of seconds on an older device -- and that wait is exactly the
    /// one the base timeout above must not be stretched to cover.
    private static let acknowledgedGrace: TimeInterval = 90

    private struct Pending {
        let method: String
        let started: Date
        var deadline: Date
        let requestURL: URL
        let responseURL: URL
        let acknowledgementURL: URL
        var acknowledged: Bool
        let result: FlutterResult
    }

    private let queue = DispatchQueue(label: "com.follow.clash.corefiles")
    private var pending: [String: Pending] = [:]
    private var timer: DispatchSourceTimer?

    /// How many times each method has been written to the log. Traffic and
    /// connection polls run once a second, so logging every call would push the
    /// tunnel's startup steps out of the log's 48KB window within minutes. The
    /// first calls of a method are recorded, and after that only the slow ones.
    private var logged: [String: Int] = [:]

    private static let logEveryMethod = 3
    private static let slowCall: TimeInterval = 2

    private init() {}

    /// Writes one call into [directory] and arranges for [result] to be called
    /// with the extension's answer, or with nil when none arrives.
    func send(_ payload: String, directory: URL, result: @escaping FlutterResult) {
        queue.async {
            let id = UUID().uuidString
            let requestURL = directory.appendingPathComponent("req-\(id).json")
            let responseURL = directory.appendingPathComponent("res-\(id).json")
            let acknowledgementURL = directory.appendingPathComponent(
                "ack-\(id).json")
            let method = Self.methodName(in: payload)
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try Data(payload.utf8).write(to: requestURL, options: .atomic)
            } catch {
                AppDelegate.log("core call \(method) was not written: "
                    + error.localizedDescription)
                DispatchQueue.main.async { result(nil) }
                return
            }
            let now = Date()
            self.pending[id] = Pending(
                method: method,
                started: now,
                deadline: now.addingTimeInterval(Self.timeout),
                requestURL: requestURL,
                responseURL: responseURL,
                acknowledgementURL: acknowledgementURL,
                acknowledged: false,
                result: result
            )
            self.startPolling()
        }
    }

    // MARK: - Answer collection

    private func startPolling() {
        if timer != nil {
            return
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval
        )
        source.setEventHandler { [weak self] in
            self?.collect()
        }
        source.resume()
        timer = source
    }

    private func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    /// Delivers every answer that has appeared, and gives up on the ones that
    /// ran out of time.
    private func collect() {
        if pending.isEmpty {
            stopPolling()
            return
        }
        let now = Date()
        for (id, call) in pending {
            if let data = FileManager.default.contents(atPath: call.responseURL.path) {
                try? FileManager.default.removeItem(at: call.responseURL)
                try? FileManager.default.removeItem(at: call.requestURL)
                try? FileManager.default.removeItem(at: call.acknowledgementURL)
                pending.removeValue(forKey: id)
                let elapsed = now.timeIntervalSince(call.started)
                if shouldLog(method: call.method, elapsed: elapsed) {
                    AppDelegate.log("core call \(call.method) answered over files in "
                        + String(format: "%.2fs", elapsed)
                        + " (\(data.count) bytes)")
                }
                DispatchQueue.main.async {
                    call.result(FlutterStandardTypedData(bytes: data))
                }
                continue
            }
            if !call.acknowledged,
               FileManager.default.fileExists(
                   atPath: call.acknowledgementURL.path) {
                // The extension has the call and is waiting for its core. That
                // wait is bounded by the extension, so the deadline moves out
                // instead of the call failing under it.
                try? FileManager.default.removeItem(at: call.acknowledgementURL)
                var updated = call
                updated.acknowledged = true
                updated.deadline = now.addingTimeInterval(Self.acknowledgedGrace)
                pending[id] = updated
                AppDelegate.log("core call \(call.method) is being handled; "
                    + "waiting for the core")
                continue
            }
            if now >= call.deadline {
                // The request is withdrawn so a tunnel that comes up later does
                // not replay a call the user has already moved on from.
                try? FileManager.default.removeItem(at: call.requestURL)
                try? FileManager.default.removeItem(at: call.acknowledgementURL)
                pending.removeValue(forKey: id)
                AppDelegate.log("core call \(call.method) got no answer in "
                    + String(format: "%.0fs", now.timeIntervalSince(call.started))
                    + (call.acknowledged ? " (extension never answered)" : ""))
                DispatchQueue.main.async { call.result(nil) }
            }
        }
    }

    /// Whether this call is worth a line in the log: the first few of each
    /// method, and every one that took noticeably long.
    private func shouldLog(method: String, elapsed: TimeInterval) -> Bool {
        let seen = logged[method, default: 0]
        if seen < Self.logEveryMethod {
            logged[method] = seen + 1
            return true
        }
        return elapsed >= Self.slowCall
    }

    /// The `method` field of a core call, for the log. The whole call is too
    /// large to write (a config push carries the profile).
    private static func methodName(in payload: String) -> String {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let method = object["method"] as? String else {
            return "unknown"
        }
        return method
    }
}
