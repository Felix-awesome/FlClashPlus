import Foundation

/// Carries core calls between the app and this extension over the App Group
/// filesystem.
///
/// `sendProviderMessage` is the documented channel, and the extension still
/// answers it, but on the device this build was tested on the app's calls never
/// arrived: every one of them came back empty within milliseconds and not one
/// "app call" line reached this log, on a tunnel whose core had just reported
/// itself live. That is the failure Apple describes for the API itself -- "if an
/// error occurs while sending the message ... nil should be sent to the response
/// handler as notification" -- so it says nothing about the core and everything
/// about the app -> extension link.
///
/// The App Group container has no such problem: both processes already write the
/// same startup log inside it, and the core reads the config the app put there.
/// A call therefore travels the same way: the app drops `ipc/req-<id>.json` and
/// waits for `ipc/res-<id>.json`, this class hands the request to the core and
/// writes the answer back.
///
/// A request waiting on disk survives what a lost message does not: the tunnel
/// can still be booting its core when the app writes the call, and the request
/// is picked up as soon as the core is ready instead of being answered with
/// nothing.
final class CoreBridge {

    static let shared = CoreBridge()

    /// The subdirectory both sides use inside the shared home dir.
    static let directoryName = "ipc"

    /// How long a request may sit unread before it is dropped. A tunnel that
    /// comes up long after the app gave up must not replay a config the user
    /// has moved on from.
    private static let requestTTL: TimeInterval = 120

    /// Written the moment a request is taken, so the app can tell "the
    /// extension is on it" from "nothing is listening". The first call after a
    /// cold start can wait out a whole QuickSetup, and the app would otherwise
    /// have to choose between a short timeout (breaking that case) and a long
    /// one (every call hanging when the extension is gone).
    private static let ackPrefix = "ack-"

    /// How often the directory is checked for new requests. A provider drains
    /// packets for a living, so ten wakeups a second cost nothing next to the
    /// traffic it already carries -- and unlike a directory watch there is no
    /// filesystem event to miss.
    private static let pollInterval: TimeInterval = 0.1

    private let queue = DispatchQueue(label: "com.follow.clash.corebridge")

    private var directory: URL?
    private var timer: DispatchSourceTimer?

    /// Ids being answered right now, so the next drain cannot start them twice.
    /// Only touched on [queue].
    private var inFlight = Set<String>()

    /// How many times each method has been written to the log. Traffic and
    /// connection polls run once a second, so logging every call would push the
    /// startup steps that matter out of the log's 48KB window within minutes.
    /// The first calls of a method are recorded, and after that only the slow
    /// ones: that is what tells "the channel works" apart from "it stalls".
    private var logged: [String: Int] = [:]

    private static let logEveryMethod = 3
    private static let slowCall: TimeInterval = 2

    /// What to do with a request: hand it to the core and call back with the
    /// reply text. Supplied by the provider, which owns the core.
    private var answer: ((String, @escaping (String) -> Void) -> Void)?

    private init() {}

