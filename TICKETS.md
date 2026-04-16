# Crooner — Engineering Tickets

Tickets are ordered by dependency. Each ticket is self-contained with enough context for Claude to pick up and implement without re-reading the whole spec.

---

## EPIC 0 — Project Bootstrap

### CROON-001: Xcode project setup & entitlements

**Type**: Setup  
**Depends on**: nothing  
**Size**: S

**Goal**: Create a runnable macOS app skeleton that satisfies all permission requirements.

**Tasks**:
- Create a new Xcode project: macOS App, SwiftUI, bundle ID `com.crooner.app`
- Minimum deployment: macOS 13.0
- Add `Crooner.entitlements` with:
  - `com.apple.security.device.camera` — true
  - `com.apple.security.device.microphone` — true
  - `com.apple.security.screen-recording` — true (non-sandboxed) OR request via `SCShareableContent` (sandboxed)
- Add `Info.plist` usage description strings:
  - `NSCameraUsageDescription`
  - `NSMicrophoneUsageDescription`
  - `NSScreenCaptureUsageDescription` (macOS 14+)
- Add the `ScreenCaptureKit`, `AVFoundation`, `VideoToolbox`, and `CoreVideo` frameworks
- Confirm app builds and launches to a blank window

**Acceptance**: App launches, no build errors, entitlements file present and linked.

---

### CROON-002: Menu bar app skeleton

**Type**: UI  
**Depends on**: CROON-001  
**Size**: S

**Goal**: Convert the app to a menu bar agent (no Dock icon) with a status item that opens a popover.

**Tasks**:
- In `CroonerApp.swift`, set `LSUIElement = YES` in Info.plist (hide Dock icon)
- Create `NSStatusItem` in `AppDelegate` with a camera SF Symbol icon
- Clicking the status item opens a SwiftUI `NSPopover`
- Popover contains placeholder text "Crooner" and a Quit button
- App quits when menu bar item is removed

**Acceptance**: App runs in menu bar, no Dock icon, popover opens/closes.

---

### CROON-003: Permission request flow

**Type**: Feature  
**Depends on**: CROON-001  
**Size**: S

**Goal**: On first launch, request all required permissions and guide user to System Settings if denied.

