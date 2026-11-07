import Dispatch
import Foundation
import NetworkExtension
import FlClashCore

/// The NetworkExtension packet tunnel provider for FlClash. It installs the
/// tunnel network settings (address/routes/DNS), then loads the Go core (built
/// as an xcframework via gomobile) and drives the tunnel through the utun
/// socket file descriptor obtained from NEPacketTunnelFlow.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var vpnCore: VpnCore?

    /// Refreshes the App Group "alive" file while the core is up, so the app
    /// can tell a live provider (recent mtime) from one the system silently
    /// reaped (stale mtime) even though NEVPNManager still says "connected".
    private var heartbeat: DispatchSourceTimer?

    /// Why the last startTunnel attempt failed, if it did. Kept so a core call
    /// that arrives afterwards can be answered with the real reason instead of
    /// an empty reply -- on a device there is no console to read it from.
    private var lastStartError = ""

    /// Set when the system tears the tunnel down while the core is still
    /// booting in the background. The boot then stops itself instead of leaving
    /// a tun stack running with no tunnel to carry its packets to.
    private var stopping = false

    /// Set when the background core boot threw. A call then answers with the
    /// reason at once instead of waiting out the readiness timeout for a core
    /// that will never become ready.
    private var bootFailed = false

    /// Samples the kernel's per-utun counters while the core is live, so a
    /// tunnel that is up but carrying nothing can be told apart from one whose
    /// packets never arrive (see TunnelTrafficMonitor).
    private var traffic: TunnelTrafficMonitor?

    /// Fails startTunnel with a message that survives the failure.
    private func fail(
        _ code: Int,
        _ message: String,
        completion: @escaping (Error?) -> Void
    ) {
        lastStartError = message
        // No core will ever boot after this, so calls must not wait out the
        // readiness timeout; answer them with the reason at once.
        bootFailed = true
        BootLog.write("startTunnel failed: \(message)")
        completion(NSError(
            domain: "FlClash",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }

    /// Reports a failure that happens after startTunnel has already answered
    /// the system. The completion must not be called twice, so the reason is
    /// written to the boot log (the app attaches it to the start failure) and
    /// the provider is exited: the system then takes the tunnel down, which is
    /// what the app's start watch sees and reports.
    private func reportBootFailure(_ message: String) {
        lastStartError = message
        bootFailed = true
        BootLog.write("startTunnel failed: " + message)
        BootLog.write("exiting so the system tears the tunnel down")
        exit(EXIT_FAILURE)
    }

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        BootLog.write("startTunnel entered")
        stopping = false
        bootFailed = false
        // The tunnel configuration (home dir, stack, address, dns) is delivered
        // from the containing app through the protocolConfiguration.
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration else {
            fail(1, "missing providerConfiguration", completion: completionHandler)
            return
        }

        // An empty string is not a missing home dir: treat it as absent so the
        // shared container fallback below still applies.
        let configuredHomeDir = (providerConfig["home-dir"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let homeDir: String
        if let configured = configuredHomeDir, Self.isUsableDirectory(configured) {
            homeDir = configured
        } else if let group = VpnCore.groupHomeDir, Self.isUsableDirectory(group) {
            homeDir = group
        } else {
            // No App Group container. A pseudo-signed (TrollStore/ldid) install
            // can end up with the entitlement but without the container the
            // system is supposed to create for it. Refusing to start here only
            // produced "the tunnel did not come up", which names none of the
            // causes and is indistinguishable from a signing problem; booting
            // into the extension's own container at least gets a live tunnel and
            // a readable log, and the app then learns the real reason from the
            // core call instead of from a tunnel that never appeared.
            homeDir = VpnCore.ownHomeDir
            BootLog.write("warning: the \(VpnCore.appGroup) container is unavailable; "
                + "booting into the extension container instead. The app cannot share "
                + "its config with this directory.")
        }
        BootLog.write("home dir: \(homeDir)")
        // Start the liveness signal as soon as this process is known to be up,
        // not after the core finishes booting: the app reads it to tell a live
        // provider from a reaped one, and the window between "connected" and
        // "tun live" must still count as alive.
        startHeartbeat(homeDir: homeDir)

        let stack = providerConfig["stack"] as? String ?? "gvisor"
        let address = providerConfig["address"] as? String ?? "198.18.0.1/30"
        let mtu = Self.tunnelMtu(providerConfig["mtu"])

        guard let parsed = Self.splitCIDR(address) else {
            fail(1, "invalid tunnel address: " + address,
                completion: completionHandler)
            return
        }
        // The core hijacks DNS on the *second* address of the TUN subnet
        // (`Inet4Address.Addr().Next()` in mihomo's sing_tun, and
        // `GetDNSServerAddress()` in Hiddify's libbox). Older app builds still
        // send 198.18.0.1, which is the gvisor NIC's own address: nothing
        // listens there, so every system DNS query times out and with it every
        // proxy delay test. Derive it here rather than trusting the caller.
        let dns = Self.nextIPv4Address(parsed.address) ?? "198.18.0.2"
        BootLog.write("stack=\(stack) address=\(address) dns=\(dns) mtu=\(mtu)")

        // The settings that point this device's routes and DNS at the tunnel
        // are built here and submitted below, before startTunnel answers the
        // system, so NetworkExtension has them in hand as it brings the
        // session up.
        let settings = Self.settings(
            address: parsed.address,
            mask: parsed.mask,
            dns: dns,
            mtu: mtu
        )

        let core = VpnCore(homeDir: homeDir, stack: stack, address: address, dns: dns, mtu: mtu)
        vpnCore = core

        // The app's calls travel over the shared container, not over
        // `sendProviderMessage` (see CoreBridge.swift). Serving starts here,
        // before the core is ready: a request that arrives while QuickSetup is
        // still running waits on disk and is answered once it is.
        CoreBridge.shared.start(homeDir: homeDir) { [weak self] message, reply in
            self?.answer(message, reply: reply)
        }

        // Submit the settings request before answering the system, but wait
        // for its completion on a background queue (see the note below).
        // The core boot follows that completion, and the system is still
        // answered at once: holding the completion for QuickSetup (up to 45s
        // on a first run) is what made the app's own start watch give up
        // earlier.
        BootLog.write("installing network settings before answering the system")
        let installStarted = Date()
        let installed = DispatchSemaphore(value: 0)
        let installError = Box<NSError>()
        setTunnelNetworkSettings(settings) { error in
            installError.value = error.map { $0 as NSError }
            installed.signal()
        }

        // Answer immediately, and never wait for that signal on this queue.
        // NetworkExtension delivers the settings completion on the same serial
        // queue that is running startTunnel, so a semaphore here blocks the
        // very callback it waits for: the boot log showed four starts, each
        // failing at precisely 15.0s with "timed out", followed by
        // connecting -> disconnecting -> disconnected. Keeping the completion
        // immediate also covers the other reading of that log -- the system
        // withholding the settings callback until startTunnel has answered.
        // The request above is still submitted first, so the routes and DNS
        // are in the system's hands when it brings the session up.
        completionHandler(nil)
        BootLog.write("startTunnel answered; settings and core settle in background")

        DispatchQueue.global(qos: .userInitiated).async {
            guard installed.wait(timeout: .now() + 15) == .success else {
                self.reportBootFailure("setTunnelNetworkSettings timed out")
                return
            }
            if let error = installError.value {
                self.reportBootFailure("setTunnelNetworkSettings failed: "
                    + error.localizedDescription)
                return
            }
            BootLog.write("network settings installed in "
                + String(format: "%.1fs", Date().timeIntervalSince(installStarted)))

            do {
                try core.start(
                    packetFlow: self.packetFlow,
                    tunnelProvider: self
                )
                BootLog.write("core boot finished: tun live")
                // The core owns the descriptor from here on, so the only
                // remaining witness of the data path is the kernel's own view
                // of the utun. Starting the sampler now means the first sample
                // lands in the log the app reads back after a failed test.
                let monitor = TunnelTrafficMonitor()
                self.traffic = monitor
                monitor.start(reason: "core live")
            } catch {
                self.bootFailed = true
                self.lastStartError = error.localizedDescription
                BootLog.write("core boot failed: " + error.localizedDescription)
                // A tunnel whose core never came up can only black-hole the
                // traffic it was given -- the routes are in place by now, so
                // by the time this throws, packets are already being handed
                // to a flow nobody drains. Killing the
                // provider is the one way to make the system take the tunnel
                // down again (clashmi does the same), which returns networking
                // to the device and leaves the reason in the startup log.
                if self.stopping {
                    return
                }
                BootLog.write("exiting so the system tears the tunnel down")
                exit(EXIT_FAILURE)
            }
            if self.stopping {
                BootLog.write("stop arrived during core boot; stopping the core")
                core.stop()
            }
        }
    }

    /// The tunnel MTU, clamped to a range the system accepts.
    ///
    /// The value travels from the app's TUN settings now instead of being
    /// fixed at 9000 here. A nonsensical one (0, negative, or larger than what
    /// utun takes) makes `setTunnelNetworkSettings` fail, and with it the whole
    /// tunnel -- so it is bounded at the boundary rather than trusted. 9000
    /// stays the default because that is what Hiddify and sing-box use for the
    /// same setup.
    private static func tunnelMtu(_ value: Any?) -> Int {
        let requested = (value as? NSNumber)?.intValue ?? 9000
        let clamped = min(max(requested, 1280), 9000)
        if clamped != requested {
            BootLog.write("mtu \(requested) is out of range; using \(clamped)")
        }
        return clamped
    }

    /// Builds the tunnel's network settings: the interface address, the
    /// Hiddify-style subnet routes plus a default route, the DNS server on the
    /// TUN subnet's second address, and a catch-all DNS match domain so the
    /// core's fake-IP resolver sees every lookup.
    private static func settings(
        address: String,
        mask: String,
        dns: String,
        mtu: Int
    ) -> NEPacketTunnelNetworkSettings {
        // Hiddify uses "::1" because its TUN also carries an IPv6 address.
        // This one is IPv4-only (198.18.0.1/30), so an IPv6 remote would give
        // the system an IPv6 tunnel with no IPv6 address behind it. Keep the
        // IPv4 remote; the route set below is what fixes the missing badge.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: [address], subnetMasks: [mask])
        // Hiddify / sing-box-for-apple route set: eight progressively wider
        // subnets cover 1.0.0.0-255.255.255.255 and deliberately leave
        // 0.0.0.0/8 (unspecified, DHCP, captive-probe addresses) to the
        // system. Two /1 routes include that range, which is why a tunnel can
        // come up with no VPN badge and a device that thinks it has no
        // network. default() is what makes NetworkExtension adopt this tunnel
        // as the default route and move NEVPNStatus to connected.
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: "1.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "2.0.0.0", subnetMask: "254.0.0.0"),
            NEIPv4Route(destinationAddress: "4.0.0.0", subnetMask: "252.0.0.0"),
            NEIPv4Route(destinationAddress: "8.0.0.0", subnetMask: "248.0.0.0"),
            NEIPv4Route(destinationAddress: "16.0.0.0", subnetMask: "240.0.0.0"),
            NEIPv4Route(destinationAddress: "32.0.0.0", subnetMask: "224.0.0.0"),
            NEIPv4Route(destinationAddress: "64.0.0.0", subnetMask: "192.0.0.0"),
            NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "128.0.0.0"),
            NEIPv4Route.default(),
        ]
        // Punch the two lowest addresses out of the default route, as Hiddify
        // does with excludeDefaultRoute: iOS uses them while an interface
        // comes up, and a default route with no hole here can be judged
        // "no network available".
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "255.255.255.254"),
        ]
        settings.ipv4Settings = ipv4

        let dnsSettings = NEDNSSettings(servers: [dns])
        dnsSettings.matchDomains = [""]
        // Match every lookup, including bare hostnames and names without a
        // dot, and keep the system from appending its search domains. Without
        // this the core's fake-IP resolver misses the names the system treats
        // as local, and those lookups go straight to the device's real DNS
        // instead of through the tunnel.
        if #available(iOS 14.0, *) {
            dnsSettings.matchDomainsNoSearch = true
        }
        settings.dnsSettings = dnsSettings

        settings.mtu = NSNumber(value: mtu)
        return settings
    }

    /// Writes the current time into the shared "alive" file on a short period,
    /// so the app can see a provider that is still running. The file's mtime is
    /// the signal (its contents are empty), which keeps this from growing the
    /// boot.log and from needing a read-modify-write on a hot path.
    private func startHeartbeat(homeDir: String) {
        let url = URL(fileURLWithPath: homeDir)
            .appendingPathComponent("alive.txt")
        // Seed it now so the very first start() already sees a live provider.
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler {
            // Touch the file; createFile updates mtime even when it exists.
            _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        timer.resume()
        heartbeat = timer
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        BootLog.write("stopTunnel reason=\(reason.rawValue)")
        stopping = true
        CoreBridge.shared.stop()
        heartbeat?.cancel()
        heartbeat = nil
        traffic?.stop()
        traffic = nil
        vpnCore?.stop()
        vpnCore = nil
        completionHandler()
        // The provider process must not outlive its tunnel. Without this, a
        // `stopTunnel reason=9` (the system removed the configuration) leaves
        // the process running with a dead core: NEVPNManager keeps reporting
        // "connected", the app's start() trusts that and never restarts, and
        // every core call then fails as unanswered. clashmi calls
        // `exit(EXIT_FAILURE)` here for exactly this reason, so the system is
        // forced to tear the whole provider down and the next start boots a
        // fresh one.
        exit(EXIT_FAILURE)
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        // Kept because it is the documented channel and costs nothing. On the
        // tested device nothing ever arrived through it (see CoreBridge), which
        // is why the app sends its calls as files instead.
        BootLog.write("app call \(CoreBridge.methodName(in: message)) over xpc")
        answer(message) { text in
            completionHandler?(text.data(using: .utf8))
        }
    }

    /// Turns one core call into one reply string.
    ///
    /// Both transports end up here: `handleAppMessage` for the documented XPC
    /// channel, `CoreBridge` for the App Group files the app actually uses. The
    /// waiting rules are the same for both.
    private func answer(_ message: String, reply: @escaping (String) -> Void) {
        let startError = lastStartError
        let method = CoreBridge.methodName(in: message)
        if bootFailed {
            // The core threw while booting: it will not become ready, so the
            // call is answered with the reason immediately rather than making
            // the app wait out the readiness timeout for nothing.
            BootLog.write("core call \(method) answered at once: core boot failed")
            reply(Self.notReadyReply(
                request: message,
                reason: startError.isEmpty ? "核心启动失败" : startError))
            return
        }
        let started = Date()
        // The app calls in as soon as the tunnel reports itself up, but the
        // core is only built after the network settings are installed and
        // QuickSetup returns. Waiting here turns that race into a slow call
        // instead of a failed one.
        //
        // Two waits are stacked and their lengths have to differ: VpnCore
        // spends up to 45s on QuickSetup and another 15s borrowing the utun fd
        // -- 60s before StartTun even runs. The settings pass sits in front
        // of that boot too, on a background queue. Waiting
        // exactly as long as the boot made both sides give up in the same
        // instant, so a slow first init answered "core_not_ready" a moment
        // before the core went live, leaving it on its empty default config:
        // no proxies, and every delay test timing out. Leave a full minute of
        // headroom. CoreFileRelay.acknowledgedGrace is sized against this
        // number.
        waitForCore(timeout: 120) { [weak self] core in
            guard let core = core else {
                let setupError = self?.vpnCore?.lastError ?? ""
                let reason = startError.isEmpty ? setupError : startError
                BootLog.write("core call \(method) gave up after "
                    + String(format: "%.1fs", Date().timeIntervalSince(started))
                    + ": \(reason.isEmpty ? "core never became ready" : reason)")
                reply(Self.notReadyReply(request: message, reason: reason))
                return
            }
            BootLog.write("core ready for \(method) after "
                + String(format: "%.1fs", Date().timeIntervalSince(started)))
            // The core answers on its own goroutine, so the reply is handed back
            // through the completion. The watchdog keeps a lost answer from
            // wedging the caller forever; ReplyOnce makes sure the reply is
            // delivered exactly once. It has to outlast the wait above.
            let once = ReplyOnce(reply)
            core.invoke(message) { text in
                once.send(text)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                once.send(Self.notReadyReply(
                    request: message,
                    reason: "核心 120 秒内没有返回结果"))
            }
        }
    }

    /// Calls back with the core once it is set up and live, or with nil when it
    /// never got there within [timeout]. The completion runs exactly once.
    private func waitForCore(
        timeout: TimeInterval,
        completion: @escaping (VpnCore?) -> Void
    ) {
        pollCore(deadline: Date().addingTimeInterval(timeout), completion: completion)
    }

    /// One poll step of [waitForCore].
    ///
    /// The retry recurses through a method rather than a closure: a closure that
    /// calls itself cannot be declared in Swift ("closure captures 'poll' before
    /// it is declared").
    ///
    /// `vpnCore` is assigned before its start() finishes, so existence alone is
    /// not readiness: a call answered mid-setup would reach a core whose config
    /// is not applied yet.
    private func pollCore(
        deadline: Date,
        completion: @escaping (VpnCore?) -> Void
    ) {
        if let core = vpnCore, core.isReady {
            completion(core)
            return
        }
        if Date() >= deadline {
            completion(nil)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else {
                // The provider is gone; answer so the caller cannot hang.
                completion(nil)
                return
            }
            self.pollCore(deadline: deadline, completion: completion)
        }
    }

    /// Builds a reply the app decodes as a core error.
    ///
    /// The Dart side reads every answer as a `MethodResponse`, so an `error`
    /// object is what turns "nothing came back" into a message the UI prints.
    /// The id is echoed from the request because the two are paired on it.
    private static func notReadyReply(request: String, reason: String) -> String {
        var id: Any = ""
        if let data = request.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["id"] {
            id = value
        }
        let detail = reason.isEmpty ? "扩展还没有完成核心初始化" : reason
        let payload: [String: Any] = [
            "id": id,
            "error": [
                "code": "core_not_ready",
                "message": "VPN 扩展里的核心还没就绪：" + detail
                    + "。隧道已建立，稍等几秒再重试一次。",
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Whether this extension can actually write to [path].
    ///
    /// The app hands over the path it resolved for its own home dir. When the
    /// App Group container is missing, that path points inside the *app's*
    /// sandbox, which this process is not allowed to touch: the core would then
    /// fail to create its config and every call would time out without saying
    /// why. Creating the directory is the check itself -- a sandboxed path
    /// fails here, and a merely absent one is created on the spot.
    private static func isUsableDirectory(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true)
        } catch {
            return false
        }
        return FileManager.default.isWritableFile(atPath: path)
    }

    /// The second address of the TUN subnet, which is where the Go core
    /// listens for hijacked DNS (mihomo: `Inet4Address.Addr().Next()`;
    /// Hiddify/libbox: `GetDNSServerAddress()`). Both stacks require it and
    /// refuse a /32 subnet for exactly this reason.
    private static func nextIPv4Address(_ address: String) -> String? {
        var octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) else {
            return nil
        }
        for i in stride(from: 3, through: 0, by: -1) {
            if octets[i] < 255 {
                octets[i] += 1
                return octets.map { String($0) }.joined(separator: ".")
            }
            octets[i] = 0
        }
        return nil
    }

    /// Turns "198.18.0.1/30" into ("198.18.0.1", "255.255.255.252").
    private static func splitCIDR(_ cidr: String) -> (address: String, mask: String)? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let bits = Int(parts[1]),
              bits >= 0, bits <= 32 else {
            return nil
        }
        let value: UInt32 = bits == 0 ? 0 : UInt32.max << UInt32(32 - bits)
        var octets: [String] = []
        for shift in stride(from: 24, through: 0, by: -8) {
            octets.append(String((value >> UInt32(shift)) & 0xFF))
        }
        return (String(parts[0]), octets.joined(separator: "."))
    }
}

/// Delivers an extension reply exactly once. The core's answer may arrive after
/// the watchdog has already fired, and delivering a reply twice is a trap.
private final class ReplyOnce {
    private let lock = NSLock()
    private var sent = false
    private let handler: (String) -> Void

    init(_ handler: @escaping (String) -> Void) {
        self.handler = handler
    }

    func send(_ text: String) {
        lock.lock()
        if sent {
            lock.unlock()
            return
        }
        sent = true
        lock.unlock()
        handler(text)
    }
}
