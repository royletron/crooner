import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import AppKit
import SwiftUI
import UserNotifications

enum PermissionStatus {
    case notDetermined
    case granted
    case denied
}

@MainActor
class PermissionManager: ObservableObject {
    @Published private(set) var cameraStatus: PermissionStatus = .notDetermined
    @Published private(set) var microphoneStatus: PermissionStatus = .notDetermined
    @Published private(set) var screenRecordingStatus: PermissionStatus = .notDetermined

    var allGranted: Bool {
        cameraStatus == .granted &&
        microphoneStatus == .granted &&
        screenRecordingStatus == .granted
    }

    // MARK: - Check

    /// Re-reads all permission statuses from the OS.
    /// Screen recording uses SCShareableContent as the authoritative check —
    /// CGPreflightScreenCaptureAccess() is unreliable on macOS 14+ with SCKit.
    func checkAll() async {
        cameraStatus = avStatus(for: .video)
        microphoneStatus = avStatus(for: .audio)
        screenRecordingStatus = await checkScreenRecording()
    }

    private func avStatus(for mediaType: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:               return .granted
        case .denied, .restricted:      return .denied
        case .notDetermined:            return .notDetermined
        @unknown default:               return .notDetermined
        }
    }

    private func checkScreenRecording() async -> PermissionStatus {
        // Fast path: CoreGraphics preflight.
        if CGPreflightScreenCaptureAccess() { return .granted }
        // CGPreflightScreenCaptureAccess() is unreliable on macOS 14+ with SCKit.
        // Attempting an actual SCShareableContent fetch is the definitive check.
        do {
            _ = try await SCShareableContent.fetchCurrent()
            return .granted
        } catch {
            return .denied
        }
    }

    // MARK: - Request

    /// Called from the onboarding screen when the user explicitly taps "Grant Access".
    /// The user interaction ensures the app is frontmost, so the TCC dialog appears reliably.
    func requestCamera() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        cameraStatus = granted ? .granted : .denied
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = granted ? .granted : .denied
    }

    /// Checks all statuses and requests notification permission (which doesn't block recording).
    /// Camera/mic are requested individually via the onboarding screen.
    func requestAll() async {
        await checkAll()
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    // MARK: - Deep links

    func openSystemSettings(for permission: Permission) {
        guard let url = URL(string: permission.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Permission descriptor

    enum Permission: CaseIterable {
        case screenRecording, camera, microphone

        var title: String {
            switch self {
            case .screenRecording:  return "Screen Recording"
            case .camera:           return "Camera"
            case .microphone:       return "Microphone"
            }
        }

        var systemImage: String {
            switch self {
            case .screenRecording:  return "rectangle.dashed"
            case .camera:           return "camera"
            case .microphone:       return "mic"
            }
        }

        var purpose: String {
            switch self {
            case .screenRecording:  return "Captures your screen during recording"
            case .camera:           return "Shows your face in the webcam bubble"
            case .microphone:       return "Records your voice narration"
            }
        }

        var settingsURL: String {
            switch self {
            case .screenRecording:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .camera:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
            case .microphone:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            }
        }
    }

    func status(for permission: Permission) -> PermissionStatus {
        switch permission {
        case .screenRecording:  return screenRecordingStatus
        case .camera:           return cameraStatus
        case .microphone:       return microphoneStatus
        }
    }
}
