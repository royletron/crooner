import SwiftUI

/// Compact segmented-bar level meter — 10 rounded rectangles that light up
/// left-to-right across green → amber → red zones.
///
/// The level input is already smoothed (fast-attack / slow-decay) by the
/// audio engine, so no additional animation is needed here.
struct VUMeterView: View {
    /// Normalised input level from the audio engine (0 = silence, 1 = 0 dB).
    let level: Float

    private static let segmentCount = 10

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<Self.segmentCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(segmentColor(index: i))
                    .frame(width: 3, height: 10)
            }
        }
        .frame(width: 44)
    }

    private func segmentColor(index: Int) -> Color {
        let threshold = Float(index) / Float(Self.segmentCount - 1)
        guard level > threshold else { return .white.opacity(0.18) }
        if threshold < 0.60 { return .green.opacity(0.85)  }
        if threshold < 0.82 { return .yellow.opacity(0.85) }
        return .red.opacity(0.9)
    }
}

#Preview {
    VStack(spacing: 12) {
        VUMeterView(level: 0.0)
        VUMeterView(level: 0.35)
        VUMeterView(level: 0.65)
        VUMeterView(level: 0.9)
        VUMeterView(level: 1.0)
    }
    .padding(20)
    .background(.black)
}