    /// Starts serving. Safe to call again after a stop (the system can start a
    /// tunnel in a provider process that already ran one).
    func start(
        homeDir: String,
        answer: @escaping (String, @escaping (String) -> Void) -> Void
    ) {
        queue.async {
            self.stopLocked()
            let url = URL(fileURLWithPath: homeDir)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true)
            } catch {
                BootLog.write("ipc: cannot create \(url.path): "
                    + error.localizedDescription
                    + "; the app cannot reach this core")
                return
            }
            self.directory = url
            self.answer = answer
            self.dropStale(in: url)
            self.startPolling()
            self.drain()
        }
    }

    func stop() {
        queue.async {
            self.stopLocked()
        }
    }

    // MARK: - Polling

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        directory = nil
        answer = nil
        inFlight.removeAll()
    }

    private func startPolling() {
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval
        )
        poll.setEventHandler { [weak self] in
            self?.drain()
        }
        poll.resume()
        timer = poll
    }

    // MARK: - Serving

    /// Picks up every request that is waiting and starts answering it.
    private func drain() {
        guard let directory = directory else { return }
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path)) ?? []
        let now = Date()
        for name in names {
            if name.hasPrefix("req-") && name.hasSuffix(".json") {
                handleRequest(named: name, in: directory, now: now)
            } else if name.hasPrefix("res-") || name.hasPrefix(Self.ackPrefix) {
                // Left behind by a call nobody collected: the app gave up on it
                // (it was killed, or it timed out). Left alone it would grow the
                // directory forever.
                let url = directory.appendingPathComponent(name)
                if let age = Self.age(of: url, now: now), age > Self.requestTTL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func handleRequest(named name: String, in directory: URL, now: Date) {
        let id = String(name.dropFirst("req-".count).dropLast(".json".count))
        if inFlight.contains(id) {
            return
        }
        let url = directory.appendingPathComponent(name)
        guard let age = Self.age(of: url, now: now) else {
            return
        }
        if age > Self.requestTTL {
            try? FileManager.default.removeItem(at: url)
            BootLog.write("ipc: dropped request \(id), \(Int(age))s old"
                + " (the app that sent it is gone)")
            return
        }
        guard let data = FileManager.default.contents(atPath: url.path),
              let message = String(data: data, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: url)
            BootLog.write("ipc: unreadable request \(id), dropped")
            return
        }
        // Taken off disk at once: the answer is written under a different name,
        // so nothing needs the request afterwards and a second drain must not
        // run the core call twice.
        try? FileManager.default.removeItem(at: url)

        inFlight.insert(id)
        let method = Self.methodName(in: message)
        let started = Date()
        // Tells the app its call is in hand before the wait for a booting core
        // begins, so its own deadline can be short without breaking the slow
        // first call.
        writeAcknowledgement(id: id, in: directory)
        guard let handler = answer else {
            inFlight.remove(id)
            BootLog.write("ipc: \(method) arrived with no core to answer it")
            return
        }
        handler(message) { [weak self] text in
            guard let self = self else { return }
            self.queue.async {
                self.respond(
                    id: id,
                    method: method,
                    text: text,
                    started: started
                )
            }
        }
    }

    private func writeAcknowledgement(id: String, in directory: URL) {
        let url = directory.appendingPathComponent("\(Self.ackPrefix)\(id).json")
        try? Data().write(to: url, options: .atomic)
    }

    private func respond(id: String, method: String, text: String, started: Date) {
        inFlight.remove(id)
        guard let directory = directory else { return }
        let url = directory.appendingPathComponent("res-\(id).json")
        // The acknowledgement has served its purpose; a call the app has
        // already given up on leaves the file behind.
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(Self.ackPrefix)\(id).json"))
        let payload = text.isEmpty ? "{}" : text
        guard let data = payload.data(using: .utf8) else { return }
        let elapsed = Date().timeIntervalSince(started)
        do {
            try data.write(to: url, options: .atomic)
            if shouldLog(method: method, elapsed: elapsed) {
                BootLog.write("ipc: \(method) answered in "
                    + String(format: "%.2fs", elapsed))
            }
        } catch {
            BootLog.write("ipc: could not write the answer for \(method): "
                + error.localizedDescription)
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

    /// Drops leftovers of a previous tunnel. Only what is already too old to be
    /// a live call is removed: the app writes its first request the moment the
    /// tunnel reports itself up, which can be before this runs.
    private func dropStale(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path)) ?? []
        let now = Date()
        var dropped = 0
        for name in names
        where name.hasPrefix("req-")
            || name.hasPrefix("res-")
            || name.hasPrefix(Self.ackPrefix) {
            let url = directory.appendingPathComponent(name)
            guard let age = Self.age(of: url, now: now),
                  age > Self.requestTTL else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
            dropped += 1
        }
        if dropped > 0 {
            BootLog.write("ipc: cleared \(dropped) stale file(s)")
        }
    }

    private static func age(of url: URL, now: Date) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        return now.timeIntervalSince(modified)
    }

    /// The `method` field of a core call, for the log. The whole call is too
    /// large to write (a config push carries the profile).
    static func methodName(in message: String) -> String {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let method = object["method"] as? String else {
            return "unknown"
        }
        return method
    }
}
