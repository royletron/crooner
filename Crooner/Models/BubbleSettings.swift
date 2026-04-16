import CoreGraphics
import SwiftUI

// MARK: - BubbleSize

enum BubbleSize: String, CaseIterable {
    case small  = "S"
    case medium = "M"
    case large  = "L"

    var diameter: CGFloat {
        switch self {
        case .small:  return 120
        case .medium: return 180
        case .large:  return 240
        }
    }
}

// MARK: - BubbleCorner

enum BubbleCorner: String, CaseIterable {
    case topLeft     = "topLeft"
    case topRight    = "topRight"
    case bottomLeft  = "bottomLeft"
    case bottomRight = "bottomRight"

    var alignment: Alignment {
        switch self {
        case .topLeft:     return .topLeading
        case .topRight:    return .topTrailing
        case .bottomLeft:  return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }

    /// Center point for the bubble inside `size`, inset from the edge by `inset` points.
    func position(in size: CGSize, inset: CGFloat) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: inset,              y: inset)
        case .topRight:    return CGPoint(x: size.width - inset, y: inset)
        case .bottomLeft:  return CGPoint(x: inset,              y: size.height - inset)
        case .bottomRight: return CGPoint(x: size.width - inset, y: size.height - inset)
        }
    }

    /// Return the corner whose quadrant contains `point` within `size`.
    static func nearest(to point: CGPoint, in size: CGSize) -> BubbleCorner {
        switch (point.y < size.height / 2, point.x < size.width / 2) {
        case (true,  true):  return .topLeft
        case (true,  false): return .topRight
        case (false, true):  return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}
