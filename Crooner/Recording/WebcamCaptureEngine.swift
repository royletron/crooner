import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Errors

enum WebcamError: LocalizedError {
    case noCameraAvailable
    case sessionAlreadyRunning
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable:     return "No camera was found on this Mac."
        case .sessionAlreadyRunning: return "A webcam session is already running. Call stop() first."
        case .cannotAddInput:        return "Failed to add the camera input to the capture session."
        case .cannotAddOutput:       return "Failed to add the video output to the capture session."
        }
    }
}

// MARK: - Engine

/// Captures webcam frames and delivers them as an `AsyncStream<CMSampleBuffer>`.
///
/// Typical usage:
/// ```swift
/// let engine = WebcamCaptureEngine()
/// let frames = try await engine.start()
/// for await buffer in frames { /* composite */ }
/// await engine.stop()
/// ```
final class WebcamCaptureEngine: NSObject {

    // MARK: - Available cameras

    /// All video input devices visible to AVFoundation, sorted by display name.
    /// Covers built-in FaceTime camera, USB cameras, and Continuity Camera (iPhone).
    static var availableCameras: [AVCaptureDevice] {
        // .continuityCamera and .external are macOS 14+;
        // .externalUnknown is the macOS 13 equivalent of .external.
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external, .continuityCamera]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
        .sorted { $0.localizedName < $1.localizedName }
    }

    // MARK: - Private state

    private var session: AVCaptureSession?
    private var continuation: AsyncStream<CMSampleBuffer>.Continuation?
    private let lock = NSLock()

    /// Dedicated queue for AVCaptureSession configuration and start/stop.
    /// Apple strongly recommends never running these on the main thread.
    private let sessionQueue = DispatchQueue(
        label: "com.crooner.webcam.session",
        qos: .userInitiated
    )
    /// Separate queue for frame delivery so session operations aren't blocked.
    private let outputQueue = DispatchQueue(
        label: "com.crooner.webcam.output",
        qos: .userInteractive
    )

    // MARK: - Public API

    /// Start capturing from `camera`, falling back to the system default if nil.
    /// Returns an `AsyncStream` that yields one `CMSampleBuffer` per frame (~30 fps).
    func start(camera: AVCaptureDevice? = nil) async throws -> AsyncStream<CMSampleBuffer> {
        guard session == nil else { throw WebcamError.sessionAlreadyRunning }

        guard let device = camera
                        ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                        ?? AVCaptureDevice.default(for: .video)
        else { throw WebcamError.noCameraAvailable }

        let (stream, continuation) = AsyncStream.makeStream(of: CMSampleBuffer.self)
        lock.withLock { self.continuation = continuation }

        do {
            try await configureAndStart(device: device)
        } catch {
            lock.withLock { self.continuation?.finish(); self.continuation = nil }
            throw error
        }

        return stream
    }

    /// Stop the capture session and finish the async stream.
    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.session?.stopRunning()
                cont.resume()
            }
        }
        session = nil
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }

    // MARK: - Session setup

    private func configureAndStart(device: AVCaptureDevice) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                do {
                    let s = AVCaptureSession()
                    s.sessionPreset = .medium
                    s.beginConfiguration()

                    // Input
                    let input = try AVCaptureDeviceInput(device: device)
                    guard s.canAddInput(input) else { throw WebcamError.cannotAddInput }
                    s.addInput(input)

                    // Output — 32BGRA matches the screen capture pixel format
                    // so the compositor can blend them without a conversion step.
                    let output = AVCaptureVideoDataOutput()
                    output.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ]
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: self.outputQueue)
                    guard s.canAddOutput(output) else { throw WebcamError.cannotAddOutput }
                    s.addOutput(output)

                    s.commitConfiguration()
                    self.session = s
                    s.startRunning()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension WebcamCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.withLock { _ = continuation?.yield(sampleBuffer) }
    }
}
