import AVFoundation
import AppKit
import CoreVideo
import ScreenCaptureKit
import SwiftUI

// MARK: - Capture mode

private enum CaptureMode: String, CaseIterable {
    case fullScreen = "Screen"
    case window     = "Window"
    case area       = "Area"
    case recordings = "Recordings"
}

// MARK: - Source picker (root)

struct SourcePickerView: View {
    @EnvironmentObject var session: RecordingSession

    @State private var mode:      CaptureMode = .fullScreen
    @State private var content:   SCShareableContent?
    @State private var isLoading = true
    @State private var loadError: String?

    // Audio config — kept as local @State so the Toggle and Picker own their
    // state directly; values are written to the session only when Go is tapped.
    @State private var micDevices:          [AVCaptureDevice] = []
    @State private var selectedMicID:       String?  = nil    // nil = system default
    @State private var systemAudioEnabled:  Bool     = true

    var body: some View {
        VStack(spacing: 0) {
            // Segmented mode selector (includes Recordings)
            Picker("Capture mode", selection: $mode) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // ── Content area (fixed height) ───────────────────────────────
            contentArea
                .frame(height: 200)

            // ── Audio config (always in layout; invisible in Recordings mode) ──
            // Using opacity rather than conditional rendering keeps the row's
            // height constant across all modes, which anchors the footer.
            Group {
                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)

                    Picker("Microphone", selection: $selectedMicID) {
                        Text("Default").tag(nil as String?)
                        ForEach(micDevices, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device.uniqueID as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 150)

                    Spacer()

                    Toggle(isOn: $systemAudioEnabled) {
                        Label("System Audio", systemImage: "speaker.wave.2")
                    }
                    .toggleStyle(.checkbox)
                    .help("Include system audio in the recording")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .opacity(mode == .recordings ? 0 : 1)
            .allowsHitTesting(mode != .recordings)
        }
        .task { await loadContent() }
        .onAppear { loadMicDevices() }
        // Always clear the selected source when the mode changes so the Go
        // button (in the footer) is correctly disabled until a source is picked.
        .onChange(of: mode) { _ in session.selectedSource = nil }
        // Keep session in sync eagerly so MenuBarView's Go button can simply
        // call session.stage() without needing to read local @State.
        .onChange(of: selectedMicID) { id in
            session.selectedMicDevice = micDevices.first { $0.uniqueID == id }
        }
        .onChange(of: systemAudioEnabled) { session.systemAudioEnabled = $0 }
        // Auto-switch to Recordings when a recording finishes.
        .onChange(of: session.lastRecordingURL) { url in
            if url != nil { mode = .recordings }
        }
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if mode == .recordings {
            RecordingsListView(lastURL: session.lastRecordingURL)
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            errorPlaceholder(err)
        } else {
            switch mode {
            case .fullScreen:
                FullScreenTabView(displays: content?.displays ?? [])
            case .window:
                WindowTabView(windows: filteredWindows)
            case .area:
                AreaTabView(displays: content?.displays ?? [])
            case .recordings:
                EmptyView()
            }
        }
    }

    // MARK: - Helpers

    private func loadMicDevices() {
        // AVCaptureDevice.devices(for:) is deprecated but returns all audio input devices
        // across all macOS 13+ versions without version gating.
        micDevices = AVCaptureDevice.devices(for: .audio)
    }

    private var filteredWindows: [SCWindow] {
        (content?.windows ?? [])
            .filter {
                $0.isOnScreen
                && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
                && $0.frame.width  >= 100
                && $0.frame.height >= 100
            }
            .sorted {
                ($0.owningApplication?.applicationName ?? "~") <
                ($1.owningApplication?.applicationName ?? "~")
            }
    }

    private func loadContent() async {
        isLoading = true
        loadError = nil
        do {
            content = try await SCShareableContent.fetchCurrent()
        } catch {
            loadError = "Couldn't load screen content.\nCheck Screen Recording access."
        }
        isLoading = false
    }

    private func errorPlaceholder(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Full Screen tab

private struct FullScreenTabView: View {
    @EnvironmentObject var session: RecordingSession
    let displays: [SCDisplay]

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(displays, id: \.displayID) { DisplayRow(display: $0) }
            }
            .padding(10)
        }
    }
}

