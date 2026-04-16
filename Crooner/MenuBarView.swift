import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var permissions: PermissionManager
    @EnvironmentObject var session: RecordingSession

    var onOpenSettings: (() -> Void)? = nil

    @State private var tab: Tab = .record

    private enum Tab { case record, recordings }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title2)
                Text("Crooner")
                    .font(.headline)
                Spacer()
                Picker("", selection: $tab) {
                    Text("Record").tag(Tab.record)
                    Text("Recordings").tag(Tab.recordings)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Tab content
            switch tab {
            case .record:
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

            case .recordings:
                RecordingsTab(lastURL: session.lastRecordingURL)
            }

            Divider()

            // Footer
            HStack {
                Button {
                    onOpenSettings?()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Crooner Settings")
                .padding(.leading, 16)

                Spacer()

                Button("Quit Crooner") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.trailing, 16)
            }
            .padding(.vertical, 10)
        }
        .frame(width: 320, height: 400)
        .task { await permissions.checkAll() }
        // Switch to the Recordings tab automatically after a recording finishes.
        .onChange(of: session.lastRecordingURL) { url in
            if url != nil { tab = .recordings }
        }
    }
}

// MARK: - Recordings tab

private struct RecordingsTab: View {
    let lastURL: URL?

    var body: some View {
        if let url = lastURL {
            VStack(spacing: 0) {
                RecordingRow(url: url)
                Spacer()
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No recordings yet")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct RecordingRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = fileSize(url) {
                    Text(size)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "folder")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func fileSize(_ url: URL) -> String? {
        guard let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(PermissionManager())
        .environmentObject(RecordingSession())
}
