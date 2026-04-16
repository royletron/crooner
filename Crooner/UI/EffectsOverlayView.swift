import SwiftUI

/// Full-screen transparent view that renders live effect particles for presenter feedback.
///
/// Rendered in an `EffectsOverlayController` NSPanel that covers the captured area.
/// The compositor independently renders the same particles into the video file.
struct EffectsOverlayView: View {

    @ObservedObject var engine: EffectsEngine

    /// The font used to draw trail emoji.  Sized so particles look natural at 1× scale.
    private let emojiFont = Font.system(size: 40)

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { ctx, size in
                let now   = CACurrentMediaTime()
                let frame = engine.captureFrame

                for p in engine.particles {
                    let globalPos = p.currentOrigin(at: now)

                    // Convert from global AppKit (y-up) → overlay-local (y-down, top-left origin).
                    let lx = globalPos.x - frame.minX
                    let ly = frame.maxY - globalPos.y

                    let α     = p.alpha(at: now)
                    let sc    = p.scale(at: now)
                    let angle = p.rotation(at: now)

                    guard α > 0, lx >= -60, lx <= size.width + 60,
                          ly >= -60, ly <= size.height + 60 else { continue }

                    ctx.withCGContext { cg in
                        cg.saveGState()
                        cg.translateBy(x: lx, y: ly)
                        cg.rotate(by: angle)
                        cg.scaleBy(x: sc, y: sc)
                        cg.setAlpha(α)

                        switch p.kind {
                        case .trail(let emoji):
                            // Draw colour emoji centred on the particle position.
                            drawEmoji(emoji, in: cg, size: 40)

                        case .click:
                            // Subtle expanding ring — sc is already in the context transform.
                            let r: CGFloat = 14
                            let lineW: CGFloat = max(0.5, 2 * (1 - p.progress(at: now)))
                            cg.setStrokeColor(
                                CGColor(red: 1, green: 1, blue: 1, alpha: α)
                            )
                            cg.setLineWidth(lineW)
                            cg.strokeEllipse(in: CGRect(x: -r, y: -r,
                                                        width: r * 2, height: r * 2))
                        }

                        cg.restoreGState()
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Helpers

    private func drawEmoji(_ emoji: String, in ctx: CGContext, size: CGFloat) {
        // Use NSAttributedString + CoreText so emoji renders in colour off the main thread.
        let font  = CTFontCreateWithName("AppleColorEmoji" as CFString, size, nil)
        let attrs = [kCTFontAttributeName: font] as CFDictionary
        let str   = CFAttributedStringCreate(nil, emoji as CFString, attrs)!
        let line  = CTLineCreateWithAttributedString(str)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        // CTLineDraw places the baseline at the current text position.
        // Translate so the glyph is centred at (0, 0) with y-down (Canvas coords).
        ctx.saveGState()
        // Canvas is y-down; flip for CoreText which is y-up.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(
            x: -bounds.width / 2 - bounds.minX,
            y:  bounds.height / 2 + bounds.minY
        )
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
