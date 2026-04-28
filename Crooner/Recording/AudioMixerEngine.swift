import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

// MARK: - Models

enum AudioSourceType {
    case microphone
    case systemAudio
}

struct AudioSource: Identifiable {
    let id:   UUID
    let name: String
    let type: AudioSourceType
    var volume:  Float  // 0.0 – 1.0
    var enabled: Bool
}

// MARK: - Errors

enum AudioMixerError: LocalizedError {
    case engineAlreadyRunning
    case engineNotRunning
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .engineAlreadyRunning:       return "Audio engine is already running. Call stop() first."
        case .engineNotRunning:           return "Audio engine is not running. Call startMonitoring() first."
        case .engineStartFailed(let e):   return "Audio engine failed to start: \(e.localizedDescription)"
        }
    }
}

// MARK: - Engine

/// Captures microphone audio via `AVAudioEngine` and mixes it with system audio
/// buffers pushed in by `ScreenCaptureEngine`.  Delivers the mix as
/// `AsyncStream<AVAudioPCMBuffer>` for the file writer (CROON-011).
///
/// Graph:
/// ```
/// inputNode ──► micMixer ──────────────────────┐
///                                               ├──► mainMixerNode ──► tap → stream
/// sysAudioPlayer ──► sysAudioMixer ────────────┘
/// ```
final class AudioMixerEngine {

    // MARK: - Source state

    private(set) var sources: [AudioSource] = [
        AudioSource(id: UUID(), name: "Microphone",   type: .microphone,   volume: 1, enabled: true),
        AudioSource(id: UUID(), name: "System Audio", type: .systemAudio,  volume: 1, enabled: true),
    ]

    // MARK: - Audio engine graph

    private let engine         = AVAudioEngine()
    private let micMixer       = AVAudioMixerNode()
    private let sysAudioPlayer = AVAudioPlayerNode()
    private let sysAudioMixer  = AVAudioMixerNode()
    /// Sits between the sources and mainMixerNode.  The recording tap lives
    /// here so it reads the full signal BEFORE mainMixerNode.outputVolume = 0
    /// silences the hardware path.  Keeping the graph fully connected to the
    /// output node ensures AVAudioEngine starts reliably.
    private let tapMixer       = AVAudioMixerNode()

    /// Standard format we request from SCKit and expect on `feedSystemAudio`.
    /// Must match `SCStreamConfiguration.sampleRate` / `channelCount` (both default to 48 kHz / 2 ch).
    static let systemAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!

    // MARK: - Level monitoring

    /// Called on the main thread with a normalised 0–1 mic level.
    var micLevelHandler: ((Float) -> Void)?
    /// Smoothed level — only touched from the audio work-queue tap callback.
    private var smoothedLevel: Float = 0
    private var isMonitoringLevel  = false

    // MARK: - Stream state

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let lock = NSLock()
    private var configChangeObserver: NSObjectProtocol?

    // MARK: - Public API

    /// Start the engine in level-monitoring mode for use during the staged state.
    /// No recording tap is installed; call `beginRecording()` to start capturing.
    /// Using a single persistent engine avoids reconnecting to the Bluetooth
    /// device between staging and recording, which causes a brief CoreAudio
    /// renegotiation that invalidates the AUHAL's device reference and crashes.
    func startMonitoring(micDevice: AVCaptureDevice? = nil) throws {
        guard !engine.isRunning else { return }
        attachAndConnect()
        applyVolumes()
        setInputDevice(micDevice)
        engine.mainMixerNode.outputVolume = 0
        startLevelMonitoring()

        // When the Bluetooth device switches from A2DP to HFP (triggered by the
        // IO proc activating the mic), CoreAudio resets the engine and posts
        // AVAudioEngineConfigurationChange. We must reconnect with the new format
        // and restart, otherwise the engine stays stopped and beginRecording() fails.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in self?.handleEngineConfigChange() }

        do {
            try engine.start()
        } catch {
            if isMonitoringLevel { micMixer.removeTap(onBus: 0); isMonitoringLevel = false }
            throw AudioMixerError.engineStartFailed(error)
        }
        sysAudioPlayer.play()
    }