private struct DisplayRow: View {
    @EnvironmentObject var session: RecordingSession
    let display: SCDisplay

    private var isSelected: Bool {
        guard case .fullScreen(let d) = session.selectedSource else { return false }
        return d.displayID == display.displayID
    }

    var body: some View {
        Button { session.selectedSource = .fullScreen(display: display) } label: {
            HStack(spacing: 10) {
                ThumbnailView(filter: SCContentFilter(display: display, excludingWindows: []))
                    .frame(width: 80, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(display.localizedName)
                        .font(.callout).fontWeight(.medium)
                    Text("\(display.width) × \(display.height)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                }
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Window tab

private struct WindowTabView: View {
    let windows: [SCWindow]

    var body: some View {
        if windows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "macwindow").font(.title2).foregroundStyle(.secondary)
                Text("No windows found")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(windows, id: \.windowID) { WindowRow(window: $0) }
                }
                .padding(8)
            }
        }
    }
}

private struct WindowRow: View {
    @EnvironmentObject var session: RecordingSession
    let window: SCWindow

    private var isSelected: Bool {
        guard case .window(let w) = session.selectedSource else { return false }
        return w.windowID == window.windowID
    }

    private var appIcon: NSImage {
        let fallback = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        guard let pid = window.owningApplication?.processID,
              let app = NSRunningApplication(processIdentifier: pid) else { return fallback }
        return app.icon ?? fallback
    }

    var body: some View {
        Button { session.selectedSource = .window(window) } label: {
            HStack(spacing: 8) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(window.owningApplication?.applicationName ?? "Unknown")
                        .font(.callout).fontWeight(.medium)
                        .lineLimit(1)
                    if let title = window.title, !title.isEmpty {
                        Text(title)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                ThumbnailView(filter: SCContentFilter(desktopIndependentWindow: window))
                    .frame(width: 64, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                        .padding(.leading, 2)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Area tab

private struct AreaTabView: View {
    @EnvironmentObject var session: RecordingSession
    let displays: [SCDisplay]

    @State private var isSelecting = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed")
                .font(.largeTitle).foregroundStyle(.secondary)

            Text("Drag to select a region of your screen")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(isSelecting ? "Selecting…" : "Select Area…") {
                beginSelection()
            }
            .buttonStyle(.bordered)
            .disabled(isSelecting)

            if case .area(_, let rect) = session.selectedSource {
                Label("\(Int(rect.width)) × \(Int(rect.height)) px", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func beginSelection() {
        guard let screen = NSScreen.main else { return }
        isSelecting = true
        Task { @MainActor in
            defer { isSelecting = false }
            guard let rect = await AreaSelectorOverlay.selectArea(on: screen) else { return }
            // Match the NSScreen to its SCDisplay by display ID
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
            guard let display = displays.first(where: { $0.displayID == screenID }) else { return }
            session.selectedSource = .area(display: display, rect: rect)
        }
    }
}

// MARK: - Async thumbnail

/// Shows a live screenshot of the given content filter.
/// Uses SCScreenshotManager on macOS 14+; shows a neutral placeholder on macOS 13.
private struct ThumbnailView: View {
    let filter: SCContentFilter
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary.opacity(0.5))
                    )
            }
        }
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard #available(macOS 14.0, *) else { return }
        let config = SCStreamConfiguration()
        config.width  = 128
        config.height = 80
        config.pixelFormat = kCVPixelFormatType_32BGRA
        image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }
}

// MARK: - Recordings list

private struct RecordingsListView: View {
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
                Image(systemName: "folder").font(.callout)
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

// MARK: - SCDisplay name helper

private extension SCDisplay {
    /// Resolves the human-readable display name via NSScreen correlation.
    var localizedName: String {
        NSScreen.screens
            .first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == displayID
            }?
            .localizedName ?? "Display"
    }
}
