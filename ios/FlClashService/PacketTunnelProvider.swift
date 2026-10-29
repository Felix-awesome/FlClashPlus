import NetworkExtension
import FlClashCore

/// The NetworkExtension packet tunnel provider for FlClash. It installs the
/// tunnel network settings (address/routes/DNS), then loads the Go core (built
/// as an xcframework via gomobile) and drives the tunnel through the utun
/// socket file descriptor obtained from NEPacketTunnelFlow.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var vpnCore: VpnCore?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // The tunnel configuration (home dir, stack, address, dns) is delivered
        // from the containing app through the protocolConfiguration.
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration else {
            completionHandler(NSError(domain: "FlClash", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing providerConfiguration"]))
            return
        }

        guard let homeDir = providerConfig["home-dir"] as? String
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VpnCore.appGroup)?
                .appendingPathComponent("Library/Application Support/flclash", isDirectory: true).path
        else {
            completionHandler(NSError(domain: "FlClash", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unable to resolve home dir"]))
            return
        }

        let stack = providerConfig["stack"] as? String ?? "gvisor"
        let address = providerConfig["address"] as? String ?? "198.18.0.1/30"
        let dns = providerConfig["dns"] as? String ?? "198.18.0.1"
        let mtu = (providerConfig["mtu"] as? NSNumber)?.intValue ?? 9000

        guard let parsed = Self.splitCIDR(address) else {
            completionHandler(NSError(domain: "FlClash", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalid tunnel address: " + address]))
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

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                completionHandler(NSError(domain: "FlClash", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "setTunnelNetworkSettings failed: " + error.localizedDescription]))
                return
            }

            let core = VpnCore(homeDir: homeDir, stack: stack, address: address, dns: dns, mtu: mtu)
            self.vpnCore = core

            do {
                try core.start(packetFlow: self.packetFlow, tunnelProvider: self)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        vpnCore?.stop()
        vpnCore = nil
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Forward JSON method calls from the containing app to the core.
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        let result = vpnCore?.invoke(message) ?? ""
        completionHandler?(result.data(using: .utf8))
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
