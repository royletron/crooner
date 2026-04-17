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
        .frame(width: 420, height: 320)
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

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: $filterRaw) {
                    ForEach(VideoFilter.allCases, id: \.rawValue) { f in
                        Text(f.label).tag(f.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Group {
                    switch VideoFilter(rawValue: filterRaw) ?? .none {
                    case .none:
                        Text("No filter applied.")
                    case .noir:
                        Text("Classic black-and-white with lifted contrast.")
                    case .sepia:
                        Text("Warm sepia tone, like an old photograph.")
                    case .oldMovie:
                        Text("Sepia + film grain + flickering vignette — full vintage look.")
                    case .vhs:
                        Text("Degraded tape look: muted colours, warm cast, scanlines, and edge vignette.")
                    case .thermal:
                        Text("False-colour heat map — luminance mapped to a blue-to-red infrared palette.")
                    case .neonNoir:
                        Text("Noir base with deep blacks, bloom glow, and a blue-purple tint.")
                    case .comic:
                        Text("Posterised flat colours with cranked saturation — graphic novel panel.")
                    case .glitch:
                        Text("Periodic RGB channel splits and chromatic aberration, as if the signal is breaking up.")
                    case .dream:
                        Text("Soft bloom haze, lifted blacks, and a cool blue-grey tone.")
                    case .focus:
                        Text("Sharpened centre with a soft vignette to draw the eye inward.")
                    case .highContrast:
                        Text("Punchy blacks, bright whites, and subdued colour — clean and tutorial-ready.")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