    /// Add the recording tap to the already-running engine.
    /// The engine must have been started via `startMonitoring()`.
    func beginRecording(systemAudioEnabled: Bool = true) throws -> AsyncStream<AVAudioPCMBuffer> {
        guard engine.isRunning else { throw AudioMixerError.engineNotRunning }
        if !systemAudioEnabled,
           let i = sources.firstIndex(where: { $0.type == .systemAudio }) {
            sources[i].enabled = false
            sysAudioMixer.outputVolume = 0
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        lock.withLock { self.continuation = continuation }
        tapMixer.installTap(onBus: 0, bufferSize: 4_096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            lock.withLock { _ = self.continuation?.yield(buffer) }
        }
        return stream
    }

    /// Build the graph, start the engine, and return a stream of mixed PCM buffers.
    ///
    /// - Parameters:
    ///   - micDevice:          Specific microphone to use; `nil` uses the system default.
    ///   - systemAudioEnabled: When `false` the system-audio mixer is silenced.
    func start(micDevice: AVCaptureDevice? = nil,
               systemAudioEnabled: Bool = true) throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !engine.isRunning else { throw AudioMixerError.engineAlreadyRunning }

        if !systemAudioEnabled,
           let i = sources.firstIndex(where: { $0.type == .systemAudio }) {
            sources[i].enabled = false
        }

        attachAndConnect()
        applyVolumes()

        // Select mic device before starting the engine.
        if let device = micDevice,
           let deviceID = Self.coreAudioDeviceID(for: device),
           let au = engine.inputNode.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        lock.withLock { self.continuation = continuation }

        // Silence hardware output — nothing plays to speakers or headphones.
        // This is set on mainMixerNode (downstream of the tap), so the tap
        // on tapMixer still receives the full unsilenced mix.
        engine.mainMixerNode.outputVolume = 0

        // Tap tapMixer to capture the mix for writing.  Because tapMixer sits
        // upstream of mainMixerNode, its output is unaffected by the zero
        // output volume set above.
        tapMixer.installTap(onBus: 0, bufferSize: 4_096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            lock.withLock { _ = self.continuation?.yield(buffer) }
        }

        startLevelMonitoring()

        do {
            try engine.start()
        } catch {
            tapMixer.removeTap(onBus: 0)
            if isMonitoringLevel { micMixer.removeTap(onBus: 0); isMonitoringLevel = false }
            lock.withLock { self.continuation?.finish(); self.continuation = nil }
            throw AudioMixerError.engineStartFailed(error)
        }

        sysAudioPlayer.play()
        return stream
    }

    /// Stop the engine and finish the output stream.
    func stop() {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
        }
        tapMixer.removeTap(onBus: 0)
        if isMonitoringLevel { micMixer.removeTap(onBus: 0); isMonitoringLevel = false }
        smoothedLevel = 0
        sysAudioPlayer.stop()
        engine.stop()
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    // MARK: - System audio injection

