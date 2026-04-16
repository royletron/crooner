import CoreMedia
import Foundation

struct RecordingSettings {
    var frameRate: FrameRate = .thirty
    var codec: VideoCodec = .h264
    var saveFolderURL: URL = Self.defaultSaveFolder

    // MARK: - Frame rate

    enum FrameRate: Int, CaseIterable {
        case thirty = 30
        case sixty  = 60

        var label: String { "\(rawValue) fps" }

        var minimumFrameInterval: CMTime {
            CMTime(value: 1, timescale: CMTimeScale(rawValue))
        }
    }

    // MARK: - Codec

    enum VideoCodec: String, CaseIterable {
        case h264 = "H.264"
        case hevc = "HEVC / H.265"

        /// AVFoundation codec key for use with AVAssetWriterInput.
        var avCodecKey: String {
            switch self {
            case .h264: return "avc1"   // AVVideoCodecType.h264
            case .hevc: return "hvc1"   // AVVideoCodecType.hevc
            }
        }
    }

    // MARK: - Save folder

    static var defaultSaveFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appending(path: "Crooner", directoryHint: .isDirectory)
    }
}
