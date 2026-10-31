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

    /// The extension's own data directory, with the same layout as the shared
    /// one. Only used when the App Group container does not exist: on a
    /// pseudo-signed install the entitlement can be present while the container
    /// the system should have created for it is not, and the tunnel is more
    /// useful up-and-unshared than down-and-unexplained.
    static var ownHomeDir: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/flclash")
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
    func start(
        packetFlow: NEPacketTunnelFlow,
        tunnelProvider: NEPacketTunnelProvider,
        settings: NEPacketTunnelNetworkSettings
    ) throws {
        try FileManager.default.createDirectory(
            atPath: homeDir, withIntermediateDirectories: true)

        // The core reads GEOIP/GEOSITE while it loads its first config, which
        // happens here and not on the app's schedule.
        ensureGeoData()

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

        // Traffic is handed over here, and not a moment earlier.
        //
        // These are the settings that point the device's routes and DNS at this
        // tunnel. clashmi installs them from inside the core's own startup, once
        // the core is ready to read the packet flow; doing it before the core
        // boots means every packet goes into a flow nobody drains while setup
        // runs, which the device experiences as its network dying -- including
        // the profile download the user is in the middle of.
        //
        // It is applied exactly once: the descriptor read below is the one this
        // settings pass produces, so nothing goes stale underneath the core.
        BootLog.write("core: installing network settings (traffic takeover)")
        let installStarted = Date()
        let installed = DispatchSemaphore(value: 0)
        let installError = Box<NSError>()
        tunnelProvider.setTunnelNetworkSettings(settings) { error in
            installError.value = error.map { $0 as NSError }
            installed.signal()
        }
        guard installed.wait(timeout: .now() + 15) == .success else {
            lastError = "setTunnelNetworkSettings timed out"
            BootLog.write("core: network settings timed out after 15s")
            throw NSError(domain: "FlClash", code: 4,
                userInfo: [NSLocalizedDescriptionKey: lastError])
        }
        if let error = installError.value {
            lastError = "setTunnelNetworkSettings failed: " + error.localizedDescription
            BootLog.write("core: " + lastError)
            throw NSError(domain: "FlClash", code: 4,
                userInfo: [NSLocalizedDescriptionKey: lastError])
        }
        BootLog.write("core: network settings installed in "
            + String(format: "%.1fs", Date().timeIntervalSince(installStarted)))

        // The descriptor is resolved through the utun socket that the settings
        // above just created -- and *only* through it.
        //
        // The shortcut everyone copied (`packetFlow.value(forKeyPath:
        // "socket.fileDescriptor")`) answers nil on current iOS, which is what
        // this tunnel reported on a real device: five tries, always nil, and a
        // tunnel that died seconds after it appeared. The socket itself does
        // exist in this process, so it is found by asking the kernel which
        // interface each descriptor belongs to; that is the fallback clashmi
        // uses, and mihomo's tun reads the 4-byte utun header itself.
        guard let descriptor = TunSocket.acquire(from: tunnelProvider.packetFlow) else {
            lastError = "unable to obtain the utun socket of this tunnel"
            BootLog.write("core: no utun socket in this process; "
                + "traffic cannot be taken over")
            throw NSError(domain: "FlClash", code: 2,
                userInfo: [NSLocalizedDescriptionKey: lastError])
        }

        // The core takes ownership of what it is given and closes it
        // (tun.Start dups the descriptor, then closes the original). This one
        // belongs to the packet flow, so a duplicate is what goes over:
        // closing that leaves the framework's own descriptor -- and the tunnel
        // -- intact.
        guard let fd = TunSocket.detached(descriptor) else {
            lastError = "could not duplicate the utun descriptor"
            BootLog.write("core: dup of fd \(descriptor) failed")
            throw NSError(domain: "FlClash", code: 2,
                userInfo: [NSLocalizedDescriptionKey: lastError])
        }
        BootLog.write("core: tun fd=\(fd) (from \(descriptor))")

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

    /// Copies the geo databases into the core's home dir when they are missing.
    ///
    /// They ship inside the app's Flutter assets, and the app copies them into
    /// the shared directory from Dart. This extension cannot wait for that: the
    /// tunnel brings the core up on its own schedule, including a cold start
    /// where the app has not run at all, and a core whose home dir has no
    /// GEOIP/GEOSITE fails its initial setup -- leaving a tunnel that carries
    /// traffic for a core which applied nothing. Only the missing files are
    /// copied, so a normal launch costs four existence checks.
    private func ensureGeoData() {
        let names = ["ASN.mmdb", "GEOIP.dat", "GEOIP.metadb", "GEOSITE.dat"]
        let missing = names.filter {
            !FileManager.default.fileExists(
                atPath: (homeDir as NSString).appendingPathComponent($0))
        }
        guard !missing.isEmpty else { return }
        guard let source = VpnCore.geoAssetDirectory() else {
            BootLog.write("core: geo assets are not in the app bundle; "
                + "setup may fail without \(missing.joined(separator: ", "))")
            return
        }
        let started = Date()
        var copied: [String] = []
        for name in missing {
            let from = source.appendingPathComponent(name)
            let to = (homeDir as NSString).appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(atPath: from.path, toPath: to)
                copied.append(name)
            } catch {
                BootLog.write("core: could not copy \(name): "
                    + error.localizedDescription)
            }
        }
        BootLog.write("core: geo data copied (\(copied.joined(separator: ", "))) in "
            + String(format: "%.1fs", Date().timeIntervalSince(started)))
    }

    /// Locates the geo databases inside the containing app's bundle.
    ///
    /// The appex lives at `<app>/PlugIns/FlClashService.appex`, so the app
    /// bundle is two levels up, and Flutter keeps its assets in App.framework.
    /// Both layouts are checked because a build that inlines the assets would
    /// put them directly under the app bundle.
    private static func geoAssetDirectory() -> URL? {
        let appBundle = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            appBundle.appendingPathComponent(
                "Frameworks/App.framework/flutter_assets/assets/data"),
            appBundle.appendingPathComponent("flutter_assets/assets/data"),
            Bundle.main.bundleURL
                .appendingPathComponent("flutter_assets/assets/data"),
        ]
        for candidate in candidates
        where FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("GEOIP.dat").path) {
            return candidate
        }
        return nil
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

