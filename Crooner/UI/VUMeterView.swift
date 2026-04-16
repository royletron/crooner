import SwiftUI

/// Compact analogue-style VU meter for the floating control bar.
///
/// A colour-zoned arc with zone-boundary tick marks and a spring-physics
/// needle that pivots at the bottom-centre of the frame.
struct VUMeterView: View {
    /// Normalised input level from the audio engine (0 = silence, 1 = 0 dB).
    let level: Float

    var body: some View {
        ZStack(alignment: .bottom) {

            // ── Background rail ──────────────────────────────────────────
            MeterArc(fromFrac: 0, toFrac: 1)
                .stroke(Color.white.opacity(0.08),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .butt))

            // ── Green zone  (silence → nominal) ─────────────────────────
            MeterArc(fromFrac: 0, toFrac: 0.72)
                .stroke(Color(red: 0.20, green: 0.70, blue: 0.22).opacity(0.72),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .butt))

            // ── Amber zone  (nominal → loud) ─────────────────────────────
            MeterArc(fromFrac: 0.72, toFrac: 0.87)
                .stroke(Color(red: 0.95, green: 0.56, blue: 0.04).opacity(0.80),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .butt))

            // ── Red zone   (loud → clip) ──────────────────────────────────
            MeterArc(fromFrac: 0.87, toFrac: 1.0)
                .stroke(Color(red: 0.92, green: 0.16, blue: 0.10).opacity(0.88),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .butt))

            // ── Tick marks at zone boundaries + endpoints ────────────────
            MeterTicks()
                .stroke(Color.white.opacity(0.32), lineWidth: 0.75)

            // ── Peak glow — fades in when needle enters red ──────────────
            MeterArc(fromFrac: 0.87, toFrac: min(1.0, Double(level)))
                .stroke(Color(red: 1.0, green: 0.35, blue: 0.1).opacity(0.45),
                        style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                .blur(radius: 3)
                .opacity(level > 0.87 ? 1 : 0)
                .animation(.easeOut(duration: 0.08), value: level > 0.87)

            // ── Needle ────────────────────────────────────────────────────
            NeedleShape(level: Double(level))
                .stroke(Color.white.opacity(0.92),
                        style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                .animation(.interpolatingSpring(stiffness: 310, damping: 20), value: level)

            // ── Pivot pin ─────────────────────────────────────────────────
            Circle()
                .fill(Color.white.opacity(0.90))
                .frame(width: 4, height: 4)
        }
        .frame(width: 56, height: 32)
    }
}

// MARK: - Arc

/// An arc segment defined by fractional positions (0 = left end, 1 = right end)
/// along the 90° sweep from 225° to 315° in screen coordinates.
private struct MeterArc: Shape {
    let fromFrac: Double
    let toFrac:   Double

    private static let startDeg = 225.0
    private static let spanDeg  = 90.0

    func path(in rect: CGRect) -> Path {
        let pivot  = CGPoint(x: rect.midX, y: rect.maxY - 2)
        let radius = rect.height * 0.82
        var p = Path()
        p.addArc(
            center:     pivot,
            radius:     radius,
            startAngle: .degrees(Self.startDeg + fromFrac * Self.spanDeg),
            endAngle:   .degrees(Self.startDeg + toFrac   * Self.spanDeg),
            clockwise:  true
        )
        return p
    }
}

// MARK: - Tick marks

/// Short radial lines at the arc endpoints and at each zone boundary.
private struct MeterTicks: Shape {
    // Fractional positions: endpoints + zone boundaries
    private static let fracs: [Double] = [0, 0.25, 0.5, 0.72, 0.87, 1.0]

    func path(in rect: CGRect) -> Path {
        let pivot  = CGPoint(x: rect.midX, y: rect.maxY - 2)
        let outerR = rect.height * 0.82
        var p = Path()

        for frac in Self.fracs {
            // Arc angle in screen-coordinate convention (Y-down):
            // 225° = upper-left, 270° = straight-up, 315° = upper-right.
            let angle  = CGFloat((225 + frac * 90) * .pi / 180)
            let dx     = cos(angle)
            let dy     = sin(angle)                          // negative → upward
            // Zone-boundary ticks are taller
            let len: CGFloat = (frac == 0.72 || frac == 0.87) ? 5.5 : 3.5
            let outer  = CGPoint(x: pivot.x + outerR * dx,          y: pivot.y + outerR * dy)
            let inner  = CGPoint(x: pivot.x + (outerR - len) * dx,  y: pivot.y + (outerR - len) * dy)
            p.move(to: outer)
            p.addLine(to: inner)
        }
        return p
    }
}

// MARK: - Needle

/// A line from the pivot to the tip, animated via `Animatable`.
/// Sweeps –45°…+45° from vertical as level goes 0 → 1.
private struct NeedleShape: Shape, Animatable {
    var level: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let pivot  = CGPoint(x: rect.midX, y: rect.maxY - 2)
        let length = rect.height * 0.78

        // Bearing convention: 0° = up, positive = clockwise.
        // x = sin(θ), y = −cos(θ)  (screen Y-down, so up is −y)
        let angleDeg = -45.0 + level * 90.0
        let rad      = CGFloat(angleDeg * .pi / 180.0)
        let tip = CGPoint(
            x: pivot.x + sin(rad) * length,
            y: pivot.y - cos(rad) * length
        )

        var p = Path()
        p.move(to: pivot)
        p.addLine(to: tip)
        return p
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 16) {
        VUMeterView(level: 0.0)
        VUMeterView(level: 0.45)
        VUMeterView(level: 0.80)
        VUMeterView(level: 1.0)
    }
    .padding(24)
    .background(Color(white: 0.12))
}
