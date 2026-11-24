import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    /// Held for the app's lifetime: an idle menu bar app gets App Nap'd, and its timers
    /// and ScreenCaptureKit calls then wake late, so the shortcut feels a beat behind.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, even when launched outside a bundle (e.g. from Xcode).
        NSApp.setActivationPolicy(.accessory)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Responsive global screenshot shortcut"
        )
        MainMenu.install()
        LatencyLog.logLaunch()

        let menuBar = MenuBarController(onCapture: { CaptureCoordinator.shared.start() })
        self.menuBar = menuBar

        CaptureCoordinator.shared.willBeginCapture = { [weak menuBar] in
            menuBar?.closePopover()
        }

        GlobalHotkeyManager.shared.onTrigger = {
            MainActor.assumeIsolated { CaptureCoordinator.shared.start() }
        }
        registerSavedShortcut()

        LaunchAtLogin.shared.applyDefaultOnFirstLaunch()

        if !ScreenPermission.isGranted && !ScreenPermission.hasShownOnboarding {
            ScreenPermission.hasShownOnboarding = true
            PermissionWindowController.shared.show()
        }
    }

    private func registerSavedShortcut() {
        let shortcut = AppSettings.shared.shortcut
        do {
            try GlobalHotkeyManager.shared.register(shortcut)
        } catch {
            Alerts.show(
                title: "Shortcut unavailable",
                message: "Another app is already using \(shortcut.displayString). Click the ShotMate icon in the menu bar to choose a different shortcut."
            )
        }
    }
}

/// LSUIElement apps have no visible menu bar, but a main menu is still needed so
/// standard editing shortcuts (⌘C, ⌘V, ⌘A, ⌘Z) work inside text fields.
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit ShotMate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
