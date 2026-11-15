import Dispatch
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

    // MARK: - Footprint

    /// The size the kernel charges this process against its memory budget.
    ///
    /// `phys_footprint` from TASK_VM_INFO is the figure jetsam acts on: it
    /// counts every dirty page the process owns -- the Go heap, the tun stack's
    /// buffers, the TLS session caches and every loaded library -- while the
    /// core can only report its own heap. A tunnel that dies with a modest Go
    /// heap and a footprint at the ceiling is therefore not a Go leak, and these
    /// two numbers next to each other are what tells the two apart.
    static func footprintMiB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    /// Records the footprint at one named step.
    ///
    /// The extension has been killed three times now, always within seconds of
    /// a large allocation, and none of those kills left a single line behind --
    /// a process the kernel removes writes nothing on its way out. A footprint
    /// sampled every few seconds turns that silence into a slope: the last line
    /// before the log stops is the number the process died at.
    static func writeMemory(_ step: String) {
        guard let footprint = footprintMiB() else { return }
        write(String(format: "mem: %@: footprint %.1f MiB", step, footprint))
    }
}

/// Samples the process footprint on a short period while the tunnel is up.
///
/// Deliberately cheap: one `task_info` call and one appended line every few
/// seconds, on a utility queue, so the watchdog can never be the reason the
/// process needs the memory it is measuring.
final class MemoryWatchdog {
    private var timer: DispatchSourceTimer?
    private var samples = 0

    /// One sample a second for the first minute, then one every half minute.
    ///
    /// The kills happen within seconds of boot, so that is where the resolution
    /// has to be. Sampling at that rate forever would fill the log's 48 KiB
    /// with nothing but footprint lines -- and the tail of that log is the only
    /// diagnostic a sideloaded build has -- so the slow rate takes over once
    /// the boot window has passed.
    private static let fastInterval: TimeInterval = 3
    private static let slowInterval: TimeInterval = 30
    private static let fastSamples = 20

    func start() {
        stop()
        samples = 0
        schedule(interval: Self.fastInterval)
    }

    private func schedule(interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility))
        // Fire immediately: the first sample is the baseline the later ones are
        // compared against, and a tunnel that dies during boot would otherwise
        // have no line at all.
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            BootLog.writeMemory("tick")
            guard let self = self else { return }
            self.samples += 1
            if self.samples == Self.fastSamples {
                self.schedule(interval: Self.slowInterval)
            }
        }
        timer.resume()
        self.timer?.cancel()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