    /// Called by `ScreenCaptureEngine` for every `.audio` sample buffer from SCKit.
    /// Converts to `AVAudioPCMBuffer` and schedules it on the player node.
    func feedSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard engine.isRunning else { return }
        guard let raw = makeAudioPCMBuffer(from: sampleBuffer) else { return }
        let buffer = raw.format == Self.systemAudioFormat
            ? raw
            : convert(raw, to: Self.systemAudioFormat) ?? raw
        sysAudioPlayer.scheduleBuffer(buffer)
    }

    // MARK: - Per-source control

    func setVolume(_ volume: Float, for type: AudioSourceType) {
        guard let i = sources.firstIndex(where: { $0.type == type }) else { return }
        sources[i].volume = max(0, min(1, volume))
        if sources[i].enabled {
            mixerNode(for: type).outputVolume = sources[i].volume
        }
    }

    func setEnabled(_ enabled: Bool, for type: AudioSourceType) {
        guard let i = sources.firstIndex(where: { $0.type == type }) else { return }
        sources[i].enabled = enabled
        mixerNode(for: type).outputVolume = enabled ? sources[i].volume : 0
    }

    // MARK: - Level monitoring

    /// Called on the main thread when CoreAudio resets the engine (e.g. Bluetooth
    /// switching from A2DP to HFP when the mic IO proc activates). Reconnects
    /// the mic path with the new device format and restarts the engine.
    private func handleEngineConfigChange() {
        // Disconnect and reconnect the mic path so format-dependent connections
        // are rebuilt against the device's new format (e.g. HFP at 16 kHz).
        engine.disconnectNodeInput(micMixer)
        engine.disconnectNodeOutput(micMixer)
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        if micFormat.sampleRate > 0 {
            engine.connect(engine.inputNode, to: micMixer, format: micFormat)
            engine.connect(micMixer,         to: tapMixer, format: micFormat)
        }
        engine.mainMixerNode.outputVolume = 0
        if !isMonitoringLevel { startLevelMonitoring() }
        try? engine.start()
    }

    /// Installs a lightweight tap on the mic mixer to compute RMS power,
    /// convert to a normalised 0–1 value (–60 dB … 0 dB), and push it to
    /// `micLevelHandler` on the main thread with a fast-attack / slow-decay
    /// envelope so the needle moves smoothly.
    private func startLevelMonitoring() {
        let format = micMixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }

        micMixer.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self,
                  let data = buffer.floatChannelData,
                  buffer.frameLength > 0 else { return }

            let frameCount = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameCount { sum += data[0][i] * data[0][i] }
            let rms  = sqrt(sum / Float(frameCount))

            // Convert RMS → dB, then normalise –60…0 dB to 0…1.
            let db         = 20.0 * log10(max(rms, 1e-7))
            let normalised = max(0, min(1, Float((db + 60.0) / 60.0)))

            // Fast attack, slow decay (~0.7 s full fall at 44 kHz / 1024 frames).
            let decayed = max(normalised, self.smoothedLevel * 0.88)
            self.smoothedLevel = decayed

            let level = decayed
            DispatchQueue.main.async { [weak self] in self?.micLevelHandler?(level) }
        }
        isMonitoringLevel = true
    }

    // MARK: - Graph construction

    private func setInputDevice(_ device: AVCaptureDevice?) {
        guard let device,
              let deviceID = Self.coreAudioDeviceID(for: device),
              let au = engine.inputNode.audioUnit else { return }
        var id = deviceID
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &id,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private func attachAndConnect() {
        engine.attach(micMixer)
        engine.attach(sysAudioPlayer)
        engine.attach(sysAudioMixer)
        engine.attach(tapMixer)

        // Pin the engine output to the built-in device before connecting
        // the output path. The output is silenced (mainMixerNode.outputVolume = 0)
        // so this has no audible effect, but it prevents Bluetooth HFP/A2DP
        // transitions from producing an invalid outputHWFormat and crashing
        // inside AVAudioEngine.start() with an uncatchable NSException.
        if let au = engine.outputNode.audioUnit,
           let builtInID = Self.builtInOutputDeviceID() {
            var id = builtInID
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &id,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        // Mic: inputNode → micMixer → tapMixer
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        if micFormat.sampleRate > 0 {
            engine.connect(engine.inputNode, to: micMixer, format: micFormat)
            engine.connect(micMixer,         to: tapMixer, format: micFormat)
        }

        // System audio: playerNode → sysAudioMixer → tapMixer
        engine.connect(sysAudioPlayer, to: sysAudioMixer, format: Self.systemAudioFormat)
        engine.connect(sysAudioMixer,  to: tapMixer,      format: Self.systemAudioFormat)

        // tapMixer → mainMixerNode → outputNode
        // The graph must be fully connected for engine.start() to succeed.
        // mainMixerNode.outputVolume is set to 0 in start() to prevent
        // loopback; tapMixer's output is unaffected because it is upstream.
        engine.connect(tapMixer, to: engine.mainMixerNode, format: nil)
    }

    private func applyVolumes() {
        for source in sources {
            mixerNode(for: source.type).outputVolume = source.enabled ? source.volume : 0
        }
    }

    private func mixerNode(for type: AudioSourceType) -> AVAudioMixerNode {
        type == .microphone ? micMixer : sysAudioMixer
    }

    // MARK: - CoreAudio device lookup

    /// Returns the `AudioDeviceID` of the first built-in output device, or `nil`.
    private static func builtInOutputDeviceID() -> AudioDeviceID? {
        var size = UInt32(0)
        var listAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &ids
        ) == noErr else { return nil }

        for id in ids {
            var transport     = UInt32(0)
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope:    kAudioObjectPropertyScopeGlobal,
                mElement:  kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                id, &transportAddr, 0, nil, &transportSize, &transport
            ) == noErr, transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            var streamSize = UInt32(0)
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope:    kAudioObjectPropertyScopeOutput,
                mElement:  kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyDataSize(
                id, &streamAddr, 0, nil, &streamSize
            ) == noErr, streamSize > 0 else { continue }

            return id
        }
        return nil
    }

    /// Translates an `AVCaptureDevice` audio UID to a CoreAudio `AudioDeviceID`.
    /// Returns `nil` if the device cannot be found (e.g. unplugged).
    static func coreAudioDeviceID(for captureDevice: AVCaptureDevice) -> AudioDeviceID? {
        var uid      = captureDevice.uniqueID as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var outSize  = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address  = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<CFString>.size),
            &uid,
            &outSize,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    private func makeAudioPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcm.frameLength = frameCount

        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList
        ) == noErr else { return nil }

        return pcm
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
        let ratio    = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var inputConsumed = false
        var convertError: NSError?
        converter.convert(to: output, error: &convertError) { _, outStatus in
            guard !inputConsumed else { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            inputConsumed = true
            return buffer
        }
        return convertError == nil ? output : nil
    }
}