/// Carries a value out of an escaping completion that runs on another queue.
///
/// A local `var` captured by such a closure is what Swift 6 rejects outright,
/// and the semaphore in `start` needs the outcome of a callback it does not own.
private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}

/// Finds the utun descriptor of the tunnel's packet flow.
///
/// There is no supported API for this: NetworkExtension is meant to hand
/// packets out through `readPackets`, and a core that wants a socket reads one
/// itself. Every client that runs a tun-based core in an extension therefore
/// borrows the descriptor from underneath, and there are exactly two ways to
/// get it:
///
/// - `packetFlow.value(forKeyPath: "socket.fileDescriptor")`, the long-standing
///   shortcut. It stopped answering on current iOS versions -- it returns nil
///   rather than throwing, which made a dead tunnel look like a slow one.
/// - Asking the kernel. `getsockopt(fd, ...)` reports the interface a socket is
///   attached to, so walking the descriptors of this process and keeping the one
///   whose interface is named `utun*` finds the same socket.
///
/// Both are tried, kernel first being unreliable on some builds and the
/// shortcut being nil on others; whichever answers is used.
enum TunSocket {

    /// How long the descriptor is waited for after the network settings are in.
    ///
    /// The socket belongs to a flow the system sets up asynchronously, so the
    /// first look can come too early. The wait is bounded because the routes
    /// are already pointing at this tunnel: every second spent here is a second
    /// with no traffic, so failing fast is better than hanging politely.
    private static let waitDuration: TimeInterval = 15

    private static let pollInterval: TimeInterval = 0.25

    static func acquire(from flow: NEPacketTunnelFlow) -> Int32? {
        let deadline = Date().addingTimeInterval(waitDuration)
        var attempt = 0
        while true {
            attempt += 1
            if let fd = fromPacketFlow(flow) {
                BootLog.write("core: utun fd \(fd) came from the packet flow")
                return fd
            }
            if let fd = scan() {
                BootLog.write("core: utun fd \(fd) came from the descriptor scan")
                return fd
            }
            if Date() >= deadline {
                BootLog.write("core: no utun socket appeared in "
                    + String(format: "%.1fs", waitDuration)
                    + " (\(attempt) looks); the packet flow has no socket to borrow")
                return nil
            }
            if attempt == 3 {
                // One delivery request, dropped on the floor.
                //
                // The flow attaches its utun socket when it is asked to
                // deliver, and a tunnel that has just come up may not have been
                // asked yet -- which would hide the descriptor from the scan
                // even though the interface exists. The batch is discarded: the
                // core is not reading yet, and every packet that is lost here
                // is one the sender's own protocol retransmits.
                BootLog.write("core: priming the packet flow with one read")
                flow.readPackets { _, _ in }
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    /// A duplicate of [fd] for a caller that closes what it is handed.
    static func detached(_ fd: Int32) -> Int32? {
        let copy = dup(fd)
        return copy >= 0 ? copy : nil
    }

    /// The private shortcut, kept for the builds where it still answers.
    private static func fromPacketFlow(_ flow: NEPacketTunnelFlow) -> Int32? {
        guard let value = flow.value(forKeyPath: "socket.fileDescriptor") else {
            return nil
        }
        if let number = value as? NSNumber {
            let fd = number.int32Value
            return fd > 0 ? fd : nil
        }
        if let fd = value as? Int32 {
            return fd > 0 ? fd : nil
        }
        return nil
    }

    /// The descriptor whose socket sits on an interface named `utun*`.
    ///
    /// Several can exist (an older session that has not been reaped yet, for
    /// instance), and the newest is the one this tunnel just created, so the
    /// highest descriptor wins.
    private static func scan() -> Int32? {
        var found: Int32?
        var fd: Int32 = 0
        while fd <= 1024 {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(name.count)
            // Level/option 2/2 is the pair that reports the bound interface
            // name; it succeeds on sockets and fails on everything else, which
            // is also how non-sockets are skipped.
            let result = name.withUnsafeMutableBytes { buffer in
                getsockopt(fd, 2, 2, buffer.baseAddress, &length)
            }
            if result == 0, String(cString: name).hasPrefix("utun") {
                found = fd
            }
            fd += 1
        }
        return found
    }
}
