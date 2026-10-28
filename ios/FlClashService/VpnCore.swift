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

    private let homeDir: String
    private var started = false

    init(homeDir: String) {
        self.homeDir = homeDir
    }

    /// Initializes the core and starts the tunnel on the packet flow's utun
    /// socket. This mirrors clashmi's approach: read the packet flow's private
    /// "socket.fileDescriptor" and hand it to the Go tun stack.
    func start(packetFlow: NEPacketTunnelFlow, tunnelProvider: NEPacketTunnelProvider) throws {
        // 1. Initialize the core (home dir + config path come from the app).
        try FileManager.default.createDirectory(
            atPath: homeDir, withIntermediateDirectories: true)

        let initParams = #"{"home-dir":"\#(homeDir)","version":1}"#
        let setupParams = #"{"selected-map":{},"test-url":"http://www.gstatic.com/generate_204","skip-cert-verify":false}"#

        // QuickSetup is fire-and-forget on iOS; completion is delivered through
        // the ResultHandler callback.
        let resultHandler = ResultCallback()
        MobileQuickSetup(initParams, setupParams, resultHandler)

        // 2. Start the tunnel. The utun fd comes from the packet flow.
        guard let fd = tunnelProvider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 else {
            throw NSError(domain: "FlClash", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "unable to obtain packet flow file descriptor"])
        }

        // These values are placeholders the app overrides with real config
        // before starting the tunnel; see the containing app's VPN manager.
        let stack = "gvisor"
        let address = "198.18.0.1/30"
        let dns = "198.18.0.1"
        let options = #"{"mtu":9000,"congestion-controller":""}"#

        let ok = MobileStartTun(fd, stack, address, dns, options)
        if !ok {
            throw NSError(domain: "FlClash", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "MobileStartTun failed"])
        }

        started = true
    }

    func stop() {
        if started {
            MobileStopTun()
            started = false
        }
    }

    /// Forwards a JSON method call to the core and returns the JSON result.
    func invoke(_ json: String) -> String {
        let callback = ResultCallback()
        MobileInvokeMethod(json, callback)
        return callback.result
    }
}

/// A gomobile ResultHandler implementation that captures the single result
/// callback the core delivers.
private final class ResultCallback: NSObject, MobileResultHandler {
    private let lock = NSLock()
    private var buffer = ""

    var result: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func onResult(_ data: Data?, error: NSErrorPointer) -> Bool {
        lock.lock()
        if let data = data {
            buffer = String(data: data, encoding: .utf8) ?? ""
        }
        lock.unlock()
        return false
    }
}
