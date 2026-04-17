import CoreImage
import CoreVideo
import Foundation
import ScreenCaptureKit

// MARK: - Compositor

/// Merges screen-capture frames and webcam frames into a single composited
/// pixel-buffer stream.
///
/// Usage:
/// ```swift
/// let compositor = CompositorPipeline()
/// await compositor.configure(bubbleEnabled: true, bubbleSize: .medium, bubbleCorner: .bottomRight)
/// let frames = await compositor.start(screenStream: ..., webcamStream: ..., outputSize: ...)
/// for await (buffer, time) in frames { /* encode */ }
/// await compositor.stop()
/// ```
///
/// The compositor is an `actor` so its state is automatically serialised across
/// the two concurrent frame-consuming tasks.  `ciContext` is `nonisolated` because
/// `CIContext` is thread-safe internally and doesn't need to hold the actor lock.
actor CompositorPipeline {

    // MARK: - Configuration

    private var bubbleEnabled: Bool        = true
    private var bubbleSize:    BubbleSize   = .medium
    private var bubbleCorner:  BubbleCorner = .bottomRight

    // MARK: - Internals

    /// Metal-backed context reused for every frame.  Creating a new context per
    /// frame is expensive; reuse is the primary performance requirement (CROON-018).
    /// Device-RGB working color space avoids gamma conversions when rendering
    /// BGRA pixel buffers.  Using a display/sRGB working space causes CoreImage
    /// to apply gamma correction into the output buffer, producing dark video.
    nonisolated let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: CGColorSpaceCreateDeviceRGB() as Any,
    ])

    private var pixelBufferPool:    CVPixelBufferPool?
    private var latestWebcamBuffer: CVPixelBuffer?

    private var webcamTask: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?
    private var continuation: AsyncStream<(CVPixelBuffer, CMTime)>.Continuation?

    // MARK: - Per-frame reusable objects (CROON-018)

    /// Circular mask, invalidated only when bubble diameter changes.
    private var cachedMask: (diameter: CGFloat, image: CIImage)?

    /// Long-lived CIFilter instances — inputs are updated each frame instead of
    /// allocating new filter objects at 30–60 fps.
    private let blendFilter     = CIFilter(name: "CIBlendWithMask")
    private let compositeFilter = CIFilter(name: "CISourceAtopCompositing")

    // MARK: - Effects

    /// Set by `RecordingSession` immediately after creating the compositor.
    private var effectsEngine: EffectsEngine?

    func setEffectsEngine(_ engine: EffectsEngine?) {
        effectsEngine = engine
    }

    // MARK: - Public API

    /// Update bubble options at any point — safe to call while the compositor is running.
    func configure(bubbleEnabled: Bool, bubbleSize: BubbleSize, bubbleCorner: BubbleCorner) {
        self.bubbleEnabled = bubbleEnabled
        self.bubbleSize    = bubbleSize
        self.bubbleCorner  = bubbleCorner
    }

    /// Start compositing.
    ///
    /// - Parameters:
    ///   - screenStream: Frame stream from `ScreenCaptureEngine`.
    ///   - webcamStream: Frame stream from `WebcamCaptureEngine`.
    ///   - outputSize:   Pixel dimensions of the output (from `CaptureSource.outputSize`).
    /// - Returns: An async stream of `(composited CVPixelBuffer, presentation CMTime)` pairs
    ///   at the same rate as `screenStream`.
    func start(
        screenStream: AsyncStream<CMSampleBuffer>,
        webcamStream: AsyncStream<CMSampleBuffer>,
        outputSize:   CGSize
    ) -> AsyncStream<(CVPixelBuffer, CMTime)> {
        makePixelBufferPool(size: outputSize)

        let (stream, continuation) = AsyncStream<(CVPixelBuffer, CMTime)>.makeStream()
        self.continuation = continuation

        // Webcam: keep the latest frame in memory; don't drive the output rate.
        webcamTask = Task { [weak self] in
            for await buffer in webcamStream {
                guard !Task.isCancelled, let self else { break }
                await self.cacheWebcam(CMSampleBufferGetImageBuffer(buffer))
            }
        }

        // Screen frames drive the output clock.
        screenTask = Task { [weak self] in
            for await sample in screenStream {
                guard !Task.isCancelled, let self else { break }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let time   = CMSampleBufferGetPresentationTimeStamp(sample)
                let output = await self.composite(screen: pixelBuffer, outputSize: outputSize)
                await self.continuation?.yield((output, time))
            }
            await self?.continuation?.finish()
        }

        return stream
    }

    /// Stop compositing and release resources.
    func stop() {
        webcamTask?.cancel()
        screenTask?.cancel()
        webcamTask         = nil
        screenTask         = nil
        continuation?.finish()
        continuation       = nil
        pixelBufferPool    = nil
        latestWebcamBuffer = nil
    }

    // MARK: - Private helpers

    private func cacheWebcam(_ buffer: CVPixelBuffer?) {
        latestWebcamBuffer = buffer
    }

    private func allocateOutputBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func makePixelBufferPool(size: CGSize) {
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferWidthKey              as String: Int(size.width),
            kCVPixelBufferHeightKey             as String: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey    as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs   as CFDictionary,
            bufferAttrs as CFDictionary,
            &pixelBufferPool
        )
    }

    // MARK: - Mask cache

    /// Returns a circular white-on-clear CIImage of the given diameter.
    /// The result is cached and reused across frames; it is only regenerated
    /// when the bubble size changes (CROON-018).
    private func circularMask(diameter: CGFloat) -> CIImage? {
        if let cached = cachedMask, cached.diameter == diameter {
            return cached.image
        }
        let radius = diameter / 2
        guard
            let filter = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter":  CIVector(x: radius, y: radius),
                "inputRadius0": Float(radius - 0.5),
                "inputRadius1": Float(radius),
                "inputColor0":  CIColor.white,
                "inputColor1":  CIColor.clear
            ]),
            let image = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0,
                                                               width: diameter,
                                                               height: diameter))
        else { return nil }
        cachedMask = (diameter, image)
        return image
    }

    // MARK: - Compositing

    /// Returns a composited pixel buffer for one screen frame.
    ///
    /// Steps:
    ///   1. Square-crop + scale webcam to bubble diameter
    ///   2. Mirror horizontally (selfie cameras produce a flipped image)
    ///   3. Apply circular mask via CIRadialGradient + CIBlendWithMask
    ///   4. Translate bubble to the correct corner of the output frame
    ///   5. CISourceAtopCompositing over the screen frame
    ///   6. Render into a CVPixelBufferPool buffer (avoids per-frame allocation)
    private func composite(screen: CVPixelBuffer, outputSize: CGSize) -> CVPixelBuffer {
        let screenCI = CIImage(cvPixelBuffer: screen)

        // — Webcam bubble (optional) ———————————————————————————————————————————

        var baseImage: CIImage = screenCI

        if bubbleEnabled, let webcam = latestWebcamBuffer {
            let diameter = bubbleSize.diameter
            let radius   = diameter / 2

            // Step 1 & 2: square-crop, scale, mirror
            let webcamCI  = CIImage(cvPixelBuffer: webcam)
            let srcExtent = webcamCI.extent
            let side      = min(srcExtent.width, srcExtent.height)
            let cropRect  = CGRect(
                x: (srcExtent.width  - side) / 2,
                y: (srcExtent.height - side) / 2,
                width: side, height: side
            )
            let scale = diameter / side

            let scaledWebcam = webcamCI
                .cropped(to: cropRect)
                .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                    .translatedBy(x: -diameter, y: 0))

            // Step 3: circular mask (cached per diameter)
            if let maskCI = circularMask(diameter: diameter) {
                blendFilter?.setValue(scaledWebcam,    forKey: kCIInputImageKey)
                blendFilter?.setValue(maskCI,          forKey: kCIInputMaskImageKey)
                blendFilter?.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)

                if let maskedWebcam = blendFilter?.outputImage {
                    // Step 4: position in output frame
                    // BubbleCorner uses top-left origin; CIImage uses bottom-left.
                    let inset    = radius + 8
                    let tlCenter = bubbleCorner.position(in: outputSize, inset: inset)
                    let ciOrigin = CGPoint(
                        x: tlCenter.x - radius,
                        y: outputSize.height - tlCenter.y - radius
                    )
                    let positionedBubble = maskedWebcam
                        .transformed(by: CGAffineTransform(translationX: ciOrigin.x, y: ciOrigin.y))

                    // Step 5: composite bubble atop screen
                    compositeFilter?.setValue(positionedBubble, forKey: kCIInputImageKey)
                    compositeFilter?.setValue(screenCI,         forKey: kCIInputBackgroundImageKey)
                    if let composited = compositeFilter?.outputImage {
                        baseImage = composited
                    }
                }
            }
        }

        // — Effects layer (always applied, bubble-independent) ————————————————

        if let effectsCI = renderEffects(outputSize: outputSize) {
            compositeFilter?.setValue(effectsCI, forKey: kCIInputImageKey)
            compositeFilter?.setValue(baseImage, forKey: kCIInputBackgroundImageKey)
            if let withEffects = compositeFilter?.outputImage {
                baseImage = withEffects
            }
        }

        // — Render to pooled buffer ————————————————————————————————————————————

        guard let output = allocateOutputBuffer() else { return screen }
        ciContext.render(
            baseImage,
            to: output,
            bounds: CGRect(origin: .zero, size: outputSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return output
    }

    // MARK: - Effects rendering

    /// Renders all live particles into a `CIImage` the size of `outputSize`.
    /// Returns `nil` when there are no active particles (fast path).
    private func renderEffects(outputSize: CGSize) -> CIImage? {
        guard let engine = effectsEngine else { return nil }

        let particles = engine.snapshotParticles()
        guard !particles.isEmpty else { return nil }

        let meta = engine.snapshotMeta()
        guard meta.trailEnabled || meta.clickEnabled else { return nil }

        let now = CACurrentMediaTime()
        let frame = meta.captureFrame   // AppKit coords (y-up)
        let scaleX = frame.width  > 0 ? outputSize.width  / frame.width  : 1
        let scaleY = frame.height > 0 ? outputSize.height / frame.height : 1

        // One CGContext for all particles this frame.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data:             nil,
            width:            Int(outputSize.width),
            height:           Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow:      0,
            space:            colorSpace,
            bitmapInfo:       CGImageAlphaInfo.premultipliedFirst.rawValue
                              | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        for p in particles {
            let α = p.alpha(at: now)
            guard α > 0.01 else { continue }

            // Convert global AppKit (y-up) → video-frame pixels (y-down, top-left).
            let globalPos = p.currentOrigin(at: now)
            let px = (globalPos.x - frame.minX) * scaleX
            let py = (frame.maxY - globalPos.y)  * scaleY

            guard px > -80, px < outputSize.width  + 80,
                  py > -80, py < outputSize.height + 80 else { continue }

            let sc    = CGFloat(p.scale(at: now))
            let angle = CGFloat(p.rotation(at: now))

            ctx.saveGState()
            ctx.translateBy(x: px, y: outputSize.height - py)   // flip y for CG (y-up)
            ctx.rotate(by: angle)
            ctx.scaleBy(x: sc, y: sc)
            ctx.setAlpha(α)

            switch p.kind {
            case .trail:
                if meta.trailEnabled, let emojiCI = meta.emojiImage {
                    // Draw at 40 logical-point equivalent in video pixels.
                    // scaleX converts points → pixels, normalising for display density.
                    // sc (already in the context transform) handles per-frame shrink.
                    let targetPx = 40.0 * scaleX
                    if let cg = ciContext.createCGImage(emojiCI, from: emojiCI.extent) {
                        ctx.draw(cg, in: CGRect(x: -targetPx / 2, y: -targetPx / 2,
                                               width: targetPx,   height: targetPx))
                    }
                }

            case .click:
                if meta.clickEnabled {
                    // Match overlay: 14pt base, sc already in transform.
                    let r      = 14.0 * scaleX
                    let lineW  = max(1, (2.0 * scaleX) * (1 - CGFloat(p.progress(at: now))))
                    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    ctx.setLineWidth(lineW)
                    ctx.strokeEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
                }
            }

            ctx.restoreGState()
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
