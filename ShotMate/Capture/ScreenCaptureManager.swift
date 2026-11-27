import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "ShotMate needs Screen Recording permission to capture your screen."
        case .noDisplays:
            "ShotMate couldn't find a display to capture. If you just connected or disconnected a monitor, try again."
        case .failed:
            "ShotMate couldn't capture the screen. Please try again."
        }
    }
}

/// Captures every connected display with ScreenCaptureKit at native pixel density.
enum ScreenCaptureManager {
    /// A display to capture, reduced to Sendable values so the request can start off the main thread.
    struct Target: Sendable {
        let displayID: CGDirectDisplayID
        let bounds: CGRect
    }

    static func targets(for screens: [NSScreen]) -> [Target] {
        screens.compactMap { screen in
            screen.displayID.map { Target(displayID: $0, bounds: CGDisplayBounds($0)) }
        }
    }

    /// Captures by display rect, which skips the SCShareableContent lookup and filter setup
    /// and so is the fastest ScreenCaptureKit path. It never includes the cursor.
    /// Not main-actor isolated: a busy main thread must not delay the request.
    static func capture(_ targets: [Target]) async throws -> [CGDirectDisplayID: CGImage] {
        guard !targets.isEmpty else { throw CaptureError.noDisplays }

        do {
            return try await withThrowingTaskGroup(of: (CGDirectDisplayID, CGImage).self) { group in
                for target in targets {
                    group.addTask {
                        (target.displayID, try await SCScreenshotManager.captureImage(in: target.bounds))
                    }
                }
                var results: [CGDirectDisplayID: CGImage] = [:]
                for try await (id, image) in group {
                    results[id] = image
                }
                return results
            }
        } catch {
            throw ScreenPermission.isGranted ? CaptureError.failed(error) : CaptureError.permissionDenied
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
