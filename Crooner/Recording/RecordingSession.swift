import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
import SwiftUI
import UserNotifications

// MARK: - State

enum RecordingState: Equatable {
    case idle
    case staged                 // source + audio config chosen; pill visible, waiting for Record tap
    case countdown(Int)         // seconds remaining before recording starts
    case recording
    case paused
    case finishing
}

// MARK: - Errors

enum RecordingSessionError: LocalizedError {
    case noSourceSelected
    case notRecording

    var errorDescription: String? {
        switch self {
        case .noSourceSelected: return "Select a screen or window to record first."
        case .notRecording:     return "No recording is in progress."
        }
    }
}

// MARK: - Session

/// Single `@MainActor ObservableObject` that wires all engines together and
/// drives the UI state machine.
///
/// State transitions:
/// ```
/// idle → staged → countdown(3..1) → recording ⇄ paused → finishing → idle
///                    ↑ cancelStage()
///         staged ────┘
/// ```
@MainActor
final class RecordingSession: ObservableObject {

    // MARK: - Existing published properties (CROON-005 / CROON-008)

    @Published var selectedSource: CaptureSource?
    var settings = RecordingSettings()

    @Published var bubbleEnabled: Bool        = true
    @Published var bubbleSize:    BubbleSize   = .medium
    @Published var bubbleCorner:  BubbleCorner = .bottomRight

    // MARK: - New published state

    @Published private(set) var state:              RecordingState = .idle
    @Published private(set) var elapsed:             TimeInterval   = 0
    @Published private(set) var audioSources:        [AudioSource]  = []
    @Published private(set) var isMuted:             Bool           = false
    @Published private(set) var lastRecordingURL:    URL?
    @Published private(set) var micLevel:            Float          = 0

    // MARK: - Audio configuration (set by SourcePickerView before staging)

    /// Specific mic to use; nil = system default.
    var selectedMicDevice: AVCaptureDevice? = nil
    /// Whether to mix in system audio.  Defaults to true.
    var systemAudioEnabled: Bool = true

    // MARK: - Effects

    /// Shared effects engine — owned here, observed by the overlay controller and compositor.
    let effectsEngine = EffectsEngine()

    // MARK: - Engine references (nil between recordings)

    private var screenEngine:      ScreenCaptureEngine?
    private var webcamEngine:      WebcamCaptureEngine?
    private var audioMixer:        AudioMixerEngine?
    private var compositor:        CompositorPipeline?
    private var fileWriter:        FileWriter?
    private var levelMonitorEngine: AVAudioEngine?

    // MARK: - Timer / subscriptions

    private var elapsedTimer:         AnyCancellable?
    private var compositorSyncSubs:   Set<AnyCancellable> = []
    private var persistenceSubs:      Set<AnyCancellable> = []

    // MARK: - Init

    init() {
        // Restore bubble settings from UserDefaults.
        let ud = UserDefaults.standard
        if let raw = ud.string(forKey: AppStorageKey.bubbleSize),
           let s = BubbleSize(rawValue: raw)     { bubbleSize   = s }
        if let raw = ud.string(forKey: AppStorageKey.bubbleCorner),
           let c = BubbleCorner(rawValue: raw)   { bubbleCorner = c }
        bubbleEnabled = ud.object(forKey: AppStorageKey.bubbleEnabled) as? Bool ?? true

        // Persist bubble settings whenever they change.
        $bubbleSize
            .dropFirst()
            .sink { ud.set($0.rawValue, forKey: AppStorageKey.bubbleSize) }
            .store(in: &persistenceSubs)
        $bubbleCorner
            .dropFirst()
            .sink { ud.set($0.rawValue, forKey: AppStorageKey.bubbleCorner) }
            .store(in: &persistenceSubs)
        $bubbleEnabled
            .dropFirst()
            .sink { ud.set($0, forKey: AppStorageKey.bubbleEnabled) }
            .store(in: &persistenceSubs)
    }

    // MARK: - Public API

    /// Transition from `.idle` to `.staged` — shows the pill bar without starting any engines.
    /// The user must then tap Record on the pill to actually begin.
    func stage() {
        guard selectedSource != nil else { return }
        guard case .idle = state else { return }
        state = .staged
        startMicMonitor()
    }

    /// Cancel out of the staged state and return to `.idle`.
    func cancelStage() {
        guard case .staged = state else { return }
        stopMicMonitor()
        state = .idle
    }

