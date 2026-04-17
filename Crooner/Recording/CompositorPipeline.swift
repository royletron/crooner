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
    private var videoFilter:   VideoFilter  = .none

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

    private let filterEngine    = VideoFilterEngine()

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

    func setVideoFilter(_ filter: VideoFilter) {
        videoFilter = filter
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

        // — Video filter ———————————————————————————————————————————————————————

        if videoFilter != .none {
            baseImage = filterEngine.apply(baseImage, filter: videoFilter,
                                           time: CACurrentMediaTime())
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

// MARK: - Video filter engine

/// Holds reusable `CIFilter` instances and applies them per-frame.
/// All methods are called from within the `CompositorPipeline` actor so no
/// additional synchronisation is required.
private final class VideoFilterEngine {

    // Reusable filter objects — never reallocated at frame rate.
    private let noir         = CIFilter(name: "CIPhotoEffectNoir")
    private let sepia        = CIFilter(name: "CISepiaTone")
    private let vignette     = CIFilter(name: "CIVignette")
    private let colorCtrl    = CIFilter(name: "CIColorControls")
    private let hueRotate    = CIFilter(name: "CIHueAdjust")
    private let psychSat     = CIFilter(name: "CIColorControls")
    private let bloom        = CIFilter(name: "CIBloom")

    /// Cached output of `CIRandomGenerator` — translated per frame for temporal grain.
    private lazy var noiseBase: CIImage? = CIFilter(name: "CIRandomGenerator")?.outputImage

    func apply(_ image: CIImage, filter: VideoFilter, time: CFTimeInterval) -> CIImage {
        switch filter {
        case .none:        return image
        case .noir:        return applyNoir(image)
        case .sepia:       return applySepia(image, intensity: 0.85)
        case .oldMovie:    return applyOldMovie(image, time: time)
        case .psychedelic: return applyPsychedelic(image, time: time)
        }
    }

    // MARK: - Presets

    private func applyNoir(_ image: CIImage) -> CIImage {
        noir?.setValue(image, forKey: kCIInputImageKey)
        return noir?.outputImage ?? image
    }

    private func applySepia(_ image: CIImage, intensity: Double) -> CIImage {
        sepia?.setValue(image, forKey: kCIInputImageKey)
        sepia?.setValue(intensity, forKey: kCIInputIntensityKey)
        return sepia?.outputImage ?? image
    }

    private func applyOldMovie(_ image: CIImage, time: CFTimeInterval) -> CIImage {
        // 1. Warm sepia desaturation
        var result = applySepia(image, intensity: 0.65)

        // 2. Film grain (different texture each frame via coordinate jitter)
        result = addGrain(to: result, extent: image.extent, time: time)

        // 3. Flickering vignette — two sine waves at incommensurable frequencies
        //    produce an organic, non-repeating flicker.
        let flicker = sin(time * 8.5)  * 0.07
                    + sin(time * 3.7)  * 0.05
                    + sin(time * 23.1) * 0.02
        vignette?.setValue(result,               forKey: kCIInputImageKey)
        vignette?.setValue(Float(1.4 + flicker), forKey: "inputIntensity")
        vignette?.setValue(Float(1.6),            forKey: "inputRadius")
        result = vignette?.outputImage ?? result

        // 4. Subtle brightness flicker — mimics aging projector lamp
        let brightFlicker = Float(sin(time * 5.3) * 0.025 + sin(time * 11.7) * 0.015)
        colorCtrl?.setValue(result,          forKey: kCIInputImageKey)
        colorCtrl?.setValue(brightFlicker,   forKey: "inputBrightness")
        colorCtrl?.setValue(Float(1.05),     forKey: "inputContrast")
        colorCtrl?.setValue(Float(0.0),      forKey: "inputSaturation")
        result = colorCtrl?.outputImage ?? result

        return result
    }

    private func applyPsychedelic(_ image: CIImage, time: CFTimeInterval) -> CIImage {
        // 1. Continuously rotate hue — full 360° every 4 seconds.
        hueRotate?.setValue(image,          forKey: kCIInputImageKey)
        hueRotate?.setValue(Float(time * .pi / 2.0), forKey: "inputAngle")
        var result = hueRotate?.outputImage ?? image

        // 2. Push saturation to the max and bump contrast slightly.
        psychSat?.setValue(result,     forKey: kCIInputImageKey)
        psychSat?.setValue(Float(0.0), forKey: "inputBrightness")
        psychSat?.setValue(Float(1.15), forKey: "inputContrast")
        psychSat?.setValue(Float(3.0), forKey: "inputSaturation")
        result = psychSat?.outputImage ?? result

        // 3. Bloom glow — radius pulses gently so the aura breathes.
        let breathe = Float(sin(time * 1.3) * 0.5 + 1.5)   // 1.0 … 2.0
        bloom?.setValue(result,                 forKey: kCIInputImageKey)
        bloom?.setValue(breathe * 12,           forKey: "inputRadius")
        bloom?.setValue(Float(0.8),             forKey: "inputIntensity")
        result = bloom?.outputImage ?? result

        return result
    }

    // MARK: - Film grain

    /// Overlays monochromatic noise on `image`.
    ///
    /// `CIRandomGenerator` produces a deterministic infinite texture based on
    /// pixel coordinates.  Translating by a time-derived offset gives a
    /// different crop each frame, producing temporal grain variation.
    private func addGrain(to image: CIImage, extent: CGRect, time: CFTimeInterval) -> CIImage {
        guard let noise = noiseBase else { return image }

        // Integer jitter — wraps in [0, 1023] so we stay on solid texture.
        let jx = CGFloat((Int(time * 97.0)  * 73)  & 0x3FF)
        let jy = CGFloat((Int(time * 113.0) * 41)  & 0x3FF)

        // Scale random [0,1] → [0.42, 0.58] — values near 0.5 barely affect
        // the overlay blend; values at the edges create subtle grain.
        let grain = noise
            .transformed(by: CGAffineTransform(translationX: jx, y: jy))
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector":    CIVector(x: 0.16, y: 0,    z: 0,    w: 0),
                "inputGVector":    CIVector(x: 0,    y: 0.16, z: 0,    w: 0),
                "inputBVector":    CIVector(x: 0,    y: 0,    z: 0.16, w: 0),
                "inputAVector":    CIVector(x: 0,    y: 0,    z: 0,    w: 1),
                "inputBiasVector": CIVector(x: 0.42, y: 0.42, z: 0.42, w: 0),
            ])

        // CIOverlayBlendMode: neutral at 0.5, darkens below, lightens above.
        return grain.applyingFilter("CIOverlayBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ])
    }
}
