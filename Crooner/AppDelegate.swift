import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let permissions = PermissionManager()
    let session = RecordingSession()
    private var bubblePanelController:   BubblePanelController?
    private var controlBarController:    ControlBarController?
    private var effectsOverlayController: EffectsOverlayController?
    private var settingsWindow:          NSWindow?
    private var subscriptions = Set<AnyCancellable>()

    // MARK: - Menu bar animation
    private static let animFrameCount = 12
    private var reelFrames: [NSImage] = []
    private var animFrame:  Int = 0
    private var animTimer:  AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupNotifications()
        loadReelFrames()
        bubblePanelController     = BubblePanelController(session: session)
        controlBarController      = ControlBarController(session: session)
        effectsOverlayController  = EffectsOverlayController(session: session)

        // Drive menu bar icon state from session state.
        session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                switch state {
                case .staged:
                    // Dismiss the popover as soon as the user taps Go.
                    self?.popover?.performClose(nil)
                case .countdown:
                    // Safety net: also close if still open when countdown starts.
                    self?.popover?.performClose(nil)
                case .recording:
                    self?.startReelAnimation()
                case .paused:
                    self?.stopReelAnimation()
                default:
                    self?.stopReelAnimation()
                }
            }
            .store(in: &subscriptions)

        Task {
            await permissions.requestAll()   // checks status + requests notifications
        }
    }

    // MARK: - Setup

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let showInFinder = UNNotificationAction(
            identifier: "SHOW_IN_FINDER",
            title:      "Show in Finder",
            options:    .foreground
        )
        let category = UNNotificationCategory(
            identifier:          "RECORDING_SAVED",
            actions:             [showInFinder],
            intentIdentifiers:   [],
            options:             []
        )
        center.setNotificationCategories([category])
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image  = staticReelIcon()
        button.action = #selector(togglePopover)
        button.target = self
    }

    // MARK: - Reel icon helpers

    private func staticReelIcon() -> NSImage? {
        guard let img = NSImage(named: "MenuBarIcon") else {
            // Fallback to SF Symbol if asset is missing (e.g. before first xcodegen run).
            return NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Crooner")
        }
        img.isTemplate = true
        return img
    }

    private func loadReelFrames() {
        reelFrames = (0..<Self.animFrameCount).compactMap { i in
            guard let img = NSImage(named: "reel_frame_\(String(format: "%02d", i))") else {
                return nil
            }
            img.isTemplate = true
            return img
        }
    }

    private func startReelAnimation() {
        guard !reelFrames.isEmpty else { return }
        animFrame = 0
        // ~10 fps → full 360° rotation in ~1.2 s
        animTimer = Timer.publish(every: 0.08, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                animFrame = (animFrame + 1) % Self.animFrameCount
                statusItem?.button?.image = reelFrames[animFrame]
            }
    }

    private func stopReelAnimation() {
        animTimer = nil
        statusItem?.button?.image = staticReelIcon()
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 325)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(onOpenSettings: { [weak self] in self?.openSettings() })
                .environmentObject(permissions)
                .environmentObject(session)
        )
        self.popover = popover
    }

    // MARK: - Actions

    /// Opens (or focuses) the Settings window.  Using an explicit NSWindow is
    /// more reliable than `showSettingsWindow:` for `.accessory` policy apps,
    /// which have no app menu and don't always get activation for free.
    func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: SettingsView().environmentObject(session)
            )
            let window = NSWindow(contentViewController: controller)
            window.title                = "Crooner Settings"
            window.styleMask            = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        // orderFrontRegardless bypasses activation-policy restrictions that
        // prevent makeKeyAndOrderFront from working in .accessory apps.
        settingsWindow?.orderFrontRegardless()
        settingsWindow?.makeKey()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {

    /// Called when the user taps a notification action while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == "SHOW_IN_FINDER",
           let path = response.notification.request.content.userInfo["fileURL"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }

    /// Allow notifications to appear as banners even when the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
