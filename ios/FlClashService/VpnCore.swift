import Darwin
import Dispatch
import Foundation
import Network
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

    /// Appends the core's event stream (connections, DNS queries) to the shared
    /// container. The app runs in a different process and has no other way to
    /// learn about them: `sendProviderMessage` does not reach this extension on
    /// the device (see CoreBridge), and the gomobile callback fires here.
    private var eventSink: CoreEventSink?

    /// Publishes the system's active physical interface to the Go core, so its
    /// outbound sockets are bound to the real NIC (Hiddify's
    /// startDefaultInterfaceMonitor, carried over a shared file).
    private var interfaceMonitor: PhysicalInterfaceMonitor?

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
         dns: String = "198.18.0.2",
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
        tunnelProvider: NEPacketTunnelProvider
    ) throws {
        try FileManager.default.createDirectory(
            atPath: homeDir, withIntermediateDirectories: true)

        // The tunnel owns the whole IPv4 routing table, so the BSD RIB reports
        // the utun itself as the default route. Hiddify solves this by feeding
        // NWPathMonitor's active interface into the core's dialer; the core
        // here reads the same answer from a file in its home dir. Start it
        // before QuickSetup so the very first outbound dial already has it.
        let monitor = PhysicalInterfaceMonitor(homeDir: homeDir)
        monitor.start()
        interfaceMonitor = monitor

        // The core reads GEOIP/GEOSITE while it loads its first config, which
        // happens here and not on the app's schedule.
        ensureGeoData()

        // Register the event sink before the core applies its first config:
        // `hasEventListener` gates the hooks that produce connection and DNS
        // records, so a sink registered after QuickSetup would miss everything
        // the first config loads. The app polls the file this writes.
        let sink = CoreEventSink(
            url: URL(fileURLWithPath: homeDir).appendingPathComponent("events.jsonl"))
        sink.open()
        eventSink = sink
        MobileSetEventListener(sink)

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

        // The tunnel's routes and DNS are already in place by the time this
        // runs: startTunnel submits the network settings before it answers the
        // system, and only calls this boot once their completion has fired.
        // Installing them here instead -- after the completion was already
        // called -- left the live session with an empty configuration:
        // NEVPNStatus said "connected", no VPN badge appeared, and neither the
        // /1 routes nor the DNS server ever pointed at this utun.
        //
        // Only the descriptor is left to resolve, from the utun socket that
        // those settings created -- and *only* through it.
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
        MobileSetEventListener(nil)
        eventSink?.close()
        eventSink = nil
        interfaceMonitor?.stop()
        interfaceMonitor = nil
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
/// Keeps the Go core's outbound sockets on the real physical NIC.
///
/// Inside a packet tunnel the BSD routing table points at the utun, so an
/// interface scan can only guess -- and picks a stale Wi-Fi interface when
/// the device has moved to cellular. NWPathMonitor reports the path the
/// system is actually using. Hiddify passes that to the core through a
/// platform interface callback; here the same answer is written to a small
/// file in the shared home dir, which the Go dialer reads on every dial.
private final class PhysicalInterfaceMonitor {
    private let fileURL: URL
    // NetworkExtension also ships a legacy ObjC `NWPath` class, so both
    // NWPath and NWPathMonitor have to be module-qualified here.
    private var monitor: Network.NWPathMonitor?
    private var lastName = ""

    init(homeDir: String) {
        fileURL = URL(fileURLWithPath: homeDir, isDirectory: true)
            .appendingPathComponent("default_interface")
    }

    func start() {
        let monitor = Network.NWPathMonitor()
        let firstUpdate = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.publish(path)
            firstUpdate.signal()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.publish(path)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        self.monitor = monitor
        if firstUpdate.wait(timeout: .now() + 2) != .success {
            BootLog.write("network: no path update within 2s; "
                + "the core falls back to its own interface detection")
        }
    }

    private func publish(_ path: Network.NWPath) {
        let active = path.status == .satisfied ? path.availableInterfaces : []
        // utun/lo0/awdl0/bridge are either this tunnel or never carry internet
        // traffic; binding an outbound socket to utun loops it straight back.
        let name = active.first(where: { iface in
            iface.name.hasPrefix("en") || iface.name.hasPrefix("pdp_ip")
        })?.name ?? ""
        guard name != lastName else { return }
        lastName = name
        try? (name + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        BootLog.write("network: active physical interface "
            + (name.isEmpty ? "<none>" : name))
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        try? FileManager.default.removeItem(at: fileURL)
    }
}

final class Box<Value>: @unchecked Sendable {
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
    /// WireGuard-Apple / Hiddify's `GetTunnelFileDescriptor` walk the fd table
    /// and take the *first* utun control socket. Taking the highest one here
    /// used to pick a stale descriptor left by a previous session: the Go
    /// stack then read from a socket the system was no longer feeding, so the
    /// tunnel looked up while carrying no traffic at all.
    private static func scan() -> Int32? {
        var candidates: [Int32] = []
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
                candidates.append(fd)
            }
            fd += 1
        }
        if candidates.count > 1 {
            BootLog.write("core: \(candidates.count) utun sockets \(candidates); "
                + "using the first like WireGuard/libbox")
        }
        return candidates.first
    }
}

/// Records what the kernel says the tunnel's own utun is carrying.
///
/// The extension cannot count packets itself -- the core owns the borrowed
/// descriptor and drains it -- but the kernel keeps per-interface counters, and
/// they are the one signal that does not depend on the core being right.
///
/// They exist to separate two failures that look identical from the app ("the
/// tunnel is up and every node times out"):
///
///  - the utun counters grow while the core's own traffic line stays at
///    +0.0 KiB: the system is feeding packets into a socket the core is not
///    reading, i.e. the descriptor borrowed from the fd table is the wrong
///    one. Nothing reaches the tunnel stack, so nothing can be proxied.
///  - neither counter moves: the packets never entered the utun at all, so the
///    routes or the DNS settings the extension installed are the problem.
///
/// Sampling is fast for the first few minutes (the window every report is
/// about) and slow afterwards, so a long-lived tunnel does not fill the log the
/// app reads back.
final class TunnelTrafficMonitor {

