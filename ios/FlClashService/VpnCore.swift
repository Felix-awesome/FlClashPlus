import Dispatch
import Foundation
import NetworkExtension
import FlClashCore

/// Bridges the Go core (gomobile xcframework) to the NetworkExtension tunnel.
/// The gomobile bind for FlClash exports a package named `Mobile` (see
/// core/mobile/mobile_ios.go), so the Swift symbols are `MobileInvokeMethod`,
/// `MobileStartTun`, etc.
final class VpnCore {

    /// The App Group shared between the containing app and this extension.
    static let appGroup = "group.com.follow.clash"

    /// The data directory both processes must agree on. The core runs inside
    /// this extension's sandbox and cannot read the containing app's container,
    /// so config.yaml, the profiles and the geo files all live in the App Group
    /// container instead. `AppDelegate.groupHomeDir()` derives the same path on
    /// the app side; keep the two in step.
    static var groupHomeDir: String? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            return nil
        }
        return container
            .appendingPathComponent("Library/Application Support/flclash", isDirectory: true)
            .path
    }

    private let homeDir: String
    private let stack: String
    private let address: String
    private let dns: String
    private let mtu: Int
    private var started = false

    /// True once the core finished setup and the tun is live. Assigned before
    /// `MobileStartTun` so a call that arrives mid-setup is not answered by a
    /// half-initialized core.
    private(set) var isReady = false

    /// Why the core is not ready yet, in words the app can show. Empty once
    /// setup went through cleanly. Without this the provider can only answer a
    /// call with nothing, which the app surfaces as "Core did not answer
    /// setupConfig" -- true, but useless for fixing anything.
    private(set) var lastError = ""

    init(homeDir: String,
         stack: String = "gvisor",
         address: String = "198.18.0.1/30",
         dns: String = "198.18.0.1",
         mtu: Int = 9000) {
        self.homeDir = homeDir
        self.stack = stack
        self.address = address
        self.dns = dns
        self.mtu = mtu
    }

    /// Initializes the core and starts the tunnel on the packet flow's utun
    /// socket. This mirrors clashmi's approach: read the packet flow's private
    /// "socket.fileDescriptor" and hand it to the Go tun stack.
    func start(packetFlow: NEPacketTunnelFlow, tunnelProvider: NEPacketTunnelProvider) throws {
        try FileManager.default.createDirectory(
            atPath: homeDir, withIntermediateDirectories: true)

        // JSON is produced by JSONSerialization rather than string literals so
        // there is no hand-rolled escaping to get wrong.
        let initParams = VpnCore.jsonString([
            "home-dir": homeDir,
            "version": 1,
        ])
        let setupParams = VpnCore.jsonString([
            "selected-map": [String: Any](),
            "test-url": "http://www.gstatic.com/generate_204",
            "skip-cert-verify": false,
        ])

        // QuickSetup hands the work to its own goroutine, and `isRunning` is
        // only set once the config has been applied. Starting the tun before
        // that flips StartTun onto its "no core running yet" branch, which
        // opens the listeners itself and collides with the setup path, so wait
        // for the answer instead of racing it.
        let resultHandler = ResultCallback()
        let ready = DispatchSemaphore(value: 0)
        resultHandler.onAnswer = { _ in ready.signal() }
        BootLog.write("core: QuickSetup begin (homeDir=\(homeDir))")
        let setupStarted = Date()
        MobileQuickSetup(initParams, setupParams, resultHandler)

        // A first init loads the geo databases and compiles the whole rule set,
        // which on an older device easily runs past 20s. Aborting on that
        // timeout used to kill startTunnel outright, so the tunnel never came
        // up and every later core call had nobody left to answer it -- which
        // the app reports as "Core did not answer setupConfig". Wait longer,
        // and carry on even when the answer never arrives: the tunnel is what
        // the app talks through, and setupConfig re-applies the real config
        // once it is up.
        let answered = ready.wait(timeout: .now() + 45) == .success
        let setupError = resultHandler.result
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(setupStarted))
        if !answered {
            lastError = "core setup did not finish within 45s"
            BootLog.write("core: QuickSetup gave no answer after \(elapsed); "
                + "carrying on so the tunnel still comes up")
        } else if !setupError.isEmpty {
            // The core already fell back to its built-in config, which has no
            // proxies. That is recoverable: the app pushes the real config over
            // handleAppMessage once the tunnel is up, so leave a trace rather
            // than refusing to start.
            lastError = "core setup reported: " + setupError
            BootLog.write("core: QuickSetup answered in \(elapsed) with error: \(setupError)")
        } else {
            BootLog.write("core: QuickSetup answered in \(elapsed)")
        }

        guard let fd = tunnelProvider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 else {
            lastError = "unable to obtain packet flow file descriptor"
            BootLog.write("core: no packet flow file descriptor")
            throw NSError(domain: "FlClash", code: 2,
                userInfo: [NSLocalizedDescriptionKey: lastError])
        }
        BootLog.write("core: packet flow fd=\(fd)")

        let options = VpnCore.jsonString([
            "mtu": mtu,
            "congestion-controller": "",
        ])

        let ok = MobileStartTun(fd, stack, address, dns, options)
        if !ok {
            lastError = lastError.isEmpty
                ? "MobileStartTun failed"
                : lastError + "; MobileStartTun failed"
            BootLog.write("core: MobileStartTun returned false (\(lastError))")
            throw NSError(domain: "FlClash", code: 3,
                userInfo: [NSLocalizedDescriptionKey: lastError])
        }

        started = true
        isReady = true
        BootLog.write("core: MobileStartTun ok, tunnel live")
    }

    func stop() {
        isReady = false
        lastError = ""
        if started {
            MobileStopTun()
            started = false
        }
    }

    /// Forwards a JSON method call to the core. The core dispatches every
    /// method on its own goroutine (`core.dispatchMethodCall` runs the handler
    /// under `safeGo`), so `MobileInvokeMethod` returns before there is an
    /// answer: the reply has to be delivered through the completion handler
    /// instead of read back from the call.
    func invoke(_ json: String, completion: @escaping (String) -> Void) {
        let callback = ResultCallback()
        callback.onAnswer = { text in
            if text.isEmpty {
                // The core answered with nothing: either it is not running or
                // the method panicked and the export swallowed it.
                BootLog.write("core: invoke answered nothing")
            }
            completion(text)
        }
        MobileInvokeMethod(json, callback)
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

/// A gomobile ResultHandler implementation that captures the single result
/// callback the core delivers. gomobile maps the Go `ResultHandler` interface
/// to the Swift protocol `MobileResultHandlerProtocol` (the `MobileResultHandler`
/// class is the Go-created concrete instance, not the one Swift implements).
/// The Go method `OnResult(data []byte) error` becomes the Swift protocol
/// requirement `func onResult(_ data: Data?) throws`.
private final class ResultCallback: NSObject, MobileResultHandlerProtocol {
    private let lock = NSLock()
    private var buffer = ""

    /// Called once, with whatever the core answered, on the goroutine the core
    /// replied from.
    var onAnswer: ((String) -> Void)?

    var result: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func onResult(_ data: Data?) throws {
        lock.lock()
        if let data = data {
            buffer = String(data: data, encoding: .utf8) ?? ""
        }
        let text = buffer
        let answer = onAnswer
        lock.unlock()
        answer?(text)
    }
}
