import Flutter
import UIKit
import NetworkExtension

@main
@objc class AppDelegate: FlutterAppDelegate {
    private static let vpnChannel = "com.follow.clash/ios_vpn"
    private static let coreChannel = "com.follow.clash/core"

    /// The App Group the app shares with the packet-tunnel extension. The core
    /// runs inside the extension's sandbox, so the data directory has to be
    /// inside this container for both processes to reach the same files.
    private static let appGroupId = "group.com.follow.clash"

    /// The data directory the core works in, mirrored by `VpnCore.groupHomeDir`
    /// on the extension side. Keep the two in step: if they disagree the core
    /// reads a directory the app never wrote to.
    static func groupHomeDir() -> String? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else {
            return nil
        }
        return container
            .appendingPathComponent("Library/Application Support/flclash", isDirectory: true)
            .path
    }

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        let channel = FlutterMethodChannel(
            name: Self.vpnChannel,
            binaryMessenger: controller.binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }

        // The Go core lives inside the packet-tunnel extension, so core method
        // calls are relayed through sendProviderMessage and answered by the
        // extension's handleAppMessage.
        let core = FlutterMethodChannel(
            name: Self.coreChannel,
            binaryMessenger: controller.binaryMessenger
        )
        core.setMethodCallHandler { [weak self] call, result in
            self?.handleCore(call, result: result)
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - Method channel dispatch

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getStatus":
            getStatus(result)
        case "saveConfig":
            let args = call.arguments as? [String: Any] ?? [:]
            saveConfig(args, result: result)
        case "start":
            let args = call.arguments as? [String: Any] ?? [:]
            start(args, result: result)
        case "stop":
            stop(result)
        case "getRunTime":
            result(runTime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0)
        case "setRunTime":
            let args = call.arguments as? [String: Any] ?? [:]
            if let ts = args["timestamp"] as? Double {
                runTime = Date(timeIntervalSince1970: ts / 1000)
            }
            result(nil)
        case "requestPermission":
            requestPermission(result)
        case "getHomeDir":
            // The Dart side asks for this instead of path_provider's app
            // container, which the extension cannot read.
            result(Self.groupHomeDir())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private var runTime: Date?

    // MARK: - VPN status

    private func getStatus(_ result: @escaping FlutterResult) {
        Task {
            let status = await NEVPNManager.shared().loadFromPreferencesWithCompletionWrapper()
            let connected = status == .connected
            let connecting = status == .connecting
            result([
                "connected": connected,
                "connecting": connecting,
                "running": connected || connecting,
            ])
        }
    }

    // MARK: - Save config

    private func saveConfig(_ args: [String: Any], result: @escaping FlutterResult) {
        let manager = NEVPNManager.shared()
        manager.loadFromPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                result(FlutterError(code: "load_failed", message: error.localizedDescription, details: nil))
                return
            }

            let proto = NETunnelProviderProtocol()
            proto.serverAddress = args["serverAddress"] as? String ?? "127.0.0.1"
            proto.providerBundleIdentifier = "com.follow.clash.FlClashService"
            proto.disconnectOnSleep = args["disconnectOnSleep"] as? Bool ?? false

            // Pass the Go core config through to the extension.
            var providerConfig: [String: Any] = [
                "stack": args["stack"] as? String ?? "gvisor",
                "address": args["address"] as? String ?? "198.18.0.1/30",
                "dns": args["dns"] as? String ?? "198.18.0.1",
            ]
            // Leave the key out when the caller has no home dir: the extension
            // treats a missing key as "use the App Group container", but an
            // empty string would be taken literally as its data path.
            if let homeDir = args["homeDir"] as? String, !homeDir.isEmpty {
                providerConfig["home-dir"] = homeDir
            }
            if let options = args["options"] as? [String: Any] {
                for (k, v) in options { providerConfig[k] = v }
            }
            proto.providerConfiguration = providerConfig

            manager.protocolConfiguration = proto
            manager.localizedDescription = "FlClash"
            manager.isEnabled = true

            manager.saveToPreferences { error in
                if let error = error {
                    result(FlutterError(code: "save_failed", message: error.localizedDescription, details: nil))
                } else {
                    result(true)
                }
            }
        }
    }

    // MARK: - Start / Stop

    private func start(_ args: [String: Any], result: @escaping FlutterResult) {
        let manager = NEVPNManager.shared()
        manager.loadFromPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                result(FlutterError(code: "load_failed", message: error.localizedDescription, details: nil))
                return
            }
            self.runTime = Date()
            do {
                try manager.connection.startVPNTunnel()
                result(true)
            } catch {
                result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
            }
        }
    }

    private func stop(_ result: @escaping FlutterResult) {
        NEVPNManager.shared().connection.stopVPNTunnel()
        result(true)
    }

    // MARK: - Permission

    private func requestPermission(_ result: @escaping FlutterResult) {
        let manager = NEVPNManager.shared()
        manager.loadFromPreferences { error in
            if let error = error {
                result(FlutterError(code: "load_failed", message: error.localizedDescription, details: nil))
                return
            }
            // The system VPN permission dialog is triggered by saving an
            // enabled config. A minimal placeholder config is enough.
            let proto = NETunnelProviderProtocol()
            proto.serverAddress = "127.0.0.1"
            proto.providerBundleIdentifier = "com.follow.clash.FlClashService"
            manager.protocolConfiguration = proto
            manager.localizedDescription = "FlClash"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error = error {
                    result(FlutterError(code: "permission_failed", message: error.localizedDescription, details: nil))
                } else {
                    result(true)
                }
            }
        }
    }
}

// MARK: - Core relay
extension AppDelegate {

    /// Relays a JSON core method call (e.g. "getConfig", "changeProxy") to the
    /// Go core inside the tunnel extension and returns its raw JSON reply.
    func handleCore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "invokeMethod" else {
            result(FlutterMethodNotImplemented)
            return
        }
        guard let payload = call.arguments as? String,
              let data = payload.data(using: .utf8) else {
            result(FlutterError(code: "bad_arguments",
                message: "expected a JSON string", details: nil))
            return
        }
        guard let session = NEVPNManager.shared().connection as? NETunnelProviderSession else {
            result(FlutterError(code: "no_session",
                message: "the tunnel is not configured or not running", details: nil))
            return
        }
        do {
            try session.sendProviderMessage(data) { response in
                // The reply arrives on a background queue; FlutterResult must
                // be invoked on the main thread.
                DispatchQueue.main.async {
                    if let response = response {
                        result(FlutterStandardTypedData(bytes: response))
                    } else {
                        result(nil)
                    }
                }
            }
        } catch {
            result(FlutterError(code: "send_failed",
                message: error.localizedDescription, details: nil))
        }
    }
}

// MARK: - async/await helper for loadFromPreferences

extension NEVPNManager {
    func loadFromPreferencesWithCompletionWrapper() async -> NEVPNStatus {
        await withCheckedContinuation { continuation in
            self.loadFromPreferences { _ in
                continuation.resume(returning: self.connection.status)
            }
        }
    }
}