    struct Counters {
        var receivedPackets: UInt32 = 0
        var sentPackets: UInt32 = 0
        var receivedBytes: UInt32 = 0
        var sentBytes: UInt32 = 0
    }

    private static let fastInterval: TimeInterval = 15
    private static let slowInterval: TimeInterval = 60
    private static let fastSamples = 20

    private let queue = DispatchQueue(label: "com.follow.clash.traffic")
    private var timer: DispatchSourceTimer?
    private var last: [String: Counters] = [:]
    private var samples = 0
    private var stopped = false

    func start(reason: String) {
        queue.async { [weak self] in
            guard let self, self.timer == nil, !self.stopped else { return }
            // One sample immediately: it proves the counters are readable and
            // gives the baseline the next delta is measured from.
            self.sample(label: "first sample, " + reason)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now() + Self.fastInterval,
                repeating: Self.fastInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            self.last = [:]
        }
    }

    private func tick() {
        samples += 1
        sample(label: nil)
        if samples == Self.fastSamples {
            timer?.schedule(
                deadline: .now() + Self.slowInterval,
                repeating: Self.slowInterval)
        }
    }

    private func sample(label: String?) {
        let counters = Self.read()
        guard !counters.isEmpty else {
            BootLog.write("traffic: no utun interface in this process "
                + "(getifaddrs found none)")
            return
        }
        var parts: [String] = []
        for name in counters.keys.sorted() {
            let current = counters[name] ?? Counters()
            let previous = last[name] ?? Counters()
            // The counters are 32-bit and wrap; a plain subtraction would
            // report a negative delta as a huge one after 4 GiB.
            let receivedPackets = current.receivedPackets &- previous.receivedPackets
            let sentPackets = current.sentPackets &- previous.sentPackets
            let receivedBytes = current.receivedBytes &- previous.receivedBytes
            let sentBytes = current.sentBytes &- previous.sentBytes
            parts.append(String(
                format: "%@ rx +%d pkts/%.1f KiB, tx +%d pkts/%.1f KiB",
                name,
                Int(receivedPackets),
                Double(receivedBytes) / 1024,
                Int(sentPackets),
                Double(sentBytes) / 1024))
        }
        last = counters
        let prefix = label.map { "traffic (" + $0 + "): " } ?? "traffic: "
        BootLog.write(prefix + parts.joined(separator: "; "))
    }

    /// Per-utun counters as the kernel reports them.
    ///
    /// Several entries can describe the same interface (one per address
    /// family); `if_data` carries the same totals in each, so the last one
    /// wins.
    private static func read() -> [String: Counters] {
        var result: [String: Counters] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return result }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let namePointer = entry.pointee.ifa_name else { continue }
            let name = String(cString: namePointer)
            guard name.hasPrefix("utun") else { continue }
            guard let dataPointer = entry.pointee.ifa_data else { continue }
            let data = dataPointer
                .assumingMemoryBound(to: if_data.self)
                .pointee
            result[name] = Counters(
                receivedPackets: data.ifi_ipackets,
                sentPackets: data.ifi_opackets,
                receivedBytes: data.ifi_ibytes,
                sentBytes: data.ifi_obytes)
        }
        return result
    }
}

/// Appends the core's event stream to a file the app polls.
///
/// `MobileSetEventListener` delivers `{"method":"message","arguments":[...]}`
/// documents from the core's own goroutines. They are written here, one per
/// line, because the app is a separate process: the extension cannot call into
/// it, and `sendProviderMessage` is not usable on the device (see CoreBridge).
///
/// The file is capped and trimmed from the front, keeping whole lines: a
/// reader that finds the file shorter than its offset starts over instead of
/// reading a torn record.
final class CoreEventSink: NSObject, MobileResultHandlerProtocol, @unchecked Sendable {
    /// Above this the file is trimmed back to [keepBytes].
    private static let maxBytes = 4 * 1024 * 1024
    private static let keepBytes = 1024 * 1024

    private let url: URL
    private let queue = DispatchQueue(label: "com.follow.clash.core.events")
    private var handle: FileHandle?

    init(url: URL) {
        self.url = url
        super.init()
    }

    /// Starts a fresh file: records from a previous session describe a tunnel
    /// the app has already moved on from.
    func open() {
        queue.sync {
            try? handle?.close()
            handle = nil
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
    }

    func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
        }
    }

    func onResult(_ data: Data?) throws {
        guard let data = data, !data.isEmpty else { return }
        queue.async { [weak self] in
            self?.append(data)
        }
    }

    private func append(_ data: Data) {
        guard let handle = handle else { return }
        var payload = data
        if payload.last != 0x0A {
            payload.append(0x0A)
        }
        do {
            let end = try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            if end + UInt64(payload.count) > Self.maxBytes {
                trim()
            }
        } catch {
            self.handle = nil
        }
    }

    /// Drops the oldest records, keeping the newest whole lines.
    private func trim() {
        guard let contents = try? Data(contentsOf: url) else { return }
        let tail = contents.suffix(Self.keepBytes)
        guard let newline = tail.firstIndex(of: 0x0A) else { return }
        let kept = tail[tail.index(after: newline)...]
        try? handle?.close()
        handle = nil
        do {
            try Data(kept).write(to: url)
            handle = try FileHandle(forWritingTo: url)
        } catch {
            handle = nil
        }
    }
}
