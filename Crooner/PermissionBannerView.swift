import SwiftUI

/// Shown inside the popover when one or more permissions are missing.
/// Each row either shows a green tick (granted) or an orange warning with
/// a button to jump straight to the relevant System Settings pane.
struct PermissionBannerView: View {
    @EnvironmentObject var permissions: PermissionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions required")
                .font(.subheadline)
                .fontWeight(.semibold)
                .padding(.bottom, 2)

            ForEach(PermissionManager.Permission.allCases, id: \.title) { permission in
                PermissionRow(permission: permission)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

private struct PermissionRow: View {
    @EnvironmentObject var permissions: PermissionManager
    let permission: PermissionManager.Permission

    var status: PermissionStatus { permissions.status(for: permission) }
    var isGranted: Bool { status == .granted }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: permission.systemImage)
                .frame(width: 16)
                .foregroundStyle(isGranted ? .green : .orange)

            Text(permission.title)
                .font(.callout)
                .foregroundStyle(isGranted ? .primary : .primary)

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button("Open Settings") {
                    permissions.openSystemSettings(for: permission)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }
}
