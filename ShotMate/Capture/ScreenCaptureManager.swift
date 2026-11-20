import AppKit
import ScreenCaptureKit

/// One display's frozen contents at the moment the shortcut was pressed.
struct CapturedScreen {
    let screen: NSScreen
    /// Full backing-pixel resolution (e.g. 2× the point size on Retina).
    let image: CGImage
}

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
@MainActor
final class ScreenCaptureManager {
    static let shared = ScreenCaptureManager()

    private var warmUpTimer: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.warmUp() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.warmUp() }
        }
    }

    /// Runs a throwaway capture so the first real one doesn't pay for cold ScreenCaptureKit
    /// startup. The warm state fades after tens of seconds idle (first capture ~130ms warm
    /// vs 240-330ms cold), so it repeats on a timer.
    func warmUp() {
        guard ScreenPermission.isGranted else { return }
        if warmUpTimer == nil {
            warmUpTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.warmUp() }
            }
            warmUpTimer?.tolerance = 3
        }
        let origin = CGDisplayBounds(CGMainDisplayID()).origin
        Task { _ = try? await SCScreenshotManager.captureImage(in: CGRect(origin: origin, size: CGSize(width: 2, height: 2))) }
    }

    /// Captures by display rect, which skips the SCShareableContent lookup and filter setup
    /// and so is the fastest ScreenCaptureKit path. It never includes the cursor.
    func captureAllScreens() async throws -> [CapturedScreen] {
        let screens = NSScreen.screens.compactMap { screen -> (NSScreen, CGRect)? in
            screen.displayID.map { (screen, CGDisplayBounds($0)) }
        }
        guard !screens.isEmpty else { throw CaptureError.noDisplays }

        do {
            return try await withThrowingTaskGroup(of: CapturedScreen.self) { group in
                for (screen, bounds) in screens {
                    group.addTask {
                        CapturedScreen(screen: screen, image: try await SCScreenshotManager.captureImage(in: bounds))
                    }
                }
                var results: [CapturedScreen] = []
                for try await result in group {
                    results.append(result)
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
