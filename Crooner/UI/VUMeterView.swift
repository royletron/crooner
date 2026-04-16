import SwiftUI

/// Compact analogue-style VU meter for the floating control bar.
///
/// Renders a colour-zoned arc and a spring-physics needle that pivots at
/// the bottom centre of the frame.  Uses `Shape` + `Animatable` so
/// SwiftUI interpolates the needle angle automatically between level updates.
struct VUMeterView: View {
    /// Normalised input level from the audio engine (0 = silence, 1 = 0 dB).
    let level: Float

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Arc track ────────────────────────────────────────────────
            // Background rail
            ArcSegment(startDeg: 225, endDeg: 315)
                .stroke(Color.white.opacity(0.12),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))

            // Green zone  (~–inf … –10 dB equivalent)
            ArcSegment(startDeg: 225, endDeg: 273)
                .stroke(Color.green.opacity(0.55),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))

            // Amber zone  (~–10 … –3 dB)
            ArcSegment(startDeg: 273, endDeg: 300)
                .stroke(Color.yellow.opacity(0.65),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))

            // Red zone    (~–3 … 0 dB)
            ArcSegment(startDeg: 300, endDeg: 315)
                .stroke(Color.red.opacity(0.75),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))

            // ── Needle ───────────────────────────────────────────────────
            NeedleShape(level: Double(level))
                .stroke(Color.white.opacity(0.92),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .animation(
                    .interpolatingSpring(stiffness: 260, damping: 22),
                    value: level
                )

            // Pivot dot
            Circle()
                .fill(Color.white.opacity(0.7))
                .frame(width: 4, height: 4)
        }
        .frame(width: 44, height: 26)
    }
}

// MARK: - Arc segment

/// A partial arc drawn clockwise from `startDeg` to `endDeg`
/// (both measured clockwise from the positive-X axis, 0° = right).
private struct ArcSegment: Shape {
    let startDeg: Double
    let endDeg:   Double

    func path(in rect: CGRect) -> Path {
        // Pivot at the horizontal centre, near the bottom of the frame.
        let pivot  = CGPoint(x: rect.midX, y: rect.maxY - 2)
        let radius = rect.height * 0.88
        var p = Path()
        p.addArc(center:     pivot,
                 radius:     radius,
                 startAngle: .degrees(startDeg),
                 endAngle:   .degrees(endDeg),
                 clockwise:  true)
        return p
    }
}

// MARK: - Needle

/// A line from the pivot to the tip, animated via `Animatable`.
/// The needle sweeps –45° … +45° relative to straight-up as level goes 0 → 1.
private struct NeedleShape: Shape, Animatable {
    var level: Double       // 0.0 – 1.0

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let pivot  = CGPoint(x: rect.midX, y: rect.maxY - 2)
        let length = rect.height * 0.86

        // Map 0…1  →  –45°…+45° from vertical (up).
        // In SwiftUI screen-coords (Y-down):
        //   x-offset = sin(θ) * length
        //   y-offset = –cos(θ) * length  (negative = upward)
        let angleDeg = -45.0 + level * 90.0
        let rad      = angleDeg * .pi / 180.0
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

#Preview {
    HStack(spacing: 12) {
        VUMeterView(level: 0.0)
        VUMeterView(level: 0.4)
        VUMeterView(level: 0.75)
        VUMeterView(level: 1.0)
    }
    .padding(20)
    .background(.black)
}
