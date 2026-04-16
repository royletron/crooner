import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureSource {
    case fullScreen(display: SCDisplay)
    case window(SCWindow)
    /// A rectangular sub-region of a display. `rect` is in the display's
    /// point coordinate space (origin bottom-left, matching AppKit / SCKit).
    case area(display: SCDisplay, rect: CGRect)

    // MARK: - Output dimensions

    /// Pixel dimensions for the encoded output.
    /// Values are rounded up to the nearest even integer (codec requirement).
    var outputSize: CGSize {
        switch self {
        case .fullScreen(let display):
            return CGSize(
                width: evenUp(CGFloat(display.width)),
                height: evenUp(CGFloat(display.height))
            )
        case .window(let window):
            return CGSize(
                width: evenUp(window.frame.width),
                height: evenUp(window.frame.height)
            )
        case .area(_, let rect):
            return CGSize(
                width: evenUp(rect.width),
                height: evenUp(rect.height)
            )
        }
    }

    // MARK: - Display resolution

    /// The backing display for this source (used for content filter construction).
    var display: SCDisplay? {
        switch self {
        case .fullScreen(let d):    return d
        case .window:               return nil
        case .area(let d, _):       return d
        }
    }

    // MARK: - Screen frame (bubble positioning)

    /// Capture region in AppKit screen coordinates (origin = bottom-left of primary
    /// screen, y increases upward).  Used to constrain the webcam bubble panel.
    func appKitScreenFrame() -> CGRect? {
        switch self {
        case .fullScreen(let display):
            return NSScreen.matching(display)?.frame

        case .window(let window):
            // SCWindow.frame uses CG coordinates (y-down, origin top-left of primary screen).
            // Convert to AppKit coordinates (y-up, origin bottom-left of primary screen).
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let cgRect = window.frame
            return CGRect(
                x: cgRect.minX,
                y: primaryHeight - cgRect.maxY,
                width: cgRect.width,
                height: cgRect.height
            )

        case .area(let display, let rect):
            // rect is display-relative with top-left origin (from AreaSelectorOverlay).
            // Convert: appKit.y = screen.maxY − rect.maxY
            guard let screen = NSScreen.matching(display) else { return nil }
            return CGRect(
                x: screen.frame.minX + rect.minX,
                y: screen.frame.maxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        }
    }

    // MARK: - Helpers

    private func evenUp(_ value: CGFloat) -> CGFloat {
        (value.truncatingRemainder(dividingBy: 2) == 0) ? value : value + 1
    }
}

// MARK: - NSScreen helper

private extension NSScreen {
    static func matching(_ display: SCDisplay) -> NSScreen? {
        screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                == display.displayID
        }
    }
}
