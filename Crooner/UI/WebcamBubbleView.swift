import AVFoundation
import CoreImage
import CoreVideo
import SwiftUI

// MARK: - View model

@MainActor
private final class BubbleViewModel: ObservableObject {
    @Published var frame: CGImage?

    private var engine = WebcamCaptureEngine()
    // Metal-backed context; thread-safe for reads, shared across renders.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    func start() async {
        guard let stream = try? await engine.start() else { return }
        for await buffer in stream {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { continue }
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            frame = ciContext.createCGImage(ci, from: ci.extent)
        }
    }

    func stop() async { await engine.stop() }
}

// MARK: - View

/// Circular webcam preview bubble.  Mirrors the image horizontally so the user
/// sees a "mirror" view (natural for selfie cameras).
/// Starts/stops its own `WebcamCaptureEngine` with the view's lifetime.
struct WebcamBubbleView: View {
    let diameter: CGFloat

    @StateObject private var vm = BubbleViewModel()

    var body: some View {
        Group {
            if let frame = vm.frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(x: -1, y: 1) // horizontal mirror
            } else {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Image(systemName: "person.fill")
                        .font(.system(size: diameter * 0.35))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .task { await vm.start() }
        .onDisappear { Task { await vm.stop() } }
    }
}
