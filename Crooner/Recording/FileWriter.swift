import AVFoundation
import CoreMedia
import Foundation

// MARK: - Errors

enum FileWriterError: LocalizedError {
    case alreadyRunning
    case setupFailed(Error)
    case notStarted

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:         return "FileWriter is already running — call finish() first."
        case .setupFailed(let error): return "Could not create AVAssetWriter: \(error.localizedDescription)"
        case .notStarted:             return "FileWriter has not been started."
        }
    }
}

// MARK: - FileWriter

/// Writes composited video and mixed audio to a local `.mp4` file.
///
/// Usage:
/// ```swift
/// let writer  = FileWriter()
/// let fileURL = try writer.start(videoStream: ..., audioStream: ...,
///                                outputSize: ..., settings: ...)
/// writer.pause()                // paused time is cut from the output
/// writer.resume()
/// let finalURL = try await writer.finish()
/// ```
///
/// ## Timeline model
///
/// Presentation timestamps arrive from `CompositorPipeline` in wall-clock order.
/// During a pause the writer discards incoming frames; on resume it accumulates
/// the paused interval in `pauseOffset` so all subsequent frames shift left,
/// producing a seamless, gap-free output file.
///
/// Audio is clocked off a running sample counter rather than wall-clock time,
/// so it tracks the adjusted video timeline automatically — samples are simply
/// not counted during a pause, giving audio the same skip-and-continue behaviour.
actor FileWriter {

    // MARK: - AVFoundation objects

    private var assetWriter: AVAssetWriter?
    private var videoInput:  AVAssetWriterInput?
    private var audioInput:  AVAssetWriterInput?
    private var adaptor:     AVAssetWriterInputPixelBufferAdaptor?

    // MARK: - Background tasks

    private var videoTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?

    // MARK: - Pause / resume

    private var isPaused    = false
    /// Total duration skipped due to pauses; subtracted from every PTS.
    private var pauseOffset = CMTime.zero
    /// PTS of the first skipped video frame in the current pause window.
    private var pauseStart: CMTime?

    // MARK: - Audio clock

    /// Adjusted PTS of the first written video frame — used as audio epoch.
    private var sessionStart: CMTime?
    /// Running count of audio frames (samples/channel) appended so far.
    private var audioFramesWritten: Int64 = 0
    /// Cached format description — the ASBD is stable for a given microphone session,
    /// so we build it once and reuse it for every buffer (CROON-018).
    private var cachedAudioFormat: CMAudioFormatDescription?

    // MARK: - Public API

    /// Configure `AVAssetWriter`, add inputs, and begin consuming streams.
    ///
    /// Streams are drained on background `Task`s; call `finish()` to finalise the file.
    ///
    /// - Returns: The output file URL (writing is still in progress).
    func start(
        videoStream: AsyncStream<(CVPixelBuffer, CMTime)>,
        audioStream: AsyncStream<AVAudioPCMBuffer>,
        outputSize:  CGSize,
        settings:    RecordingSettings
    ) throws -> URL {
        guard assetWriter == nil else { throw FileWriterError.alreadyRunning }

        let outputURL = Self.makeOutputURL(settings: settings)
        try FileManager.default.createDirectory(
            at:   outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw FileWriterError.setupFailed(error)
        }

        // — Video input ——————————————————————————————————————————————
        let vInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey:  AVVideoCodecType(rawValue: settings.codec.avCodecKey),
                AVVideoWidthKey:  Int(outputSize.width),
                AVVideoHeightKey: Int(outputSize.height),
            ]
        )
        vInput.expectsMediaDataInRealTime = true

        let adapt = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey           as String: Int(outputSize.width),
                kCVPixelBufferHeightKey          as String: Int(outputSize.height),
            ]
        )

        // — Audio input ——————————————————————————————————————————————
        let aInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey:         kAudioFormatMPEG4AAC,
                AVSampleRateKey:       44_100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey:   128_000,
            ]
        )
        aInput.expectsMediaDataInRealTime = true

        writer.add(vInput)
        writer.add(aInput)
        writer.startWriting()

        assetWriter        = writer
        videoInput         = vInput
        audioInput         = aInput
        adaptor            = adapt
        sessionStart       = nil
        audioFramesWritten = 0
        pauseOffset        = .zero
        isPaused           = false
        pauseStart         = nil

        // Screen frames drive the output timeline.
        videoTask = Task { [weak self] in
            for await (pixelBuffer, pts) in videoStream {
                guard !Task.isCancelled, let self else { break }
                await self.appendVideo(pixelBuffer: pixelBuffer, pts: pts)
            }
        }

        // Audio is timed from the sample counter, not wall clock.
        audioTask = Task { [weak self] in
            for await pcm in audioStream {
                guard !Task.isCancelled, let self else { break }
                await self.appendAudio(pcm: pcm)
            }
        }

        return outputURL
    }

    /// Suspend writing.  Frames that arrive during a pause are discarded;
    /// the gap is removed from the output timeline on `resume()`.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        // pauseStart is captured from the first skipped video frame's PTS.
    }

    /// Resume writing after a pause.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        // pauseStart remains set; the next appendVideo call accumulates
        // the paused interval into pauseOffset and clears it.
    }

    /// Finish writing and return the output file URL.
    ///
    /// Cancels the drain tasks, marks inputs as finished, and waits for
    /// `AVAssetWriter` to flush and close the file.
    func finish() async throws -> URL {
        guard let writer = assetWriter else { throw FileWriterError.notStarted }

        videoTask?.cancel()
        audioTask?.cancel()
        videoTask = nil
        audioTask = nil

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }

        let url = writer.outputURL
        assetWriter        = nil
        videoInput         = nil
        audioInput         = nil
        adaptor            = nil
        sessionStart       = nil
        audioFramesWritten = 0
        cachedAudioFormat  = nil

        if let error = writer.error {
            throw error
        }
        return url
    }

    // MARK: - Private: video

    private func appendVideo(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let writer = assetWriter, writer.status == .writing else { return }

        if isPaused {
            if pauseStart == nil { pauseStart = pts }
            return
        }

        // On first frame after a resume: accumulate how long we were paused.
        if let ps = pauseStart {
            pauseOffset = CMTimeAdd(pauseOffset, CMTimeSubtract(pts, ps))
            pauseStart  = nil
        }

        let adjustedPTS = CMTimeSubtract(pts, pauseOffset)

        guard let vInput = videoInput, let adapt = adaptor else { return }

        if sessionStart == nil {
            sessionStart = adjustedPTS
            writer.startSession(atSourceTime: adjustedPTS)
        }

        guard vInput.isReadyForMoreMediaData else { return }
        adapt.append(pixelBuffer, withPresentationTime: adjustedPTS)
    }

    // MARK: - Private: audio

    private func appendAudio(pcm: AVAudioPCMBuffer) {
        // Hold off until the session has been started by the first video frame.
        guard !isPaused,
              let writer = assetWriter, writer.status == .writing,
              let aInput = audioInput,
              let start  = sessionStart
        else { return }

        let rate   = pcm.format.sampleRate
        let offset = CMTimeMakeWithSeconds(Double(audioFramesWritten) / rate,
                                           preferredTimescale: CMTimeScale(rate))
        let pts    = CMTimeAdd(start, offset)

        guard let sampleBuffer = makeSampleBuffer(from: pcm, presentationTime: pts) else { return }
        guard aInput.isReadyForMoreMediaData else { return }

        aInput.append(sampleBuffer)
        audioFramesWritten += Int64(pcm.frameLength)
    }

    // MARK: - AVAudioPCMBuffer → CMSampleBuffer

    private func makeSampleBuffer(from pcm: AVAudioPCMBuffer,
                                   presentationTime: CMTime) -> CMSampleBuffer? {
        // Build (or reuse) the format description from the buffer's ASBD.
        // The ASBD is stable for a given microphone session so we cache it.
        let formatDesc: CMAudioFormatDescription
        if let cached = cachedAudioFormat {
            formatDesc = cached
        } else {
            var asbd = pcm.format.streamDescription.pointee
            var desc: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(
                allocator:            kCFAllocatorDefault,
                asbd:                 &asbd,
                layoutSize:           0, layout: nil,
                magicCookieSize:      0, magicCookie: nil,
                extensions:           nil,
                formatDescriptionOut: &desc
            ) == noErr, let desc else { return nil }
            cachedAudioFormat = desc
            formatDesc = desc
        }

        // One timing entry covers the entire buffer; duration = 1 sample.
        var timing = CMSampleTimingInfo(
            duration:              CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp:       .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator:              kCFAllocatorDefault,
            dataBuffer:             nil,
            dataReady:              false,
            makeDataReadyCallback:  nil,
            refcon:                 nil,
            formatDescription:      formatDesc,
            sampleCount:            CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray:      &timing,
            sampleSizeEntryCount:   0,
            sampleSizeArray:        nil,
            sampleBufferOut:        &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator:       kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags:                      0,
            bufferList:                 pcm.audioBufferList
        )
        return sampleBuffer
    }

    // MARK: - Output URL

    private static func makeOutputURL(settings: RecordingSettings) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return settings.saveFolderURL.appending(path: "\(timestamp).mp4")
    }
}