**Tasks**:
- Create `PermissionManager.swift` with methods:
  - `requestCameraAccess() async -> Bool`
  - `requestMicrophoneAccess() async -> Bool`
  - `requestScreenRecordingAccess() -> Bool` (screen recording can't be requested programmatically on macOS 14; open System Settings deep link instead)
- On first launch, run the permission sequence: screen recording → camera → mic
- If any permission is denied, show an inline prompt in the popover with a "Open System Settings" button that deep-links to `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
- Store permission state in `@AppStorage`

**Acceptance**: Running the app on a fresh simulator or after permission reset shows the prompt; granting all permissions clears the prompt.

---

## EPIC 1 — Screen Capture

### CROON-004: ScreenCaptureKit stream setup

**Type**: Feature  
**Depends on**: CROON-003  
**Size**: M

**Goal**: Wrap `SCStream` in a clean engine class that can start/stop a capture of a given source.

**Tasks**:
- Create `ScreenCaptureEngine.swift` conforming to `SCStreamOutput` and `SCStreamDelegate`
- Implement `func start(source: CaptureSource, config: RecordingSettings) async throws`
- Implement `func stop() async`
- `CaptureSource` enum:
  ```swift
  enum CaptureSource {
    case fullScreen(display: SCDisplay)
    case window(SCWindow)
    case area(display: SCDisplay, rect: CGRect)
  }
  ```
- Configure `SCStreamConfiguration`:
  - `width`, `height` from source
  - `minimumFrameInterval` from settings (30 or 60 fps)
  - `pixelFormat` = `kCVPixelFormatType_32BGRA`
  - `capturesAudio` = false (audio handled separately)
- Deliver frames via `func stream(_:didOutputSampleBuffer:of:)` → publish via `AsyncStream<CMSampleBuffer>`

**Acceptance**: Engine streams frames in a unit test / preview without crashing; stop cleanly tears down the stream.

---

### CROON-005: Source picker UI

**Type**: UI  
**Depends on**: CROON-004  
**Size**: M

**Goal**: UI in the popover for selecting what to capture before recording starts.

**Tasks**:
- Create `SourcePickerView.swift`
- Top-level segmented control: **Full Screen** | **Window** | **Area**
- **Full Screen**: list all `SCDisplay`s with thumbnails (use `SCShareableContent.getWithCompletionHandler`)
- **Window**: scrollable list of all `SCWindow`s with app icon + window title; filter to visible, non-Crooner windows; show a live thumbnail using `SCScreenshotManager`
- **Area**: show a "Select Area…" button; clicking it presents the area selector overlay (CROON-006)
- Selecting any source stores it in `RecordingSession.selectedSource`
- "Record" button at bottom (disabled until source selected)

**Acceptance**: All three modes are selectable; the window list populates with running apps.

---

### CROON-006: Area selection overlay

**Type**: Feature  
**Depends on**: CROON-004  
**Size**: M

**Goal**: Full-screen transparent overlay window for dragging a capture region.

**Tasks**:
- Create a borderless, transparent `NSWindow` covering the entire display (level `.screenSaver`)
- Draw a dimming overlay in `NSView`; on drag, draw a clear selection rect with a bright border
- Show W×H dimensions label near the selection handle
- On mouseUp, store the `CGRect` and dismiss the overlay
- Expose result via `async` function: `func selectArea() async -> CGRect`
- Minimum selection: 100×100 px

**Acceptance**: Clicking "Select Area" dims the screen; user can drag a rectangle; rectangle is stored correctly.

---

## EPIC 2 — Webcam

### CROON-007: Webcam capture engine

**Type**: Feature  
**Depends on**: CROON-001  
**Size**: S

**Goal**: Capture webcam frames via `AVCaptureSession`.

**Tasks**:
- Create `WebcamCaptureEngine.swift`
- `AVCaptureSession` with `.medium` quality preset
- Add `AVCaptureDeviceInput` for default `.builtInWideAngleCamera`
- Add `AVCaptureVideoDataOutput` with `kCVPixelFormatType_32BGRA`
- Deliver frames via `AVCaptureVideoDataOutputSampleBufferDelegate` → `AsyncStream<CMSampleBuffer>`
- Implement `start()` / `stop()`
- List available cameras (for multi-camera Macs)

**Acceptance**: Frames arrive in the async stream at ~30 fps; stop() releases the session.

---

### CROON-008: Webcam bubble UI

**Type**: UI  
**Depends on**: CROON-007  
**Size**: M

**Goal**: Show a draggable, circular webcam preview in the source picker and as a burned-in overlay during recording.

**Tasks**:
- Create `WebcamBubbleView.swift` — a SwiftUI `View` rendering the latest webcam `CIImage` in a circle with a subtle shadow
- Expose size enum: `Small` (120 px), `Medium` (180 px), `Large` (240 px)
- In the source picker: show bubble in the corner as a preview; toggle on/off
- Store `bubbleEnabled: Bool`, `bubbleSize`, `bubbleCorner: Corner` in `RecordingSession`
- During recording: bubble position is burned into the composited output (CROON-010), not a floating window

**Acceptance**: Webcam preview renders in the source picker; toggling hides it; dragging to corners snaps.

---

## EPIC 3 — Audio

### CROON-009: Audio mixer engine

**Type**: Feature  
**Depends on**: CROON-001  
**Size**: M

**Goal**: Capture and mix microphone + system audio into a single PCM stream for encoding.

**Tasks**:
- Create `AudioMixerEngine.swift` using `AVAudioEngine`
- **Microphone path**: `AVAudioInputNode` → `mixerNode`
- **System audio path**: `SCStreamConfiguration.capturesAudio = true` on the `SCStream`; extract audio `CMSampleBuffer`s from the stream delegate's `.audio` type; convert to `AVAudioPCMBuffer`; feed into a manual `AVAudioPlayerNode` → `mixerNode`
- Output tap on `mixerNode` → `AsyncStream<AVAudioPCMBuffer>`
- `AudioSource` model:
  ```swift
  struct AudioSource: Identifiable {
    let id: UUID
    let name: String
    let type: AudioSourceType  // .microphone, .systemAudio
    var volume: Float          // 0.0 – 1.0
    var enabled: Bool
  }
  ```
- Mute support: set `volume = 0` on the relevant mixer input node
- Global mute: write silent buffers instead of real audio

**Acceptance**: Mixed audio stream contains both mic and system audio when both are enabled; muting one source silences only that source in the output.

---

## EPIC 4 — Compositor & Encoder

### CROON-010: Compositor pipeline

**Type**: Feature  
**Depends on**: CROON-004, CROON-007  
**Size**: L

**Goal**: Merge screen capture frames and webcam frames into a single pixel buffer stream.

**Tasks**:
- Create `CompositorPipeline.swift`
- Subscribe to both `ScreenCaptureEngine` and `WebcamCaptureEngine` frame streams
- On each screen frame, if webcam is enabled:
  - Crop webcam buffer to a square
  - Scale to bubble size
  - Apply circular mask using `CIFilter` (`CIMaskToAlpha` or `CIRadialGradient` clip)
  - Blit into a copy of the screen pixel buffer at the configured corner position with padding
- If webcam is disabled, pass screen buffer through unchanged
- Output: `AsyncStream<CVPixelBuffer>` at the screen capture frame rate
- Must maintain timing: use screen frame's `CMSampleBuffer` presentation timestamp

**Notes**: Use `CIContext` (Metal-backed) for all image operations. Avoid `CGContext` for performance.

**Acceptance**: Compositor output shows webcam circle overlaid on screen content; no visible tearing; CPU usage reasonable (<30% on M1).

---

### CROON-011: File writer (AVAssetWriter)

**Type**: Feature  
**Depends on**: CROON-010, CROON-009  
**Size**: L

**Goal**: Write composited video and mixed audio to a local `.mp4` file using `AVAssetWriter`.

**Tasks**:
- Create `FileWriter.swift`
- `AVAssetWriter` with `outputURL` pointing to `~/Movies/Crooner/<timestamp>.mp4`
- **Video input**: `AVAssetWriterInput` with `AVVideoCodecKey` = H.264 or HEVC (from settings); `AVVideoWidthKey`/`AVVideoHeightKey` from source; `expectsMediaDataInRealTime = true`
- **Audio input**: `AVAssetWriterInput` with `AVFormatIDKey` = `kAudioFormatMPEG4AAC`, 2 channels, 44100 Hz
- Use `AVAssetWriterInputPixelBufferAdaptor` for video
- Consume compositor's `CVPixelBuffer` stream for video; convert timestamps to `CMTime`
- Consume audio mixer's `AVAudioPCMBuffer` stream; convert to `CMSampleBuffer` for audio input
- Implement `pause()` / `resume()` by buffering incoming frames during pause (write silence + black? No — just hold writes and resume with correct time offsets)
- Implement `finish() async throws -> URL`
- Create `~/Movies/Crooner/` directory if it doesn't exist

**Notes on pause**: The cleanest approach is to skip appending frames during pause and adjust the next segment's start time so the output timeline is continuous (no gap in the file). This means paused time is simply cut out.

**Acceptance**: After stop, a valid MP4 exists at the expected path; file plays in QuickTime Player; pausing and resuming produces a seamless cut in the output.

---

## EPIC 5 — Recording Session Coordinator

### CROON-012: RecordingSession coordinator

**Type**: Feature  
**Depends on**: CROON-004 through CROON-011  
**Size**: M

**Goal**: Single `ObservableObject` that wires all engines together and drives the UI state machine.

**Tasks**:
- Create `RecordingSession.swift` as `@MainActor ObservableObject`
- State enum:
  ```swift
  enum RecordingState {
    case idle, countdown(Int), recording, paused, finishing
  }
  ```
- Published properties: `state`, `elapsed: TimeInterval`, `isMuted: Bool`, `selectedSource`, `audioSources`, `bubbleEnabled`, etc.
- `func startRecording() async throws`:
  1. Validate permissions
  2. Run countdown timer (fires UI updates)
  3. Start `ScreenCaptureEngine` → `WebcamCaptureEngine` → `AudioMixerEngine` → `CompositorPipeline` → `FileWriter`
  4. Start 1-second timer to update `elapsed`
- `func pauseRecording()` / `func resumeRecording()`
- `func muteToggle()`
- `func stopRecording() async throws -> URL`
- On stop: call `FileWriter.finish()`, fire local notification, reset state to `.idle`

**Acceptance**: Full pipeline runs end-to-end; a valid MP4 is produced; state transitions are correct.

---

## EPIC 6 — Recording Controls UI

### CROON-013: Floating control bar

**Type**: UI  
**Depends on**: CROON-012  
**Size**: M

**Goal**: Always-on-top floating panel shown during recording with pause, mute, and stop controls.

**Tasks**:
- Create `ControlBarView.swift` in SwiftUI
- Host in a borderless `NSPanel` with `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .stationary]`
- Panel appears at bottom-center of the recorded display when recording starts
- Panel is draggable (mouse-down on its background moves it)
- Controls: red record dot + `MM:SS` timer | pause icon | mic icon (muted = strikethrough) | stop (square) button
- Pause icon toggles to play icon when paused; timer stops incrementing
- Stop button triggers `RecordingSession.stopRecording()`; panel dismisses when state returns to `.idle`

**Acceptance**: Panel appears on record start; updates timer each second; pause/mute/stop work correctly; panel is draggable.

---

## EPIC 7 — Post-Recording & Settings

### CROON-014: Save notification & Finder reveal

**Type**: Feature  
**Depends on**: CROON-012  
**Size**: S

**Goal**: After recording finishes, notify the user and let them reveal the file.

**Tasks**:
- Use `UNUserNotificationCenter` to post a local notification: title "Recording saved", body with filename
- Request notification permission on first launch (add to `PermissionManager`)
- Notification action: "Show in Finder" — calls `NSWorkspace.shared.activateFileViewerSelecting([url])`
- In the popover, show a "Last Recording" row with the filename and a Finder button; update after each recording

**Acceptance**: Notification appears after stop; clicking "Show in Finder" reveals the file.

---

### CROON-015: Settings panel

**Type**: UI  
**Depends on**: CROON-001  
**Size**: M

**Goal**: Persistent user preferences stored in `UserDefaults` / `@AppStorage`.

**Tasks**:
- Create `SettingsView.swift` opened via `Settings {}` scene or a sheet from the popover
- Sections:
  - **Output**: save folder (folder picker), codec (H.264 / HEVC), frame rate (30 / 60)
  - **Audio**: default sources, per-source default volume
  - **Webcam**: default size, default corner
  - **General**: countdown duration, launch at login
- Back all fields with `@AppStorage` keys defined in a `Settings.swift` constants file
- Launch at login: use `SMAppService.mainApp.register()` (macOS 13+)

**Acceptance**: Changing settings persists across app relaunches; recording uses the persisted values.

---

## EPIC 8 — Polish & Distribution

### CROON-016: App icon & branding

**Type**: Design/Asset  
**Depends on**: CROON-002  
**Size**: S

**Tasks**:
- Create an app icon set (all required macOS sizes) in `Assets.xcassets`
- Menu bar icon: SF Symbol `record.circle` or custom 22×22 template image
- Suggested palette: dark background, coral/red record dot

---

### CROON-017: Notarization & distribution

**Type**: DevOps  
**Depends on**: All  
**Size**: M

**Tasks**:
- Configure release scheme with hardened runtime (`com.apple.security.cs.allow-jit` if needed)
- Set up `Archive → Distribute App → Developer ID` workflow in Xcode
- Notarise with `notarytool` via CI or manually
- Produce a signed `.dmg` using `create-dmg` or `hdiutil`
- Document the release process in `RELEASING.md`

---

### CROON-018: Performance pass

**Type**: Engineering  
**Depends on**: CROON-012  
**Size**: M

**Goal**: Profile and optimise the recording pipeline to keep CPU < 20% and memory stable on Apple Silicon.

**Tasks**:
- Profile with Instruments: Time Profiler + Core Animation
- Ensure `CIContext` is Metal-backed and reused (not recreated per frame)
- Verify pixel buffer pools are used (`CVPixelBufferPool`) to avoid per-frame allocations
- Check that `AVAssetWriterInput` appends happen off the main thread
- Validate that stopping the session drains the async streams cleanly (no leaks)

---

## Ticket Summary

| ID | Title | Epic | Size | Depends on |
|---|---|---|---|---|
| CROON-001 | Xcode project setup & entitlements | 0 | S | — |
| CROON-002 | Menu bar app skeleton | 0 | S | 001 |
| CROON-003 | Permission request flow | 0 | S | 001 |
| CROON-004 | ScreenCaptureKit stream setup | 1 | M | 003 |
| CROON-005 | Source picker UI | 1 | M | 004 |
| CROON-006 | Area selection overlay | 1 | M | 004 |
| CROON-007 | Webcam capture engine | 2 | S | 001 |
| CROON-008 | Webcam bubble UI | 2 | M | 007 |
| CROON-009 | Audio mixer engine | 3 | M | 001 |
| CROON-010 | Compositor pipeline | 4 | L | 004, 007 |
| CROON-011 | File writer (AVAssetWriter) | 4 | L | 010, 009 |
| CROON-012 | RecordingSession coordinator | 5 | M | 004–011 |
| CROON-013 | Floating control bar | 6 | M | 012 |
| CROON-014 | Save notification & Finder reveal | 7 | S | 012 |
| CROON-015 | Settings panel | 7 | M | 001 |
| CROON-016 | App icon & branding | 8 | S | 002 |
| CROON-017 | Notarization & distribution | 8 | M | All |
| CROON-018 | Performance pass | 8 | M | 012 |
