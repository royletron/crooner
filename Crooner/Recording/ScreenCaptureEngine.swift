import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Foundation

// CMSampleBuffer is a Core Foundation reference type whose contents are
// immutable once created; it's safe to cross actor boundaries.
extension CMSampleBuffer: @retroactive @unchecked Sendable {}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case streamAlreadyRunning
    case startFailed(Error)

    var errorDescription: String? {
        switch self {
        case .streamAlreadyRunning:
            return "A capture stream is already running. Call stop() before starting a new one."
        case .startFailed(let underlying):
            return "Screen capture failed to start: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Engine

/// Wraps `SCStream` and vends screen frames as an `AsyncStream<CMSampleBuffer>`.
///
/// Usage:
/// ```swift
/// let engine = ScreenCaptureEngine()
/// let frames = try await engine.start(source: .fullScreen(display: display), settings: settings)
/// for await buffer in frames { /* encode */ }
/// await engine.stop()
/// ```
final class ScreenCaptureEngine: NSObject {

    // Protected by `lock` — read/written from the SCStreamOutput queue AND
    // from async callers (start/stop).
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    private let lock = NSLock()

    private var stream: SCStream?

    /// Called on the output queue for every SCKit `.audio` sample buffer.
    /// Wire this to `AudioMixerEngine.feedSystemAudio` in `RecordingSession` (CROON-012).
    var audioBufferHandler: ((CMSampleBuffer) -> Void)?

    // A dedicated serial queue keeps frame delivery ordered and off the main thread.
    private let outputQueue = DispatchQueue(
        label: "com.crooner.screencapture.output",
        qos: .userInteractive
    )

    // MARK: - Public API

    /// Start capturing the given source and return an async stream of sample buffers.
    /// Frames are delivered at the rate specified by `settings.frameRate`.
    func start(source: CaptureSource, settings: RecordingSettings) async throws -> AsyncStream<CMSampleBuffer> {
        guard stream == nil else { throw CaptureError.streamAlreadyRunning }

        // Exclude Crooner's own windows from the capture.
        // macOS 14+: exclude at the app level so the control bar (which appears
        // after the filter is created) is also invisible.
        // macOS 13:  fall back to window-level exclusion of whatever is on-screen now.
        let (ownApps, ownWindows) = await fetchOwnContent()
        let filter = makeContentFilter(for: source, excludingApps: ownApps, fallbackWindows: ownWindows)
        let config = makeStreamConfiguration(for: source, settings: settings)

        let (asyncStream, continuation) = AsyncStream.makeStream(of: CMSampleBuffer.self)
        lock.withLock { self.continuation = continuation }

        do {
            let scStream = SCStream(filter: filter, configuration: config, delegate: self)
            try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try scStream.addStreamOutput(self, type: .audio,  sampleHandlerQueue: outputQueue)
            try await scStream.startCapture()
            stream = scStream
        } catch {
            lock.withLock {
                self.continuation?.finish()
                self.continuation = nil
            }
            throw CaptureError.startFailed(error)
        }

        return asyncStream
    }

    /// Stop the capture stream. Safe to call even if the stream is not running.
    func stop() async {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    // MARK: - SCContentFilter construction

    private func makeContentFilter(for source: CaptureSource,
                                   excludingApps: [SCRunningApplication],
                                   fallbackWindows: [SCWindow]) -> SCContentFilter {
        switch source {
        case .fullScreen(let display):
            return Self.displayFilter(display: display,
                                      excludingApps: excludingApps,
                                      fallbackWindows: fallbackWindows)
        case .window(let window):
            return SCContentFilter(desktopIndependentWindow: window)
        case .area(let display, _):
            return Self.displayFilter(display: display,
                                      excludingApps: excludingApps,
                                      fallbackWindows: fallbackWindows)
        }
    }

    private static func displayFilter(display: SCDisplay,
                                      excludingApps: [SCRunningApplication],
                                      fallbackWindows: [SCWindow]) -> SCContentFilter {
        if #available(macOS 14.0, *) {
            // App-level exclusion: covers windows that open after the filter is created.
            return SCContentFilter(display: display,
                                   excludingApplications: excludingApps,
                                   exceptingWindows: [])
        }
        // macOS 13 fallback: exclude the on-screen windows we know about right now.
        return SCContentFilter(display: display, excludingWindows: fallbackWindows)
    }

    /// Returns the SCRunningApplication(s) and SCWindow(s) that belong to this
    /// process so they can be stripped from the capture filter.
    private func fetchOwnContent() async -> ([SCRunningApplication], [SCWindow]) {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return ([], []) }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let apps    = content.applications.filter { $0.bundleIdentifier == bundleID }
        let windows = content.windows.filter     { $0.owningApplication?.bundleIdentifier == bundleID }
        return (apps, windows)
    }

    // MARK: - SCStreamConfiguration construction

    private func makeStreamConfiguration(
        for source: CaptureSource,
        settings: RecordingSettings
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let size = source.outputSize

        config.width  = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = settings.frameRate.minimumFrameInterval
        config.pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        config.capturesAudio = true
        config.showsCursor = true

        // For area capture, tell SCKit which portion of the display to capture.
        if case .area(_, let rect) = source {
            config.sourceRect = rect
        }

        return config
    }
}

// MARK: - SCStreamOutput

extension ScreenCaptureEngine: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        switch type {
        case .screen:
            lock.withLock { _ = continuation?.yield(sampleBuffer) }
        case .audio:
            audioBufferHandler?(sampleBuffer)
        case .microphone:
            break   // microphone audio routed separately on macOS 15+
        @unknown default:
            break
        }
    }
}

// MARK: - SCStreamDelegate

extension ScreenCaptureEngine: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
        self.stream = nil
    }
}
