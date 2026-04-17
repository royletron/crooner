import CoreFoundation
import CoreGraphics
import Foundation

/// One live visual effect particle.
///
/// Positions are stored in **global AppKit screen coordinates**
/// (y-up, origin = bottom-left of the primary screen), matching `NSEvent.mouseLocation`.
struct EffectParticle: Identifiable {
    let id: UUID

    /// Position at birth (global AppKit coords, y-up).
    let origin: CGPoint

    /// `CACurrentMediaTime()` at the moment the particle was created.
    let birth: CFTimeInterval

    let kind: Kind

    // Per-particle randomness so the trail looks organic.
    let driftX: Double      // points/sec, horizontal wander
    let driftY: Double      // points/sec, downward drift (applied as −y in AppKit)
    let spinOffset: Double  // initial rotation in radians

    enum Kind {
        case trail(emoji: String)
        case click
    }

    var maxAge: Double {
        switch kind { case .trail: return 0.9;  case .click: return 0.45 }
    }

    /// 0 = just born, 1 = fully expired.
    func progress(at t: CFTimeInterval) -> Double {
        min(1, (t - birth) / maxAge)
    }

    func isExpired(at t: CFTimeInterval) -> Bool {
        t - birth >= maxAge
    }

    // MARK: - Derived visual properties

    func alpha(at t: CFTimeInterval) -> Double {
        let p = progress(at: t)
        switch kind {
        case .trail:
            // Linger then drop off quickly at the end.
            return p < 0.5 ? 1.0 : 1.0 - (p - 0.5) * 2.0
        case .click:
            return 1 - p
        }
    }

    func scale(at t: CFTimeInterval) -> Double {
        let p = progress(at: t)
        switch kind {
        case .trail:
            return 1.0 - p * 0.4      // shrinks to 60 %
        case .click:
            return 1.0 + p * 0.9      // expands to 1.9 ×  (subtle ripple)
        }
    }

    func rotation(at t: CFTimeInterval) -> Double {
        spinOffset + progress(at: t) * .pi * 0.6
    }

    /// Current position in global AppKit coords accounting for drift (y-up).
    func currentOrigin(at t: CFTimeInterval) -> CGPoint {
        switch kind {
        case .click:
            return origin   // pulse expands in place; never drifts
        case .trail:
            let age = t - birth
            return CGPoint(
                x: origin.x + driftX * age,
                y: origin.y - driftY * age   // subtract → downward in y-up space
            )
        }
    }
}
