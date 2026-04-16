import AppKit
import CoreGraphics

// MARK: - Public entry point

/// Presents a full-screen drag overlay and returns the selected region in
/// SCKit point coordinates (origin top-left, matching SCStreamConfiguration.sourceRect).
/// Returns nil if the user cancels (Escape) or the selection is smaller than 100 × 100.
@MainActor
final class AreaSelectorOverlay {
    private static var activeWindow: OverlayWindow?

    static func selectArea(on screen: NSScreen) async -> CGRect? {
        await withCheckedContinuation { continuation in
            let window = OverlayWindow(screen: screen) { result in
                activeWindow = nil
                continuation.resume(returning: result)
            }
            activeWindow = window          // retain until completion
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Overlay window

final class OverlayWindow: NSWindow {
    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level                = .screenSaver
        backgroundColor      = .clear
        isOpaque             = false
        ignoresMouseEvents   = false
        collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary]

        contentView = OverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            screenHeight: screen.frame.height
        ) { [weak self] result in
            self?.orderOut(nil)
            completion(result)
        }
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - Overlay view

private final class OverlayView: NSView {
    private let screenHeight: CGFloat
    private let onComplete: (CGRect?) -> Void

    private var startPoint:   CGPoint?
    private var currentPoint: CGPoint?
    private var isActive = false

    init(frame: NSRect, screenHeight: CGFloat, onComplete: @escaping (CGRect?) -> Void) {
        self.screenHeight = screenHeight
        self.onComplete   = onComplete
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dim the full screen
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(bounds)

        guard isActive, let rect = normalizedRect, rect.width > 1, rect.height > 1 else { return }

        // Punch a clear hole for the selection
        ctx.setBlendMode(.clear)
        ctx.fill(rect)
        ctx.setBlendMode(.normal)

        // Selection border
        let accent = NSColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 1.0)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(rect.insetBy(dx: 1, dy: 1))

        // Corner handles
        drawHandles(in: rect, color: accent, ctx: ctx)

        // Dimensions label
        drawLabel(for: rect)
    }

    private func drawHandles(in rect: CGRect, color: NSColor, ctx: CGContext) {
        let s: CGFloat = 8
        ctx.setFillColor(color.cgColor)
        for pt in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                   CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            ctx.fill(CGRect(x: pt.x - s/2, y: pt.y - s/2, width: s, height: s))
        }
    }

    private func drawLabel(for rect: CGRect) {
        let text  = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str    = NSAttributedString(string: text, attributes: attrs)
        let sz     = str.size()
        let pad: CGFloat = 5
        let lw = sz.width + pad * 2
        let lh = sz.height + pad

        // Below the selection rect; fall inside if too close to the screen bottom
        let ly = rect.minY > lh + 6 ? rect.minY - lh - 4 : rect.minY + 4
        let lx = min(rect.maxX - lw, bounds.maxX - lw - 4)
        let bg = CGRect(x: lx, y: ly, width: lw, height: lh)

        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).apply {
            NSColor.black.withAlphaComponent(0.72).setFill()
            $0.fill()
        }
        str.draw(at: CGPoint(x: bg.minX + pad, y: bg.minY + pad / 2))
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        startPoint   = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        isActive     = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let rect = normalizedRect, rect.width >= 100, rect.height >= 100 else {
            // Too small — reset, let user try again
            startPoint = nil; currentPoint = nil; isActive = false
            needsDisplay = true
            return
        }
        onComplete(scKitRect(from: rect))
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else { return }   // Escape
        onComplete(nil)
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Coordinate helpers

    private var normalizedRect: CGRect? {
        guard let s = startPoint, let c = currentPoint else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(c.x - s.x),   height: abs(c.y - s.y))
    }

    /// NSView uses bottom-left origin; SCKit sourceRect uses top-left origin.
    private func scKitRect(from v: CGRect) -> CGRect {
        CGRect(x: v.minX, y: screenHeight - v.maxY, width: v.width, height: v.height)
    }
}

// MARK: - NSBezierPath convenience

private extension NSBezierPath {
    func apply(_ block: (NSBezierPath) -> Void) { block(self) }
}
