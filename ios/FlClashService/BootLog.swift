import Foundation

/// Append-only log of the tunnel's startup, written inside the App Group
/// container the containing app can read.
///
/// The extension has no console a user can reach: `NSLog` output only shows up
/// in Xcode, which a sideloaded build never has. Without a file, a provider
/// that stops halfway leaves nothing behind, and the app can only report that a
/// core call went unanswered -- true, but it says nothing about what to fix.
/// Every stage of `startTunnel` therefore writes one line here, and the app
/// shows the tail of it whenever the core stays silent.
enum BootLog {

    static let appGroup = "group.com.follow.clash"

    /// The log lives beside the core's data directory so a single path rule
    /// covers both processes.
    static var path: String? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            return nil
        }
        let dir = container.appendingPathComponent(
            "Library/Application Support/flclash",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir.appendingPathComponent("boot.log").path
    }

    /// Keeps the file small enough to read back in one channel reply.
    private static let maxBytes = 48 * 1024

    private static let queue = DispatchQueue(label: "com.follow.clash.bootlog")

    /// Records one step. Never throws and never blocks the caller: a failure to
    /// log must not become a failure to start the tunnel.
    static func write(_ message: String) {
        NSLog("[FlClash] %@", message)
        queue.async {
            guard let path = path else { return }
            let stamp = Self.formatter.string(from: Date())
            guard let data = "\(stamp) \(message)\n".data(using: .utf8) else {
                return
            }
            let url = URL(fileURLWithPath: path)
            if !FileManager.default.fileExists(atPath: path) {
                try? data.write(to: url)
                return
            }
            Self.trimIfNeeded(path: path, url: url)
            guard let handle = try? FileHandle(forWritingTo: url) else {
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Drops the oldest half once the file outgrows [maxBytes]: the newest
    /// lines are the ones that describe the failure being investigated.
    private static func trimIfNeeded(path: String, url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let kept = data.suffix(maxBytes / 2)
        try? Data(kept).write(to: url)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
