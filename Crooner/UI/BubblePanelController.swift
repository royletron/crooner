import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

// MARK: - Controller

/// Manages a frameless floating panel that shows `WebcamBubbleView`.
///
/// The panel appears once the user picks a capture source, defaults to the
/// bottom-right corner of the capture area, and can be dragged freely within
/// that area.  Switching sources resets position to the default corner.
///
/// A 150 ms heartbeat (`tick()`) serves two purposes:
///   1. Re-asserts the panel to the front of the screen stack on every tick so
///      that macOS can never permanently hide it regardless of app-switch behaviour.
///   2. Tracks movement and resizing of the captured window (requirement #6) and
///      adjusts the bubble's position and constraint area accordingly.
@MainActor
final class BubblePanelController {
    private weak var session: RecordingSession?
    private var panel:    BubblePanel?
    private var dragView: DragHandlerView?
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat:      AnyCancellable?

    /// Bubble centre in AppKit screen coords set by free drag; nil = use default corner.
    private var freeDragCenter: CGPoint?

    /// Last known AppKit frame of the captured window, used to detect movement/resize.
    private var lastSourceFrame: CGRect?

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
            .sink { [weak self] _ in
                guard let self else { return }
                freeDragCenter  = nil
                lastSourceFrame = nil
                update()
            }
            .store(in: &subscriptions)

        session.$bubbleEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subscriptions)

        session.$bubbleSize
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subscriptions)

        // Webcam bubble only appears once the user is actively recording.
        session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &subscriptions)
    }

    // MARK: - State sync

    private func update() {
        guard let session else { hidePanel(); return }

        // Show the webcam bubble from .staged onwards so the user can frame
        // themselves before hitting Record.  Hide during idle and finishing.
        switch session.state {
        case .staged, .countdown, .recording, .paused:
            break
        default:
            hidePanel()
            return
        }

        guard session.bubbleEnabled, let source = session.selectedSource else {
            hidePanel()
            return
        }
        let area = captureArea(for: source)
        dragView?.constraintArea = area
        showOrMove(size: session.bubbleSize, corner: session.bubbleCorner, in: area)
    }

    // MARK: - Heartbeat

    /// Fired every 150 ms while a panel is live.
    ///
    /// Step 1 — visibility: unconditionally re-asserts `orderFrontRegardless()`.
    /// macOS can hide `.accessory`-app windows through several paths that bypass
    /// both `canHide = false` and the `orderOut` override; calling this on every
    /// tick means the panel is never gone for more than one heartbeat interval.
    ///
    /// Step 2 — window tracking: for `.window` capture sources, fetches the
    /// current frame from the window server and repositions the bubble if the
    /// captured window has moved or resized.
    private func tick() {
        guard let panel else { return }

        // Step 1 — always bring to front.
        panel.orderFrontRegardless()

        // Step 2 — window tracking (skip while the user is dragging the bubble).
        guard let session,
              session.bubbleEnabled,
              let source = session.selectedSource,
              case .window(let scWindow) = source,
              !(dragView?.isDragging ?? false) else { return }

        guard let liveFrame = Self.liveFrame(for: scWindow) else { return }

        defer { lastSourceFrame = liveFrame }

        guard let lastFrame = lastSourceFrame, liveFrame != lastFrame else { return }

        if liveFrame.size != lastFrame.size {
            // Window resized — reset bubble to default corner within the new bounds.
            freeDragCenter = nil
        } else {
            // Window moved — translate the bubble by the same delta so it stays
            // in the same relative position within the window.
            let dx = liveFrame.minX - lastFrame.minX
            let dy = liveFrame.minY - lastFrame.minY
            if let c = freeDragCenter {
                freeDragCenter = CGPoint(x: c.x + dx, y: c.y + dy)
            }
        }

        dragView?.constraintArea = liveFrame
        update()
    }

    /// Returns the current frame of `window` in AppKit screen coordinates by
    /// querying the window server directly — the frame on `SCWindow` is stale
    /// after the window has been moved or resized.
    private static func liveFrame(for window: SCWindow) -> CGRect? {
        guard
            let list  = CGWindowListCopyWindowInfo([.optionIncludingWindow],
                                                   window.windowID) as? [[String: Any]],
            let info  = list.first,
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
        else { return nil }

        let x = bounds["X"] ?? 0
        let y = bounds["Y"] ?? 0   // CG: y-down from top of primary screen
        let w = bounds["Width"]  ?? 0
        let h = bounds["Height"] ?? 0
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        // Convert CG → AppKit (y-up from bottom of primary screen)
        return CGRect(x: x, y: primaryH - y - h, width: w, height: h)
    }

    // MARK: - Panel management

    private func showOrMove(size: BubbleSize, corner: BubbleCorner, in area: CGRect) {
        let diameter  = size.diameter
        let pad       = WebcamBubbleView.shadowPadding
        let panelSide = diameter + pad * 2
        let center    = freeDragCenter ?? defaultCenter(corner: corner, in: area, diameter: diameter)
        // Panel is larger than the bubble by `pad` on every side so the drop
        // shadow has room to render; offset the origin so the bubble's centre
        // still lands at `center`.
        let origin    = CGPoint(x: center.x - panelSide / 2, y: center.y - panelSide / 2)

        if let existing = panel {
            if existing.frame.width != panelSide {
                // Size changed — recreate so SwiftUI gets the correct diameter.
                heartbeat         = nil
                existing.isPinned = false
                existing.orderOut(nil)
                panel    = nil
                dragView = nil
                createPanel(origin: origin, diameter: diameter, constraintArea: area)
            } else {
                existing.setFrameOrigin(origin)
                existing.orderFrontRegardless()
            }
        } else {
            createPanel(origin: origin, diameter: diameter, constraintArea: area)
        }
    }

    private func createPanel(origin: CGPoint, diameter: CGFloat, constraintArea: CGRect) {
        let pad        = WebcamBubbleView.shadowPadding
        let panelSide  = diameter + pad * 2
        let panelSize  = CGSize(width: panelSide, height: panelSide)
        let p = BubblePanel(
            contentRect: CGRect(origin: origin, size: panelSize),
            styleMask:   .borderless,
            backing:     .buffered,
            defer:       false
        )
        p.level                = NSWindow.Level(rawValue: Int(NSWindow.Level.screenSaver.rawValue))
        p.backgroundColor      = .clear
        p.isOpaque             = false
        p.hasShadow            = false   // shadow drawn by WebcamBubbleView
        p.collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate    = false   // don't hide when the app becomes inactive
        p.canHide              = false   // don't hide via NSApp.hide(_:)

        let container = NSView(frame: CGRect(origin: .zero, size: panelSize))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: WebcamBubbleView(diameter: diameter))
        hosting.frame            = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        // Drag handler is sized to the bubble only (centred inside the padded
        // panel) so the shadow region around it doesn't accept mouse events.
        let dragFrame = CGRect(x: pad, y: pad, width: diameter, height: diameter)
        let drag = DragHandlerView(frame: dragFrame)
        drag.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        drag.bubbleDiameter   = diameter
        drag.constraintArea   = constraintArea
        drag.onDragMoved      = { [weak self] center in self?.freeDragCenter = center }
        container.addSubview(drag)   // added last → receives mouse events first

        p.contentView = container
        p.orderFrontRegardless()
        p.isPinned = true   // AppKit-level guard against system orderOut calls

        panel    = p
        dragView = drag

        heartbeat = Timer.publish(every: 0.15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func hidePanel() {
        heartbeat        = nil
        lastSourceFrame  = nil
        panel?.isPinned  = false
        panel?.orderOut(nil)
        panel    = nil
        dragView = nil
    }

    // MARK: - Coordinate helpers

    private func captureArea(for source: CaptureSource) -> CGRect {
        // For window sources prefer the live frame so the constraint area is current.
        if case .window(let w) = source, let live = Self.liveFrame(for: w) {
            return live
        }
        return source.appKitScreenFrame()
            ?? NSScreen.main?.frame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    }

    /// Bubble centre for the given corner in AppKit screen coordinates.
    /// `BubbleCorner.position` uses top-left origin, so we flip y into AppKit space.
    private func defaultCenter(corner: BubbleCorner, in area: CGRect, diameter: CGFloat) -> CGPoint {
        let inset    = diameter / 2 + 8
        let tlCenter = corner.position(in: area.size, inset: inset)
        return CGPoint(x: area.minX + tlCenter.x, y: area.maxY - tlCenter.y)
    }
}