    /// Run the countdown then start all engines and begin writing to disk.
    ///
    /// Throws if no source is selected or any engine fails to start.
    func startRecording() async throws {
        guard let source = selectedSource else { throw RecordingSessionError.noSourceSelected }
        guard case .staged = state else { return }
        stopMicMonitor()

        // — Apply persisted settings ————————————————————————————————
        applyStoredSettings()
        applyEffectsSettings()

        // — Countdown ——————————————————————————————————————————————
        let ud = UserDefaults.standard
        let countdownSecs = ud.object(forKey: AppStorageKey.countdown) == nil
            ? 3   // key not yet written → use default
            : max(0, ud.integer(forKey: AppStorageKey.countdown))
        for remaining in stride(from: countdownSecs, through: 1, by: -1) {
            state = .countdown(remaining)
            try await Task.sleep(for: .seconds(1))
        }

        // — Create engines ——————————————————————————————————————————
        let screen = ScreenCaptureEngine()
        let webcam = WebcamCaptureEngine()
        let mixer  = AudioMixerEngine()
        let comp   = CompositorPipeline()
        let writer = FileWriter()

        do {
            let screenStream = try await screen.start(source: source, settings: settings)
            let webcamStream = try await webcam.start()
            let audioStream  = try mixer.start(micDevice: selectedMicDevice,
                                                         systemAudioEnabled: systemAudioEnabled)

            // Apply persisted audio volumes.
            let ud = UserDefaults.standard
            let micVol = ud.object(forKey: AppStorageKey.micVolume)    as? Double ?? 1
            let sysVol = ud.object(forKey: AppStorageKey.sysAudioVolume) as? Double ?? 1
            mixer.setVolume(Float(micVol), for: .microphone)
            mixer.setVolume(Float(sysVol), for: .systemAudio)

            // Forward mic level updates to the published property for the VU meter.
            mixer.micLevelHandler = { [weak self] level in self?.micLevel = level }

            // Route system audio samples from the screen engine into the mixer.
            screen.audioBufferHandler = { [weak mixer] buffer in
                mixer?.feedSystemAudio(buffer)
            }

            // Configure compositor with current bubble settings and effects engine.
            await comp.configure(
                bubbleEnabled: bubbleEnabled,
                bubbleSize:    bubbleSize,
                bubbleCorner:  bubbleCorner
            )
            await comp.setEffectsEngine(effectsEngine)
            let compositorStream = await comp.start(
                screenStream: screenStream,
                webcamStream: webcamStream,
                outputSize:   source.outputSize
            )

            // Begin writing — returns immediately; drain tasks run in background.
            _ = try await writer.start(
                videoStream: compositorStream,
                audioStream: audioStream,
                outputSize:  source.outputSize,
                settings:    settings
            )
        } catch {
            // Roll back any engines that did start before the failure.
            await screen.stop()
            await webcam.stop()
            mixer.stop()
            state = .idle
            throw error
        }

        // — Persist engine references ———————————————————————————————
        screenEngine = screen
        webcamEngine = webcam
        audioMixer   = mixer
        compositor   = comp
        fileWriter   = writer

        audioSources = mixer.sources
        isMuted      = false
        elapsed      = 0

        // — Start effects tracking ————————————————————————————————————
        effectsEngine.startTracking(source: source)

        // — Start elapsed clock ————————————————————————————————————
        startElapsedTimer()

        state = .recording

        // — Sync bubble changes to compositor in real time ——————————
        startCompositorSync()
    }

    /// Suspend writing.  The output file will have the paused interval cut out.
    func pauseRecording() {
        guard case .recording = state else { return }
        elapsedTimer = nil
        state        = .paused
        Task { [weak self] in await self?.fileWriter?.pause() }
    }

    /// Resume writing after a pause.
    func resumeRecording() {
        guard case .paused = state else { return }
        startElapsedTimer()
        state = .recording
        Task { [weak self] in await self?.fileWriter?.resume() }
    }

    /// Toggle microphone mute for the current recording.
    func muteToggle() {
        isMuted = !isMuted
        audioMixer?.setEnabled(!isMuted, for: .microphone)
    }

    /// Stop the recording, finalise the file, and return its URL.
    @discardableResult
    func stopRecording() async throws -> URL {
        guard state == .recording || state == .paused else {
            throw RecordingSessionError.notRecording
        }

        state        = .finishing
        elapsedTimer = nil
        compositorSyncSubs.removeAll()

        // Stop capture; finishing the screen stream cascades through the
        // compositor into the file-writer drain tasks.
        await screenEngine?.stop()
        await webcamEngine?.stop()
        audioMixer?.stop()
        await compositor?.stop()
        effectsEngine.stopTracking()

        // Brief pause to let any in-flight frames propagate.
        try? await Task.sleep(for: .milliseconds(150))

        guard let writer = fileWriter else {
            tearDown()
            state = .idle
            throw RecordingSessionError.notRecording
        }

        let url: URL
        do {
            url = try await writer.finish()
        } catch {
            tearDown()
            state = .idle
            throw error
        }

        tearDown()
        elapsed           = 0
        isMuted           = false
        audioSources      = []
        lastRecordingURL  = url
        state             = .idle

        postSaveNotification(url: url)
        return url
    }

