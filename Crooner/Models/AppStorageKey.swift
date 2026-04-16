/// Centralised `UserDefaults` key strings used with `@AppStorage`.
/// All keys are namespaced to avoid collisions.
enum AppStorageKey {
    // Output
    static let codec          = "output.codec"        // VideoCodec rawValue (String)
    static let frameRate      = "output.frameRate"    // FrameRate rawValue (Int)
    static let saveFolderPath = "output.saveFolderPath"

    // Audio
    static let micVolume      = "audio.micVolume"     // Float  0 – 1
    static let sysAudioVolume = "audio.sysAudioVolume"

    // Webcam
    static let bubbleEnabled  = "webcam.bubbleEnabled"
    static let bubbleSize     = "webcam.bubbleSize"   // BubbleSize rawValue (String)
    static let bubbleCorner   = "webcam.bubbleCorner" // BubbleCorner rawValue (String)

    // General
    static let countdown      = "general.countdown"   // Int (seconds); 0 = disabled
    static let launchAtLogin  = "general.launchAtLogin"

    // Effects
    static let mouseTrailEnabled   = "effects.mouseTrailEnabled"   // Bool
    static let clickCirclesEnabled = "effects.clickCirclesEnabled" // Bool
    static let trailEmoji          = "effects.trailEmoji"          // String (single emoji)
}
