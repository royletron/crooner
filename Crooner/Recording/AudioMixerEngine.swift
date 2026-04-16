import AVFoundation
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
    case engineStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .engineAlreadyRunning:       return "Audio engine is already running. Call stop() first."
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

    // MARK: - Public API

    /// Build the graph, start the engine, and return a stream of mixed PCM buffers.
    func start() throws -> AsyncStream<AVAudioPCMBuffer> {
        guard !engine.isRunning else { throw AudioMixerError.engineAlreadyRunning }

        attachAndConnect()
        applyVolumes()

        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        lock.withLock { self.continuation = continuation }

        // Install tap after connecting but before starting.
        let tapFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            lock.withLock { self.continuation?.yield(buffer) }
        }

        startLevelMonitoring()

        do {
            try engine.start()
        } catch {
            engine.mainMixerNode.removeTap(onBus: 0)
            if isMonitoringLevel { micMixer.removeTap(onBus: 0); isMonitoringLevel = false }
            lock.withLock { self.continuation?.finish(); self.continuation = nil }
            throw AudioMixerError.engineStartFailed(error)
        }

        sysAudioPlayer.play()
        return stream
    }

    /// Stop the engine and finish the output stream.
    func stop() {
        engine.mainMixerNode.removeTap(onBus: 0)
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

    private func attachAndConnect() {
        engine.attach(micMixer)
        engine.attach(sysAudioPlayer)
        engine.attach(sysAudioMixer)

        // Mic: inputNode → micMixer → mainMixerNode
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        if micFormat.sampleRate > 0 {
            engine.connect(engine.inputNode, to: micMixer, format: micFormat)
            engine.connect(micMixer, to: engine.mainMixerNode, format: micFormat)
        }

        // System audio: playerNode → sysAudioMixer → mainMixerNode
        engine.connect(sysAudioPlayer, to: sysAudioMixer, format: Self.systemAudioFormat)
        engine.connect(sysAudioMixer,  to: engine.mainMixerNode, format: Self.systemAudioFormat)
    }

    private func applyVolumes() {
        for source in sources {
            mixerNode(for: source.type).outputVolume = source.enabled ? source.volume : 0
        }
    }

    private func mixerNode(for type: AudioSourceType) -> AVAudioMixerNode {
        type == .microphone ? micMixer : sysAudioMixer
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
