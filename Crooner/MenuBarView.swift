import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var permissions: PermissionManager
    @EnvironmentObject var session:     RecordingSession

    var onOpenSettings: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Content — either the source picker or a permissions prompt
            if permissions.allGranted {
                SourcePickerView()
            } else {
                VStack(spacing: 0) {
                    Text("Permissions required")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                    Divider()
                    PermissionBannerView()
                    Divider()
                    Spacer()
                }
            }

            Divider()

            // Footer: [⚙] ——————————— [Go →] ——————————— [Quit]
            HStack {
                Button {
                    onOpenSettings?()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Crooner Settings")

                Spacer()

                Button {
                    session.stage()
                } label: {
                    Label("Go", systemImage: "chevron.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.selectedSource == nil || session.state != .idle)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.callout)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 340, height: 325)
        .task { await permissions.checkAll() }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(PermissionManager())
        .environmentObject(RecordingSession())
}
