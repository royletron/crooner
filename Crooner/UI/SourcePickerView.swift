import SwiftUI
import ScreenCaptureKit
import CoreVideo
import AppKit

// MARK: - Capture mode

private enum CaptureMode: String, CaseIterable {
    case fullScreen = "Full Screen"
    case window     = "Window"
    case area       = "Area"
}

// MARK: - Source picker (root)

struct SourcePickerView: View {
    @EnvironmentObject var session: RecordingSession

    @State private var mode: CaptureMode = .fullScreen
    @State private var content: SCShareableContent?
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Segmented mode selector
            Picker("Capture mode", selection: $mode) {
                ForEach(CaptureMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Source list — fixed height so the popover doesn't resize
            ZStack {
                if isLoading {
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
                    }
                }
            }
            .frame(height: 200)

            Divider()

            // Webcam toggle + size picker + Record button
            HStack(spacing: 8) {
                // Camera on/off toggle
                Toggle(isOn: $session.bubbleEnabled) {
                    Image(systemName: "camera.fill")
                }
                .toggleStyle(.button)
                .help(session.bubbleEnabled ? "Hide webcam bubble" : "Show webcam bubble")

                // Bubble size — only visible when bubble is on
                if session.bubbleEnabled {
                    Picker("Bubble size", selection: $session.bubbleSize) {
                        ForEach(BubbleSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 72)
                }

                Spacer()

                Button {
                    Task { try? await session.startRecording() }
                } label: {
                    switch session.state {
                    case .countdown(let n): Label("Starting in \(n)…", systemImage: "timer")
                    case .recording:        Label("Recording", systemImage: "stop.circle.fill")
                    case .finishing:        Label("Finishing…", systemImage: "hourglass")
                    default:                Label("Record", systemImage: "record.circle.fill")
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(session.state == .recording ? .orange : .red)
                .disabled(session.selectedSource == nil || session.state != .idle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .task { await loadContent() }
        .onChange(of: mode) { _ in session.selectedSource = nil }
    }

    // MARK: - Helpers

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
