/// Video filter preset applied to the composited output during recording.
enum VideoFilter: String, CaseIterable {
    case none        = "None"
    case noir        = "Noir"
    case sepia       = "Sepia"
    case oldMovie    = "Old Movie"
    case psychedelic = "Psychedelic"

    var label: String { rawValue }
}