    // MARK: - Private: timer

    private func startElapsedTimer() {
        elapsedTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.elapsed += 1 }
    }

    // MARK: - Private: compositor sync

    /// Forward live bubble-setting changes to the compositor actor while recording.
    private func startCompositorSync() {
        compositorSyncSubs.removeAll()

        Publishers.CombineLatest3($bubbleEnabled, $bubbleSize, $bubbleCorner)
            .dropFirst()   // skip the initial emission — already applied at start
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, size, corner in
                guard let self, let comp = compositor else { return }
                Task {
                    await comp.configure(
                        bubbleEnabled: enabled,
                        bubbleSize:    size,
                        bubbleCorner:  corner
                    )
                }
            }
            .store(in: &compositorSyncSubs)
    }

    // MARK: - Private: effects settings

    private func applyEffectsSettings() {
        let ud = UserDefaults.standard
        effectsEngine.mouseTrailEnabled   = ud.bool(forKey: AppStorageKey.mouseTrailEnabled)
        effectsEngine.clickCirclesEnabled = ud.bool(forKey: AppStorageKey.clickCirclesEnabled)
        effectsEngine.trailEmoji          = ud.string(forKey: AppStorageKey.trailEmoji) ?? "✨"
    }

    // MARK: - Private: stored settings

    /// Reads persisted output settings from UserDefaults into `self.settings`
    /// immediately before a recording begins.
    private func applyStoredSettings() {
        let ud = UserDefaults.standard

        if let raw = ud.string(forKey: AppStorageKey.codec),
           let codec = RecordingSettings.VideoCodec(rawValue: raw) {
            settings.codec = codec
        }
        let fpsRaw = ud.integer(forKey: AppStorageKey.frameRate)
        if let fps = RecordingSettings.FrameRate(rawValue: fpsRaw) {
            settings.frameRate = fps
        }
        if let path = ud.string(forKey: AppStorageKey.saveFolderPath) {
            settings.saveFolderURL = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    // MARK: - Private: staged mic monitor

    /// Lightweight engine that drives the VU meter while the session is staged.
    /// It is torn down before the full `AudioMixerEngine` starts so they never
    /// compete for the input device.
    private func startMicMonitor() {
        let engine = AVAudioEngine()
        let input  = engine.inputNode

        // Optionally select the mic device the user picked in the source picker.
        if let device   = selectedMicDevice,
           let deviceID = AudioMixerEngine.coreAudioDeviceID(for: device),
           let au       = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }

        // `smoothed` is a heap-captured var — safe to mutate from the audio thread.
        var smoothed: Float = 0
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let n   = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += data[0][i] * data[0][i] }
            let rms        = sqrt(sum / Float(n))
            let db         = 20.0 * log10(max(rms, 1e-7))
            let normalised = max(0, min(1, Float((db + 60.0) / 60.0)))
            let decayed    = max(normalised, smoothed * 0.88)
            smoothed       = decayed
            DispatchQueue.main.async { [weak self] in self?.micLevel = decayed }
        }

        try? engine.start()
        levelMonitorEngine = engine
    }

    private func stopMicMonitor() {
        levelMonitorEngine?.inputNode.removeTap(onBus: 0)
        levelMonitorEngine?.stop()
        levelMonitorEngine = nil
        micLevel = 0
    }

    // MARK: - Private: teardown

    private func tearDown() {
        screenEngine = nil
        webcamEngine = nil
        audioMixer   = nil
        compositor   = nil
        fileWriter   = nil
        micLevel     = 0
    }

    // MARK: - Private: notification

    private func postSaveNotification(url: URL) {
        let center = UNUserNotificationCenter.current()

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }

            let content                = UNMutableNotificationContent()
            content.title              = "Recording saved"
            content.body               = url.lastPathComponent
            content.sound              = .default
            content.userInfo           = ["fileURL": url.path]
            content.categoryIdentifier = "RECORDING_SAVED"

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content:    content,
                trigger:    nil   // deliver immediately
            )
            center.add(request)
        }
    }
}
