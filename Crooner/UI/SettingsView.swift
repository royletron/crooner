import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Root

struct SettingsView: View {
    @EnvironmentObject var session: RecordingSession

    var body: some View {
        TabView {
            OutputTab()
                .tabItem { Label("Output", systemImage: "film") }

            AudioTab()
                .environmentObject(session)
                .tabItem { Label("Audio", systemImage: "waveform") }

            WebcamTab()
                .environmentObject(session)
                .tabItem { Label("Webcam", systemImage: "camera.fill") }

            EffectsTab()
                .tabItem { Label("Effects", systemImage: "sparkles") }

            FiltersTab()
                .tabItem { Label("Filters", systemImage: "camera.filters") }

            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 420, height: 360)
        .padding(20)
    }
}

// MARK: - Output

private struct OutputTab: View {
    @AppStorage(AppStorageKey.codec)          private var codec     = RecordingSettings.VideoCodec.h264.rawValue
    @AppStorage(AppStorageKey.frameRate)      private var frameRate = RecordingSettings.FrameRate.thirty.rawValue
    @AppStorage(AppStorageKey.saveFolderPath) private var folderPath = RecordingSettings.defaultSaveFolder.path

    var body: some View {
        Form {
            Section("Video") {
                Picker("Codec", selection: $codec) {
                    ForEach(RecordingSettings.VideoCodec.allCases, id: \.rawValue) {
                        Text($0.rawValue).tag($0.rawValue)
                    }
                }
                Picker("Frame rate", selection: $frameRate) {
                    ForEach(RecordingSettings.FrameRate.allCases, id: \.rawValue) {
                        Text($0.label).tag($0.rawValue)
                    }
                }
            }

            Section("Save location") {
                HStack {
                    Text(URL(fileURLWithPath: folderPath).lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles        = false
                        panel.canChooseDirectories  = true
                        panel.canCreateDirectories  = true
                        panel.prompt                = "Select"
                        if panel.runModal() == .OK, let url = panel.url {
                            folderPath = url.path
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio

private struct AudioTab: View {
    @AppStorage(AppStorageKey.micVolume)      private var micVolume:   Double = 1
    @AppStorage(AppStorageKey.sysAudioVolume) private var sysVolume:   Double = 1

    var body: some View {
        Form {
            Section {
                LabeledContent("Microphone") {
                    HStack {
                        Slider(value: $micVolume)
                        Text("\(Int(micVolume * 100))%")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("System audio") {
                    HStack {
                        Slider(value: $sysVolume)
                        Text("\(Int(sysVolume * 100))%")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Default volumes applied at the start of each recording.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Webcam

private struct WebcamTab: View {
    @EnvironmentObject var session: RecordingSession

    @AppStorage(AppStorageKey.bubbleSize)   private var sizeRaw:   String = BubbleSize.medium.rawValue
    @AppStorage(AppStorageKey.bubbleCorner) private var cornerRaw: String = BubbleCorner.bottomRight.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Show webcam bubble", isOn: $session.bubbleEnabled)

                Picker("Default size", selection: $sizeRaw) {
                    ForEach(BubbleSize.allCases, id: \.rawValue) {
                        Text(sizeName($0)).tag($0.rawValue)
                    }
                }
                .disabled(!session.bubbleEnabled)

                Picker("Default corner", selection: $cornerRaw) {
                    ForEach(BubbleCorner.allCases, id: \.rawValue) {
                        Text(cornerName($0)).tag($0.rawValue)
                    }
                }
                .disabled(!session.bubbleEnabled)
            }
        }
        .formStyle(.grouped)
        // Keep session in sync with picker selections
        .onChange(of: sizeRaw)   { session.bubbleSize   = BubbleSize(rawValue: $0)   ?? .medium }
        .onChange(of: cornerRaw) { session.bubbleCorner = BubbleCorner(rawValue: $0) ?? .bottomRight }
        .onAppear {
            sizeRaw   = session.bubbleSize.rawValue
            cornerRaw = session.bubbleCorner.rawValue
        }
    }

    private func sizeName(_ s: BubbleSize) -> String {
        switch s {
        case .small:  return "Small (120 px)"
        case .medium: return "Medium (180 px)"
        case .large:  return "Large (240 px)"
        }
    }

    private func cornerName(_ c: BubbleCorner) -> String {
        switch c {
        case .topLeft:     return "Top left"
        case .topRight:    return "Top right"
        case .bottomLeft:  return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

// MARK: - Effects

private struct EffectsTab: View {
    @AppStorage(AppStorageKey.mouseTrailEnabled)   private var trailEnabled   = false
    @AppStorage(AppStorageKey.clickCirclesEnabled) private var circlesEnabled = false
    @AppStorage(AppStorageKey.trailEmoji)          private var trailEmoji     = "✨"

    private let emojiOptions: [(String, String)] = [
        ("✨", "Sparkles"), ("⭐️", "Star"),  ("🎉", "Confetti"),
        ("💫", "Dizzy"),   ("🔥", "Fire"),   ("❤️", "Heart"),
        ("🎈", "Balloon"), ("🌟", "Glow"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Mouse trail", isOn: $trailEnabled)

                if trailEnabled {
                    LabeledContent("Emoji") {
                        Picker("", selection: $trailEmoji) {
                            ForEach(emojiOptions, id: \.0) { emoji, label in
                                Text("\(emoji)  \(label)").tag(emoji)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
            } footer: {
                Text("Emoji confetti trails the mouse during recording.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Click circles", isOn: $circlesEnabled)
            } footer: {
                Text("A ripple circle highlights every left-click.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Filters

private struct FiltersTab: View {
    @AppStorage(AppStorageKey.videoFilter) private var filterRaw = VideoFilter.none.rawValue

    private var selected: VideoFilter { VideoFilter(rawValue: filterRaw) ?? .none }

    private struct FilterGroup: Identifiable {
        let id = UUID()
        let title: String
        let filters: [(VideoFilter, String)]
    }

    private let groups: [FilterGroup] = [
        FilterGroup(title: "", filters: [
            (.none, "No filter applied."),
        ]),
        FilterGroup(title: "Vintage", filters: [
            (.noir,     "Classic black-and-white with lifted contrast."),
            (.sepia,    "Warm sepia tone, like an old photograph."),
            (.oldMovie, "Sepia + grain + flickering vignette — full vintage."),
            (.vhs,      "Muted colours, scanlines, warm cast, edge vignette."),
        ]),
        FilterGroup(title: "Colour", filters: [
            (.thermal,  "Luminance mapped to a blue→red infrared heat palette."),
            (.neonNoir, "Noir base with bloom glow and a blue-purple tint."),
            (.comic,    "Posterised flat colours — graphic novel panel."),
        ]),
        FilterGroup(title: "Style", filters: [
            (.glitch,       "Periodic RGB channel splits and chromatic aberration."),
            (.dream,        "Soft bloom haze with lifted blacks and cool tones."),
            (.focus,        "Sharpened centre with a soft vignette."),
            (.highContrast, "Punchy blacks, bright whites, subdued colour."),
        ]),
    ]

    var body: some View {
        Form {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.filters, id: \.0.rawValue) { filter, desc in
                        FilterRow(
                            label: filter.label,
                            desc: desc,
                            isSelected: selected == filter
                        ) { filterRaw = filter.rawValue }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FilterRow: View {
    let label: String
    let desc: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.callout)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(.primary)
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage(AppStorageKey.countdown)     private var countdown    = 3
    @AppStorage(AppStorageKey.launchAtLogin) private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Picker("Countdown", selection: $countdown) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // Revert if registration fails (e.g. permission denied).
                            launchAtLogin = !enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
