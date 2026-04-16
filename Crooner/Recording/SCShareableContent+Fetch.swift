import ScreenCaptureKit

extension SCShareableContent {
    /// Fetches current shareable content on macOS 12.3+.
    /// Uses the native async API on 14.2+; wraps the completion-handler form on 13.
    static func fetchCurrent() async throws -> SCShareableContent {
        if #available(macOS 14.2, *) {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        return try await withCheckedThrowingContinuation { cont in
            SCShareableContent.getWithCompletionHandler { content, error in
                if let error   { cont.resume(throwing: error);    return }
                if let content { cont.resume(returning: content); return }
                cont.resume(throwing: NSError(domain: "com.crooner.screencapture", code: -1))
            }
        }
    }
}
