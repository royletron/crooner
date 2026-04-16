import AppKit
import Combine
import SwiftUI

/// Manages a transparent, click-through NSPanel that shows live effect particles
/// during recording for presenter visual feedback.
///
/// The panel covers the entire captured area and is intentionally excluded from
/// screen capture (Crooner's own windows are stripped from the SCKit filter).
/// The compositor renders the same particles independently into the video file.
@MainActor
final class EffectsOverlayController {

    private weak var session: RecordingSession?
    private var panel: NSPanel?
    private var subscriptions = Set<AnyCancellable>()

    init(session: RecordingSession) {
        self.session = session

        session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.handle(state) }
            .store(in: &subscriptions)
    }

    // MARK: - State handling

    private func handle(_ state: RecordingState) {
        switch state {
        case .recording, .paused:
            showOverlay()
        default:
            hideOverlay()
        }
    }

    // MARK: - Panel lifecycle

    private func showOverlay() {
        guard panel == nil, let session else { return }
        guard let screenFrame = session.selectedSource?.appKitScreenFrame() else { return }

        let rootView = EffectsOverlayView(engine: session.effectsEngine)
        let hosting  = NSHostingView(rootView: rootView)
        hosting.frame = CGRect(origin: .zero, size: screenFrame.size)

        let p = NSPanel(
            contentRect: screenFrame,
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.level              = .screenSaver      // above all other windows
        p.backgroundColor    = .clear
        p.isOpaque           = false
        p.hasShadow          = false
        p.ignoresMouseEvents = true              // fully click-through
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate  = false
        p.contentView        = hosting
        p.orderFrontRegardless()

        panel = p
    }

    private func hideOverlay() {
        panel?.orderOut(nil)
        panel = nil
    }
}
