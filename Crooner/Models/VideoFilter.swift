/// Video filter preset applied to the composited output during recording.
enum VideoFilter: String, CaseIterable {
    case none         = "None"
    case noir         = "Noir"
    case sepia        = "Sepia"
    case oldMovie     = "Old Movie"
    case psychedelic  = "Psychedelic"
    case vhs          = "VHS"
    case thermal      = "Thermal"
    case neonNoir     = "Neon Noir"
    case comic        = "Comic"
    case glitch       = "Glitch"
    case dream        = "Dream"
    case focus        = "Focus"
    case highContrast = "High Contrast"

    var label: String { rawValue }
}
