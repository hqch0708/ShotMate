import AppKit
import Carbon.HIToolbox
import Foundation
import os

/// Timing logs for the hotkey-to-screenshot path, appended to
/// ~/Library/Logs/ShotMate/latency.log and mirrored to the unified log
/// (subsystem com.sentosh.ShotMate, category latency).
enum LatencyLog {
    private static let logger = Logger(subsystem: "com.sentosh.ShotMate", category: "latency")
    private static let queue = DispatchQueue(label: "com.sentosh.ShotMate.latency-log", qos: .utility)
    /// Past this size the file is moved to latency.log.1, replacing any earlier one.
    private static let maxFileSize = 2_000_000

    static let fileURL: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/ShotMate/latency.log")

    private static var lastCaptureUptime: TimeInterval?

    /// Writes off the calling thread so logging never adds to the latency it measures.
    static func write(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        logger.info("\(message, privacy: .public)")
        queue.async { append(line) }
    }

    static func logLaunch() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let displays = NSScreen.screens
            .map { "\(Int($0.frame.width * $0.backingScaleFactor))x\(Int($0.frame.height * $0.backingScaleFactor))" }
            .joined(separator: ",")
        write("launch v\(version) macOS \(system) displays=\(displays)")
    }

    /// How long a hotkey event waited between the system posting it and our handler running.
    static func logHotkeyDelivery(of event: EventRef) {
        let delayMs = (ProcessInfo.processInfo.systemUptime - GetEventTime(event)) * 1000
        write("hotkey delivery=\(String(format: "%.1f", delayMs))ms")
    }

    /// Seconds since the previous capture began, or nil for the first one since launch.
    static func idleSinceLastCapture() -> TimeInterval? {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastCaptureUptime = now }
        return lastCaptureUptime.map { now - $0 }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > maxFileSize {
            let backup = fileURL.appendingPathExtension("1")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: fileURL, to: backup)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL), let data = line.data(using: .utf8) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// Collects cumulative timestamps for one capture, measured from when the hotkey handler began.
struct CaptureTrace {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant
    private let idle: TimeInterval?
    private var marks: [(name: String, elapsedMs: Double)] = []

    /// `tracksIdle: false` makes a placeholder that doesn't count as a capture.
    init(tracksIdle: Bool = true) {
        origin = clock.now
        idle = tracksIdle ? LatencyLog.idleSinceLastCapture() : nil
    }

    mutating func mark(_ name: String) {
        let elapsed = clock.now - origin
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        marks.append((name, ms))
    }

    func log(_ outcome: String) {
        let summary = marks.map { "\($0.name)=\(String(format: "%.1f", $0.elapsedMs))ms" }.joined(separator: " ")
        let idleText = idle.map { String(format: "%.0f", $0) + "s" } ?? "first"
        LatencyLog.write("capture \(outcome) idle=\(idleText) \(summary)")
    }
}