// MARK: - NSPanel subclass

private final class BubblePanel: NSPanel {
    /// When true, `orderOut(_:)` calls are no-ops — the panel resists system hiding.
    var isPinned = false

    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }

    override func orderOut(_ sender: Any?) {
        guard !isPinned else { return }
        super.orderOut(sender)
    }
}

// MARK: - Transparent drag-handler overlay

/// A transparent `NSView` that sits on top of the webcam preview and handles
/// drag events.  No snap — the bubble stays wherever the user drops it.
private final class DragHandlerView: NSView {
    /// Called with the bubble's centre in AppKit screen coords during and after drag.
    var onDragMoved: ((CGPoint) -> Void)?
    /// When set, the panel is clamped inside this rect during drag.
    var constraintArea: CGRect?
    /// Diameter of the visible bubble.  The panel is larger than this by a
    /// fixed shadow padding, so the constraint must be expressed in terms of
    /// the bubble — not the panel — to keep the bubble fully inside the area.
    var bubbleDiameter: CGFloat = 0

    private var startMouse:  NSPoint?
    private var startOrigin: NSPoint?

    /// True while a mouse-drag is in progress.
    var isDragging: Bool { startMouse != nil }

    override var acceptsFirstResponder:  Bool { true  }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque:               Bool { false }
    override func draw(_ dirtyRect: NSRect) { /* transparent */ }

    override func mouseDown(with event: NSEvent) {
        startMouse  = NSEvent.mouseLocation
        startOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let sm = startMouse, let so = startOrigin, let window else { return }
        let cur = NSEvent.mouseLocation
        var newOrigin = NSPoint(x: so.x + cur.x - sm.x, y: so.y + cur.y - sm.y)
        if let area = constraintArea {
            // Translate the area into panel-origin space: the panel extends
            // `pad` beyond the bubble on every side.
            let pad = (window.frame.width - bubbleDiameter) / 2
            newOrigin.x = max(area.minX - pad, min(area.maxX - bubbleDiameter - pad, newOrigin.x))
            newOrigin.y = max(area.minY - pad, min(area.maxY - bubbleDiameter - pad, newOrigin.y))
        }
        window.setFrameOrigin(newOrigin)
        reportCenter()
    }

    override func mouseUp(with event: NSEvent) {
        startMouse  = nil
        startOrigin = nil
        reportCenter()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    private func reportCenter() {
        guard let window else { return }
        onDragMoved?(NSPoint(x: window.frame.midX, y: window.frame.midY))
    }
}
