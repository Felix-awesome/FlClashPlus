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

    /// Fails startTunnel with a message that survives the failure.
    private func fail(
        _ code: Int,
        _ message: String,
        completion: @escaping (Error?) -> Void
    ) {
        lastStartError = message
        BootLog.write("startTunnel failed: \(message)")
        completion(NSError(
            domain: "FlClash",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
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
        if let configured = configuredHomeDir {
            homeDir = configured
        } else if let group = VpnCore.groupHomeDir {
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

        let stack = providerConfig["stack"] as? String ?? "gvisor"
        let address = providerConfig["address"] as? String ?? "198.18.0.1/30"
        let dns = providerConfig["dns"] as? String ?? "198.18.0.1"
        let mtu = (providerConfig["mtu"] as? NSNumber)?.intValue ?? 9000
        BootLog.write("stack=\(stack) address=\(address) dns=\(dns) mtu=\(mtu)")

        guard let parsed = Self.splitCIDR(address) else {
            fail(1, "invalid tunnel address: " + address,
                completion: completionHandler)
            return
        }

        // iOS only routes traffic into the tunnel that matches the network
        // settings installed here: without setTunnelNetworkSettings the tunnel
        // comes up but carries nothing. Splitting the IPv4 space into two /1
        // routes overrides the default route without touching it.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: [parsed.address], subnetMasks: [parsed.mask])
        ipv4.includedRoutes = [
            NEIPv4Route(destinationAddress: "0.0.0.0", subnetMask: "255.255.255.254"),
            NEIPv4Route(destinationAddress: "128.0.0.0", subnetMask: "255.255.255.254"),
        ]
        settings.ipv4Settings = ipv4

        // An empty matchDomain captures every DNS query, so the core's fake-IP
        // resolver sees all lookups.
        let dnsSettings = NEDNSSettings(servers: [dns])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        settings.mtu = NSNumber(value: mtu)

        BootLog.write("installing tunnel network settings")
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                // This is the first Apple API that touches the provider, and the
                // one that fails when the settings themselves are rejected
                // (bad routes, unsupported DNS match domains). Logging it apart
                // from the core boot below is what tells the two apart later.
                self.fail(4, "setTunnelNetworkSettings failed: "
                    + error.localizedDescription, completion: completionHandler)
                return
            }
            BootLog.write("network settings installed")

            let core = VpnCore(homeDir: homeDir, stack: stack, address: address, dns: dns, mtu: mtu)
            self.vpnCore = core

            // Answer the system now, and boot the core on another queue.
            //
            // This call is what moves the connection's status from "connecting"
            // to "connected". Holding it until QuickSetup returned (up to 45s on
            // a first run, longer on an old device) made the app's own start
            // watch give up with "the tunnel did not come up" while the provider
            // was in fact booting normally -- and it turned every core-boot
            // failure into the same, cause-less message. Returning here instead
            // lets the tunnel report itself up in seconds; core calls wait for
            // readiness on their own, and a boot failure is reported through
            // them (lastStartError) instead of being swallowed.
            completionHandler(nil)
            BootLog.write("startTunnel answered; core boots in background")

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try core.start(packetFlow: self.packetFlow, tunnelProvider: self)
                    BootLog.write("core boot finished: tun live")
                } catch {
                    self.bootFailed = true
                    self.lastStartError = error.localizedDescription
                    BootLog.write("core boot failed: " + error.localizedDescription)
                }
                // The tunnel may have been torn down while the boot ran; a tun
                // stack with no tunnel above it would keep the packet flow open.
                if self.stopping {
                    BootLog.write("stop arrived during core boot; stopping the core")
                    core.stop()
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        BootLog.write("stopTunnel reason=\(reason.rawValue)")
        stopping = true
        vpnCore?.stop()
        vpnCore = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        // The app calls in as soon as the tunnel reports itself up, but the core
        // is only built after setTunnelNetworkSettings completes and QuickSetup
        // returns. Reply immediately and the very first call (typically
        // validateConfig while adding a profile) lands while vpnCore is still
        // nil, which the app shows as "Core did not answer validateConfig".
        // Waiting here turns that race into a slow call instead of a failed one.
        //
        // The wait is generous because a first init compiles the whole rule set;
        // when it still runs out, the reply carries the reason instead of being
        // empty, so the app can say why rather than "did not answer".
        let startError = lastStartError
        let method = Self.methodName(in: message)
        if bootFailed {
            // The core threw while booting: it will not become ready, so the
            // call is answered with the reason immediately rather than making
            // the app wait out the readiness timeout for nothing.
            BootLog.write("app call \(method) answered at once: core boot failed")
            completionHandler?(Self.notReadyReply(
                request: message,
                reason: startError.isEmpty ? "核心启动失败" : startError))
            return
        }
        let started = Date()
        BootLog.write("app call \(method) waiting for core")
        // Two waits are stacked here and their lengths have to differ: this one
        // covers VpnCore's own 45s wait for QuickSetup plus the StartTun that
        // follows it. Equal timeouts made the two give up in the same instant,
        // so a slow first init always answered nil a moment before the core
        // went live.
        waitForCore(timeout: 75) { [weak self] core in
            guard let core = core else {
                let setupError = self?.vpnCore?.lastError ?? ""
                let reason = startError.isEmpty ? setupError : startError
                BootLog.write("app call \(method) gave up after "
                    + String(format: "%.1fs", Date().timeIntervalSince(started))
                    + ": \(reason.isEmpty ? "core never became ready" : reason)")
                completionHandler?(Self.notReadyReply(request: message, reason: reason))
                return
            }
            BootLog.write("core ready for \(method) after "
                + String(format: "%.1fs", Date().timeIntervalSince(started)))
            // The core answers on its own goroutine, so the reply is handed back
            // through completionHandler. The watchdog keeps a lost answer from
            // wedging the Dart future forever; ReplyOnce makes sure the handler
            // still runs exactly once. It has to outlast the wait above.
            let reply = ReplyOnce(completionHandler)
            core.invoke(message) { text in
                reply.send(text.data(using: .utf8))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                reply.send(Self.notReadyReply(
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

    /// The `method` field of a core call, for the log. The whole call is too
    /// large to write on every message (a config push carries the profile).
    private static func methodName(in message: String) -> String {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            return "unknown"
        }
        return method
    }

    /// Builds a reply the app decodes as a core error.
    ///
    /// The Dart side reads every answer as a `MethodResponse`, so an `error`
    /// object is what turns "nothing came back" into a message the UI prints.
    /// The id is echoed from the request because the two are paired on it.
    private static func notReadyReply(request: String, reason: String) -> Data? {
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
        return try? JSONSerialization.data(withJSONObject: payload)
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
/// the watchdog has already fired, and calling a completion handler twice is a
/// trap.
private final class ReplyOnce {
    private let lock = NSLock()
    private var sent = false
    private let handler: ((Data?) -> Void)?

    init(_ handler: ((Data?) -> Void)?) {
        self.handler = handler
    }

    func send(_ data: Data?) {
        lock.lock()
        if sent {
            lock.unlock()
            return
        }
        sent = true
        lock.unlock()
        handler?(data)
    }
}
