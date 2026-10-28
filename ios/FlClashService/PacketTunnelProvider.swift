import NetworkExtension
import FlClashCore

/// The NetworkExtension packet tunnel provider for FlClash. It loads the Go
/// core (built as an xcframework via gomobile) and drives the tunnel through
/// the utun socket file descriptor obtained from NEPacketTunnelFlow.
class PacketTunnelProvider: NEPacketTunnelProvider {

    private var vpnCore: VpnCore?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // The tunnel configuration (home dir, config path) is delivered from the
        // containing app through the protocolConfiguration.
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = proto.providerConfiguration else {
            completionHandler(NSError(domain: "FlClash", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing providerConfiguration"]))
            return
        }

        let homeDir = providerConfig["home-dir"] as? String
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: VpnCore.appGroup)?
                .appendingPathComponent("Library/Application Support/flclash", isDirectory: true).path

        let core = VpnCore(homeDir: homeDir)
        self.vpnCore = core

        do {
            try core.start(packetFlow: self.packetFlow, tunnelProvider: self)
            completionHandler(nil)
        } catch {
            completionHandler(error)
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
}
