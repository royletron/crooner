import SwiftUI

/// The compact pill-shaped bar that floats above the screen during recording.
///
/// Shows: recording indicator + elapsed timer | pause/resume | mic mute | stop
struct ControlBarView: View {
    @ObservedObject var session: RecordingSession

    var body: some View {
        HStack(spacing: 14) {

            // — Indicator + timer ————————————————————————————————————
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(elapsedText)
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 44, alignment: .leading)
            }

            Divider().frame(height: 18)

            // — Pause / Resume ———————————————————————————————————————
            BarButton(
                icon:   pauseIcon,
                help:   session.state == .paused ? "Resume" : "Pause"
            ) {
                if case .paused = session.state {
                    session.resumeRecording()
                } else {
                    session.pauseRecording()
                }
            }

            // — Mic mute ————————————————————————————————————————————
            BarButton(
                icon:       session.isMuted ? "mic.slash.fill" : "mic.fill",
                foreground: session.isMuted ? .red : .primary,
                help:       session.isMuted ? "Unmute microphone" : "Mute microphone"
            ) {
                session.muteToggle()
            }

            // — Stop ————————————————————————————————————————————————
            BarButton(icon: "stop.fill", foreground: .red, help: "Stop recording") {
                Task { try? await session.stopRecording() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    // MARK: - Helpers

    private var indicatorColor: Color {
        if case .paused = session.state { return .orange }
        return .red
    }

    private var pauseIcon: String {
        if case .paused = session.state { return "play.fill" }
        return "pause.fill"
    }

    private var elapsedText: String {
        let t = Int(session.elapsed)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: - Shared button style

private struct BarButton: View {
    let icon:       String
    var foreground: Color = .primary
    let help:       String
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(foreground)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
