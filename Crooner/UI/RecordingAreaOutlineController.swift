import AppKit
import Combine
import ScreenCaptureKit

// MARK: - Controller

/// Draws a click-through green outline around the captured area while a
/// recording is in progress.  Only shown for `.window` and `.area` sources —
/// for `.fullScreen` the outline would simply trace the screen edge, which
/// adds no useful information.
///
/// State machine matches the webcam bubble: visible during `.countdown`,
/// `.recording`, and `.paused`.  A 150 ms heartbeat re-asserts the panel to
/// the front and tracks movement of the captured window so the outline stays
/// pinned to the recorded region.
@MainActor
final class RecordingAreaOutlineController {
    private weak var session: RecordingSession?
    private var panel:        OutlinePanel?
    private var outlineView:  OutlineView?
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat:    AnyCancellable?

    init(session: RecordingSession) {
        self.session = session
        startObserving()
        update()
    }

    // MARK: - Observation

    private func startObserving() {
        guard let session else { return }

        session.$selectedSource
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subscriptions)

        session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subscriptions)
    }

    // MARK: - State sync

    private func update() {
        guard let session else { hide(); return }

        switch session.state {
        case .countdown, .recording, .paused:
            break
        default:
            hide()
            return
        }

        guard let source = session.selectedSource else { hide(); return }

        // Full-screen capture: skip — the outline would just be the screen edge.
        switch source {
        case .fullScreen:
            hide()
            return
        case .window, .area:
            break
        }

        guard let frame = currentFrame(for: source) else { hide(); return }
        showOrMove(frame: frame)
    }

    // MARK: - Heartbeat

    /// Mirror of `BubblePanelController.tick()`: keep the panel above the
    /// stack and track window movement/resize for `.window` sources.
    private func tick() {
        guard let panel else { return }
        panel.orderFrontRegardless()

        guard let session,
              let source = session.selectedSource,
              let frame  = currentFrame(for: source)
        else { return }

        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            outlineView?.needsDisplay = true
        }
    }

    // MARK: - Frame resolution

    private func currentFrame(for source: CaptureSource) -> CGRect? {
        switch source {
        case .fullScreen:
            return nil
        case .window(let scWindow):
            return Self.liveFrame(for: scWindow)
        case .area:
            return source.appKitScreenFrame()
        }
    }

    /// Same approach as `BubblePanelController.liveFrame(for:)` — query the
    /// window server directly so resizes/moves are reflected immediately.
    private static func liveFrame(for window: SCWindow) -> CGRect? {
        guard
            let list   = CGWindowListCopyWindowInfo([.optionIncludingWindow],
                                                     window.windowID) as? [[String: Any]],
            let info   = list.first,
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
        else { return nil }

        let x = bounds["X"] ?? 0
        let y = bounds["Y"] ?? 0
        let w = bounds["Width"]  ?? 0
        let h = bounds["Height"] ?? 0
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: x, y: primaryH - y - h, width: w, height: h)
    }

    // MARK: - Panel management

    private func showOrMove(frame: CGRect) {
        if let existing = panel {
            existing.setFrame(frame, display: false)
            existing.orderFrontRegardless()
            outlineView?.needsDisplay = true
        } else {
            createPanel(frame: frame)
        }
    }

    private func createPanel(frame: CGRect) {
        let p = OutlinePanel(
            contentRect: frame,
            styleMask:   .borderless,
            backing:     .buffered,
            defer:       false
        )
        p.level                = NSWindow.Level(rawValue: Int(NSWindow.Level.screenSaver.rawValue))
        p.backgroundColor      = .clear
        p.isOpaque             = false
        p.hasShadow            = false
        p.ignoresMouseEvents   = true
        p.collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate    = false
        p.canHide              = false

        let view = OutlineView(frame: CGRect(origin: .zero, size: frame.size))
        view.autoresizingMask = [.width, .height]
        p.contentView = view

        p.orderFrontRegardless()
        p.isPinned = true

        panel       = p
        outlineView = view

        heartbeat = Timer.publish(every: 0.15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func hide() {
        heartbeat       = nil
        panel?.isPinned = false
        panel?.orderOut(nil)
        panel       = nil
        outlineView = nil
    }
}

// MARK: - NSPanel subclass

private final class OutlinePanel: NSPanel {
    var isPinned = false

    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }

    override func orderOut(_ sender: Any?) {
        guard !isPinned else { return }
        super.orderOut(sender)
    }
}

// MARK: - Outline view

/// Draws a green stroke just inside the panel's bounds.  Inset by half the
/// stroke width so the line renders fully inside the captured area instead of
/// straddling the boundary (which would clip half the stroke).
private final class OutlineView: NSView {
    private let strokeWidth: CGFloat = 3
    private let strokeColor = NSColor.systemGreen

    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let inset = strokeWidth / 2
        let rect  = bounds.insetBy(dx: inset, dy: inset)

        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.stroke(rect)
    }
}
