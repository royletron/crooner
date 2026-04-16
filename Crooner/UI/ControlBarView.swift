import SwiftUI

/// The compact pill-shaped bar that floats above the screen during recording.
///
/// During countdown  → red pill with a large animated number.
/// During recording  → indicator + timer | pause | mic + VU meter | stop.
///
/// Both states are rendered (the recording controls act as an invisible sizer)
/// so the pill never changes dimensions between states.
struct ControlBarView: View {
    @ObservedObject var session: RecordingSession

    private var isCountdown: Bool {
        if case .countdown = session.state { return true }
        return false
    }

    private var isStaged: Bool {
        if case .staged = session.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            // ── Sizing ghost ──────────────────────────────────────────────
            // Always rendered but never visible — keeps the pill at a stable
            // width/height so there's no layout jump between states.
            recordingControls.hidden()

            // ── Visible content ───────────────────────────────────────────
            if case .countdown(let n) = session.state {
                countdownContent(n)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            } else if case .staged = session.state {
                stagedControls
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            } else {
                recordingControls
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isCountdown)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            if isCountdown {
                Capsule().fill(Color.red.opacity(0.88))
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    // MARK: - Staged (ready-to-record)

    /// Webcam config + start/cancel — sized by the `recordingControls` ghost so
    /// the pill never jumps when transitioning into the recording state.
    private var stagedControls: some View {
        HStack(spacing: 14) {

            // — Webcam toggle ──────────────────────────────────────────────
            Toggle(isOn: $session.bubbleEnabled) {
                Image(systemName: "camera.fill")
            }
            .toggleStyle(.button)
            .help(session.bubbleEnabled ? "Hide webcam" : "Show webcam")

            // — Bubble size (only when webcam is on) ───────────────────────
            if session.bubbleEnabled {
                Picker("Size", selection: $session.bubbleSize) {
                    ForEach(BubbleSize.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 72)
            }

            Spacer()

            // — Mic + VU meter ─────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                VUMeterView(level: session.micLevel)
            }

            // — Record ─────────────────────────────────────────────────────
            BarButton(icon: "record.circle.fill", foreground: .red, help: "Start recording") {
                Task { try? await session.startRecording() }
            }

            // — Cancel ─────────────────────────────────────────────────────
            BarButton(icon: "trash.fill", foreground: .secondary, help: "Cancel") {
                session.cancelStage()
            }
        }
    }

    // MARK: - Countdown

    @ViewBuilder
    private func countdownContent(_ remaining: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text("\(remaining)")
                .font(.system(.callout, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    // MARK: - Recording controls

    private var recordingControls: some View {
        HStack(spacing: 14) {

            // — Indicator + timer ─────────────────────────────────────────
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

            // — Pause / Resume ────────────────────────────────────────────
            BarButton(
                icon: pauseIcon,
                help: session.state == .paused ? "Resume" : "Pause"
            ) {
                if case .paused = session.state { session.resumeRecording() }
                else { session.pauseRecording() }
            }

            // — Mic mute + VU meter ───────────────────────────────────────
            HStack(spacing: 6) {
                BarButton(
                    icon:       session.isMuted ? "mic.slash.fill" : "mic.fill",
                    foreground: session.isMuted ? .red : .primary,
                    help:       session.isMuted ? "Unmute microphone" : "Mute microphone"
                ) { session.muteToggle() }

                VUMeterView(level: session.isMuted ? 0 : session.micLevel)
            }

            // — Stop ───────────────────────────────────────────────────────
            BarButton(icon: "stop.fill", foreground: .red, help: "Stop recording") {
                Task { try? await session.stopRecording() }
            }
        }
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
