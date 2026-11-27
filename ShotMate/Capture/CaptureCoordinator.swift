import AppKit

/// Runs one capture session from hotkey to clipboard. Each display gets its own
/// overlay, and the selection is confined to the display the drag starts on.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    /// Lets the menu bar close its popover before the screen is frozen.
    var willBeginCapture: (() -> Void)?

    private(set) var isCapturing = false
    private var windows: [CaptureOverlayWindow] = []
    private var overlays: [CaptureOverlayView] = []
    private var previousApp: NSRunningApplication?
    private var screenObserver: NSObjectProtocol?
    /// Identifies the in-flight capture so a late result from an abandoned one is dropped.
    private var captureGeneration = 0
    private var trace = CaptureTrace(tracksIdle: false)

    /// Whether the frozen screenshots have replaced the transparent placeholder overlays.
    private var isRevealed = false

    /// Longest a capture may take before it is abandoned, so one stalled ScreenCaptureKit
    /// call can't leave invisible overlays up and the shortcut dead until relaunch.
    private static let captureTimeout: Duration = .seconds(3)

    private init() {}

    func start() {
        guard !isCapturing else { return }
        trace = CaptureTrace()
        guard ScreenPermission.isGranted else {
            PermissionWindowController.shared.show()
            return
        }

        isCapturing = true
        willBeginCapture?()
        HUD.dismiss()
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        trace.mark("prepared")

        captureGeneration += 1
        let generation = captureGeneration

        // The request goes out before any window work and off the main thread: building and
        // showing full-screen overlays can stall the main thread for hundreds of ms, which
        // would otherwise delay the capture too.
        let screens = NSScreen.screens.filter { $0.displayID != nil }
        let targets = ScreenCaptureManager.targets(for: screens)
        let capture = Task.detached { try await ScreenCaptureManager.capture(targets) }

        // Overlays go up before the capture finishes: ScreenCaptureKit takes 130-300ms, and
        // waiting for it made the shortcut feel sluggish. They stay transparent until then.
        showOverlays(on: screens)

        Task { @MainActor in
            do {
                let images = try await capture.value
                guard generation == captureGeneration, isCapturing else { return }
                trace.mark("captured")
                reveal(images)
            } catch CaptureError.permissionDenied {
                guard generation == captureGeneration else { return }
                close(restoreFocus: false)
                PermissionWindowController.shared.show()
            } catch {
                guard generation == captureGeneration else { return }
                close(restoreFocus: false)
                Alerts.show(error)
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: Self.captureTimeout)
            guard generation == captureGeneration, isCapturing, !isRevealed else { return }
            trace.mark("timeout")
            trace.log("timed out")
            captureGeneration += 1
            close(restoreFocus: false)
        }
    }

    func cancel() {
        close(restoreFocus: true)
    }

    /// Returns false when another display already holds annotations, so a stray
    /// drag on a second monitor can't discard the user's work.
    func overlayWillBeginSelection(_ overlay: CaptureOverlayView) -> Bool {
        let others = overlays.filter { $0 !== overlay }
        guard !others.contains(where: \.hasAnnotations) else { return false }
        others.filter(\.hasSelection).forEach { $0.clearSelection() }
        return true
    }

    func finish(_ output: CaptureOutput, from overlay: CaptureOverlayView) {
        guard let screenshot = overlay.renderScreenshot() else { return }

        let action: AfterCaptureAction = switch output {
        case .primary: AppSettings.shared.afterCapture
        case .copy: .copy
        case .saveAs: .save
        }

        if output == .saveAs {
            saveWithPanel(screenshot)
            return
        }

        do {
            switch action {
            case .copy:
                try ClipboardManager.copy(screenshot)
                close(restoreFocus: true)
                HUD.show("Copied to Clipboard", symbol: "checkmark.circle.fill")
            case .save:
                let url = try ImageSaver.saveToDefaultLocation(screenshot)
                close(restoreFocus: true)
                HUD.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)", symbol: "checkmark.circle.fill")
            case .copyAndSave:
                try ClipboardManager.copy(screenshot)
                _ = try ImageSaver.saveToDefaultLocation(screenshot)
                close(restoreFocus: true)
                HUD.show("Copied and Saved", symbol: "checkmark.circle.fill")
            }
        } catch {
            close(restoreFocus: true)
            Alerts.show(error)
        }
    }

    // MARK: - Private

    private func showOverlays(on screens: [NSScreen]) {
        let toolState = AnnotationToolState()
        for screen in screens {
            let window = CaptureOverlayWindow(screen: screen)
            let view = CaptureOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), toolState: toolState)
            view.coordinator = self
            window.contentView = view
            window.initialFirstResponder = view
            windows.append(window)
            overlays.append(view)
        }
        trace.mark("windowsBuilt")
        // Not activating yet: that would turn the frontmost app's windows inactive before
        // the screenshot is taken.
        windows.forEach { $0.orderFrontRegardless() }
        NSCursor.crosshair.set()
        trace.mark("overlayShown")

        // Unplugging a monitor mid-capture would leave overlays misaligned.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    private func reveal(_ images: [CGDirectDisplayID: CGImage]) {
        for (window, view) in zip(windows, overlays) {
            guard let image = window.screen?.displayID.flatMap({ images[$0] }) else { continue }
            view.show(image)
            window.becomeOpaque()
        }
        isRevealed = true
        trace.mark("frozenShown")

        NSApp.activate(ignoringOtherApps: true)
        let mouseLocation = NSEvent.mouseLocation
        let key = windows.first(where: { $0.frame.contains(mouseLocation) }) ?? windows.first
        key?.makeKey()
        if let view = key?.contentView as? CaptureOverlayView {
            key?.makeFirstResponder(view)
            view.updateCursor()
        }
        trace.mark("ready")
        trace.log("ok")
    }

    private func saveWithPanel(_ screenshot: RenderedScreenshot) {
        windows.forEach { $0.orderOut(nil) }
        let result = ImageSaver.saveWithPanel(screenshot)
        switch result {
        case .saved:
            close(restoreFocus: true)
            HUD.show("Saved", symbol: "checkmark.circle.fill")
        case .cancelled:
            // Back to the capture, annotations intact.
            windows.forEach { $0.orderFrontRegardless() }
            windows.first(where: { ($0.contentView as? CaptureOverlayView)?.hasSelection == true })?.makeKey()
        case .failed(let error):
            close(restoreFocus: true)
            Alerts.show(error)
        }
    }

    private func close(restoreFocus: Bool) {
        guard isCapturing else { return }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        overlays.removeAll()
        isCapturing = false
        isRevealed = false
        NSCursor.arrow.set()

        // Hand focus straight back to the app the user was in, ready for ⌘V.
        if restoreFocus, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil
    }
}
