import SwiftUI

/// Minimal audio-level indicator — three animated bars whose heights track
/// the microphone level, similar to the indicator used in Google Meet.
///
/// All bars are monochromatic; they never change colour.  The level drives
/// height only, giving a clean "simplified waveform" appearance.
struct VUMeterView: View {
    /// Normalised input level from the audio engine (0 = silence, 1 = full).
    let level: Float

    // The three bars have different maximum heights so they form a natural
    // wave silhouette rather than a uniform block.
    private let scales: [Double] = [0.55, 1.0, 0.70]
    private let barWidth:  CGFloat = 2.5
    private let minHeight: CGFloat = 2.5
    private let maxHeight: CGFloat = 16

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(scales.indices, id: \.self) { i in
                bar(scale: scales[i])
            }
        }
        .frame(width: 16, height: maxHeight)
    }

    private func bar(scale: Double) -> some View {
        let h = minHeight + max(0, CGFloat(level)) * (maxHeight - minHeight) * scale
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.white.opacity(0.85))
            .frame(width: barWidth, height: h)
            .animation(.interpolatingSpring(stiffness: 300, damping: 20), value: level)
    }
}

#Preview {
    HStack(spacing: 20) {
        VUMeterView(level: 0.0)
        VUMeterView(level: 0.3)
        VUMeterView(level: 0.7)
        VUMeterView(level: 1.0)
    }
    .padding(24)
    .background(Color(white: 0.12))
}
