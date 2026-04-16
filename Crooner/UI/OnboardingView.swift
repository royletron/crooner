import SwiftUI

/// Step-by-step permission setup shown on first launch (or any time a
/// permission is missing).  Each permission is requested via an explicit
/// button tap so the app is guaranteed to be frontmost when the TCC
/// dialog appears — auto-requesting at launch from a background menu-bar
/// app causes macOS 14+ to silently drop the microphone dialog.
struct OnboardingView: View {
    @EnvironmentObject var permissions: PermissionManager
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Crooner")
                    .font(.title2).fontWeight(.bold)
                Text("Grant the permissions below to start recording.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            // ── Permission rows ───────────────────────────────────────────
            VStack(spacing: 0) {
                OnboardingPermissionRow(permission: .screenRecording)
                Divider().padding(.leading, 60)
                OnboardingPermissionRow(permission: .camera)
                Divider().padding(.leading, 60)
                OnboardingPermissionRow(permission: .microphone)
            }

            Divider()

            // ── Footer ────────────────────────────────────────────────────
            HStack {
                Spacer()
                Button("Start Recording") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!permissions.allGranted)
            }
            .padding(20)
        }
        .frame(width: 440)
        // Poll status while the view is visible so that granting screen
        // recording in System Settings is reflected without a manual refresh.
        .task {
            while !Task.isCancelled {
                await permissions.checkAll()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

// MARK: - Individual permission row

private struct OnboardingPermissionRow: View {
    @EnvironmentObject var permissions: PermissionManager
    let permission: PermissionManager.Permission

    var status: PermissionStatus { permissions.status(for: permission) }

    var body: some View {
        HStack(spacing: 16) {
            // Icon badge
            ZStack {
                Circle()
                    .fill(badgeBackground)
                    .frame(width: 36, height: 36)
                Image(systemName: permission.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(badgeForeground)
            }

            // Label
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .fontWeight(.medium)
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Action
            actionView
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var actionView: some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .font(.title2)

        case .denied:
            Button("Open Settings") {
                permissions.openSystemSettings(for: permission)
            }
            .foregroundStyle(.orange)

        case .notDetermined:
            if permission == .screenRecording {
                Button("Open Settings") {
                    permissions.openSystemSettings(for: permission)
                }
            } else {
                Button("Grant Access") {
                    Task { await grant() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var badgeBackground: Color {
        switch status {
        case .granted:        return .green.opacity(0.12)
        case .denied:         return .orange.opacity(0.12)
        case .notDetermined:  return Color(.separatorColor).opacity(0.4)
        }
    }

    private var badgeForeground: Color {
        switch status {
        case .granted:        return .green
        case .denied:         return .orange
        case .notDetermined:  return .secondary
        }
    }

    private func grant() async {
        switch permission {
        case .camera:         await permissions.requestCamera()
        case .microphone:     await permissions.requestMicrophone()
        case .screenRecording: break  // must be done via System Settings
        }
    }
}

#Preview {
    OnboardingView(onDismiss: {})
        .environmentObject(PermissionManager())
}
