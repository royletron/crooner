import AppKit
import Combine
import SwiftUI

// MARK: - Controller

/// Manages a floating borderless panel that shows `ControlBarView` during recording.
///
/// The panel appears at the bottom-centre of the captured area when recording starts
/// and dismisses automatically when the session returns to `.idle`.  A 150 ms heartbeat
/// keeps it at the top of the window stack, matching the approach used by
/// `BubblePanelController`.
@MainActor
final class ControlBarController {

    private weak var session:   RecordingSession?
    private var panel:          NSPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat:      AnyCancellable?

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
            showPanel()
        case .idle, .finishing:
            hidePanel()
        case .countdown:
            break   // show nothing during countdown; button label handles that
        }
    }

    // MARK: - Panel lifecycle

    private func showPanel() {
        guard panel == nil, let session else { return }

        let rootView    = ControlBarView(session: session)
        let hosting     = NSHostingView(rootView: rootView)
        let barSize     = hosting.fittingSize
        let origin      = barOrigin(size: barSize)

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: barSize),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        p.level                    = .floating
        p.backgroundColor          = .clear
        p.isOpaque                 = false
        p.hasShadow                = false          // shadow is drawn by SwiftUI
        p.collectionBehavior       = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed     = false
        p.hidesOnDeactivate        = false
        p.canHide                  = false
        p.isMovableByWindowBackground = true        // drag from any empty area

        p.contentView = hosting
        p.orderFrontRegardless()

        panel = p

        heartbeat = Timer.publish(every: 0.15, on: .main, in: .common)
            .autoconnect()
            .sink { [weak p] _ in p?.orderFrontRegardless() }
    }

    private func hidePanel() {
        heartbeat = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Positioning

    /// Bottom-centre of the captured area, 40 pt above the edge.
    private func barOrigin(size: CGSize) -> CGPoint {
        let area: CGRect
        if let source = session?.selectedSource,
           let frame  = source.appKitScreenFrame() {
            area = frame
        } else {
            area = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        }
        return CGPoint(
            x: area.midX - size.width  / 2,
            y: area.minY + 40
        )
    }
}
