import SwiftUI

/// Shown inside the popover when one or more permissions are missing.
/// Camera and microphone show an explicit "Grant Access" button so the
/// request is always user-initiated (required for the TCC dialog to
/// appear reliably from a menu-bar app).
/// Screen recording must be granted via System Settings; its row opens
/// the relevant pane directly.
/// Status is refreshed once when the popover opens (MenuBarView's .task);
/// there is deliberately no background polling — repeatedly calling
/// SCShareableContent.fetchCurrent() triggers spurious system prompts.
struct PermissionBannerView: View {
    @EnvironmentObject var permissions: PermissionManager

    var body: some View {
        VStack(spacing: 0) {
            ForEach(PermissionManager.Permission.allCases, id: \.title) { permission in
                PermissionRow(permission: permission)
                if permission != PermissionManager.Permission.allCases.last {
                    Divider().padding(.leading, 52)
                }
            }
        }
    }
}

// MARK: - Row

private struct PermissionRow: View {
    @EnvironmentObject var permissions: PermissionManager
    let permission: PermissionManager.Permission

    var status: PermissionStatus { permissions.status(for: permission) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 24)
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                    .font(.callout)
                    .fontWeight(.medium)
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            actionView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var actionView: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)

        case .denied:
            Button("Open Settings") {
                permissions.openSystemSettings(for: permission)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.orange)

        case .notDetermined:
            if permission == .screenRecording {
                Button("Open Settings") {
                    permissions.openSystemSettings(for: permission)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Button("Grant Access") {
                    Task { await grant() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var iconColor: Color {
        switch status {
        case .granted:       return .green
        case .denied:        return .orange
        case .notDetermined: return .secondary
        }
    }

    private func grant() async {
        switch permission {
        case .camera:         await permissions.requestCamera()
        case .microphone:     await permissions.requestMicrophone()
        case .screenRecording: break
        }
    }
}
