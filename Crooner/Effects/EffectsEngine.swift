import AppKit
import CoreImage
import Foundation

// MARK: - Thread-safe storage (readable from any executor)

/// Lock-guarded snapshot of the data the compositor actor needs.
/// Held as a `let` on `EffectsEngine` so `nonisolated` methods can access it
/// without crossing the `@MainActor` boundary.
private final class EffectsStorage: @unchecked Sendable {
    private let lock = NSLock()

    var particles:    [EffectParticle] = []
    var captureFrame: CGRect           = .zero
    var trailEnabled: Bool             = false
    var clickEnabled: Bool             = false
    var emojiImage:   CIImage?

    func read<T>(_ body: (EffectsStorage) -> T) -> T {
        lock.withLock { body(self) }
    }

    func write(_ body: (EffectsStorage) -> Void) {
        lock.withLock { body(self) }
    }
}

// MARK: - Engine

/// Tracks global mouse and click events, maintaining a live particle list.
///
/// **Consumers:**
/// - `EffectsOverlayView` (main thread / SwiftUI) via `@Published particles`
/// - `CompositorPipeline` (actor) via `nonisolated` snapshot methods
@MainActor
final class EffectsEngine: ObservableObject {

    // MARK: - Settings (kept in sync with AppStorage by RecordingSession)

    var mouseTrailEnabled:   Bool   = false
    var clickCirclesEnabled: Bool   = false
    var trailEmoji:          String = "✨"

    // MARK: - Published state (SwiftUI overlay)

    @Published private(set) var particles: [EffectParticle] = []

    /// AppKit frame of the captured area (y-up, bottom-left of primary screen).
    /// Set when tracking starts; used by the overlay view for coordinate mapping.
    private(set) var captureFrame: CGRect = .zero

    // MARK: - Cross-actor snapshot

    private let storage = EffectsStorage()

    nonisolated func snapshotParticles() -> [EffectParticle] {
        storage.read { $0.particles }
    }

    nonisolated func snapshotMeta() -> (
        captureFrame: CGRect,
        trailEnabled: Bool,
        clickEnabled: Bool,
        emojiImage:   CIImage?
    ) {
        storage.read { s in (s.captureFrame, s.trailEnabled, s.clickEnabled, s.emojiImage) }
    }

    // MARK: - Private state

    private var moveMonitor:   Any?
    private var clickMonitor:  Any?
    private var tickTimer:     Timer?
    private var lastTrailTime: CFTimeInterval = 0

    // MARK: - Lifecycle

    func startTracking(source: CaptureSource) {
        captureFrame = source.appKitScreenFrame() ?? NSScreen.main?.frame ?? .zero
        let emojiCI  = Self.makeEmojiImage(trailEmoji, pointSize: 52)

        storage.write { s in
            s.captureFrame = captureFrame
            s.trailEnabled = mouseTrailEnabled
            s.clickEnabled = clickCirclesEnabled
            s.emojiImage   = emojiCI
        }

        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleMouseMove() }
        }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleClick() }
        }

        // 30 Hz prune loop.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    func stopTracking() {
        if let m = moveMonitor  { NSEvent.removeMonitor(m); moveMonitor  = nil }
        if let c = clickMonitor { NSEvent.removeMonitor(c); clickMonitor = nil }
        tickTimer?.invalidate()
        tickTimer = nil
        particles.removeAll()
        storage.write { s in
            s.particles    = []
            s.emojiImage   = nil
            s.trailEnabled = false
            s.clickEnabled = false
        }
    }

    // MARK: - Event handlers

    private func handleMouseMove() {
        guard mouseTrailEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastTrailTime > 0.035 else { return }   // ≈ 28 particles/sec
        lastTrailTime = now
        spawnParticle(.trail(emoji: trailEmoji), at: NSEvent.mouseLocation)
    }

    private func handleClick() {
        guard clickCirclesEnabled else { return }
        spawnParticle(.click, at: NSEvent.mouseLocation)
    }

    private func spawnParticle(_ kind: EffectParticle.Kind, at position: CGPoint) {
        let p = EffectParticle(
            id:         UUID(),
            origin:     position,
            birth:      CACurrentMediaTime(),
            kind:       kind,
            driftX:     Double.random(in: -50...50),
            driftY:     Double.random(in: 90...200),
            spinOffset: Double.random(in: -.pi...(.pi))
        )
        particles.append(p)
        let copy = particles
        storage.write { $0.particles = copy }
    }

    // MARK: - Tick

    private func tick() {
        let now    = CACurrentMediaTime()
        let before = particles.count
        particles.removeAll { $0.isExpired(at: now) }
        if particles.count != before {
            let copy = particles
            storage.write { $0.particles = copy }
        }
    }

    // MARK: - Emoji pre-rendering

    /// Renders an emoji string into a `CIImage`.  Call on the main thread.
    static func makeEmojiImage(_ emoji: String, pointSize: CGFloat) -> CIImage? {
        let pad  = pointSize * 0.15
        let side = pointSize + pad * 2
        let size = NSSize(width: side, height: side)

        let nsImage = NSImage(size: size, flipped: false) { rect in
            let font  = NSFont(name: "AppleColorEmoji", size: pointSize)
                     ?? NSFont.systemFont(ofSize: pointSize)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let str   = emoji as NSString
            let strSz = str.size(withAttributes: attrs)
            str.draw(
                at: CGPoint(x: (rect.width  - strSz.width)  / 2,
                            y: (rect.height - strSz.height) / 2),
                withAttributes: attrs
            )
            return true
        }

        guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return CIImage(cgImage: cg)
    }
}
