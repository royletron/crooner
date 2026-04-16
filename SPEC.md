# Crooner — macOS Screen Recorder: Product Spec

## Overview

Crooner is a native macOS screen recorder for product demos. It records to local MP4 files with no cloud backend. The experience mirrors Loom's simplicity: pick what to capture, press record, and get a file when done.

---

## Target Platform

- **OS**: macOS 13.0+ (Ventura)
- **Language**: Swift 5.9+
- **UI Framework**: SwiftUI
- **Distribution**: Direct download (notarized .app) or Mac App Store (sandboxed variant)

---

## Tech Stack

| Concern | Framework |
|---|---|
| Screen capture | `ScreenCaptureKit` (macOS 12.3+) |
| Webcam capture | `AVCaptureSession` |
| Audio capture | `AVCaptureSession` + `AVAudioEngine` |
| Multi-source audio mixing | `AVAudioEngine` mixer nodes |
| Video encoding | `VideoToolbox` via `AVAssetWriter` (H.264 / HEVC) |
| Compositing (webcam overlay) | `Core Video` pixel buffer merge before encode |
| File output | `AVAssetWriter` → local `.mp4` |
| UI | SwiftUI + AppKit where needed |

---

## Core User Flows

### Flow 1 — Start a Recording

1. Launch app → menu bar icon appears
2. Click icon → capture source picker sheet opens
3. User selects **Window**, **Area**, or **Full Screen**
4. User toggles webcam bubble on/off; optionally repositions it
5. User selects audio source(s) — mic, system audio, or both
6. Click **Record** → countdown (3 s) → recording begins
7. Floating control bar appears

### Flow 2 — During Recording

- Control bar shows: elapsed time, **Pause/Resume**, **Mute/Unmute**, **Stop**
- Webcam bubble is visible in-app overlay (rendered into the output)
- Mute silences the audio track in output (not just monitoring)
- Pause suspends writing to the file (seamlessly resumes)

### Flow 3 — Finish Recording

1. Click **Stop** → encoding finalises → file saved to `~/Movies/Crooner/`
2. Notification fires: "Recording saved — Show in Finder"
3. Optional: quick-look thumbnail preview before dismissing

---

## Screen Capture Modes

### Full Screen
- Uses `SCDisplay` to capture the entire display
- Multi-monitor support: user picks which display

### Window
- Presents a list of running windows via `SCWindow`
- User clicks the target window
- Captures only that window; background is excluded

### Area (Region)
- Crosshair overlay; user drags a rectangle
- Implemented with a transparent `NSWindow` overlay
- Captures the defined `CGRect` from the display stream

---

## Webcam Bubble

- Rendered as a circular (or rounded-rect) overlay in a corner
- Defaults to bottom-right; draggable to any corner or free position
- Composited into the output pixel buffer before encoding (burned in)
- Toggle on/off before or during recording
- Size: Small / Medium / Large (configurable)

---

## Audio

### Sources
- **Microphone** — any `AVCaptureDevice` of type `.microphone`
- **System Audio** — via `ScreenCaptureKit`'s `SCStreamConfiguration.capturesAudio`
- **Mixed** — both sources merged via `AVAudioEngine` mixer node

### Controls
- Per-source volume slider (pre-recording)
- Global mute button during recording (writes silence to file for muted segments)
- The audio track is always present in the MP4 (avoids re-mux on unmute)

---

## Output File

- **Container**: MPEG-4 (`.mp4`)
- **Video codec**: H.264 (default) or HEVC/H.265 (user preference)
- **Video bitrate**: auto (based on resolution) or manual
- **Audio codec**: AAC, 44.1 kHz, stereo
- **Resolution**: matches capture source (no downscale by default)
- **Frame rate**: 30 or 60 fps (user preference)
- **Save path**: `~/Movies/Crooner/YYYY-MM-DD HH-mm-ss.mp4`

---

## Recording Controls (Floating Bar)

The control bar is a small, always-on-top `NSPanel` (not in Dock, not in Mission Control).

| Control | Behaviour |
|---|---|
| Timer | Shows MM:SS elapsed |
| Pause / Resume | Suspends/resumes `AVAssetWriter` writes |
| Mute / Unmute | Inserts silence in audio track |
| Stop | Finalises file, dismisses bar |

---

## Permissions Required

| Permission | Purpose |
|---|---|
| `Screen Recording` | `ScreenCaptureKit` content capture |
| `Camera` | Webcam bubble |
| `Microphone` | Mic audio |
| `NSSystemAudioRecordingUsageDescription` | System audio (macOS 14+) |

Crooner requests permissions on first launch and guides the user to System Settings if denied.

---

## Settings Panel

- Default save location
- Default codec (H.264 / HEVC)
- Default frame rate (30 / 60)
- Default audio sources
- Webcam bubble default size/position
- Countdown duration (0 / 3 / 5 s)
- Launch at login toggle

---

## Out of Scope (v1)

- Cloud upload / sharing links
- Annotation / drawing tools during recording
- Video trimming / editing
- Transcription
- GIF export
- Custom branding / watermarks

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                     SwiftUI App                     │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │ SourcePicker │  │ControlBarView│  │ Settings  │ │
│  └──────┬───────┘  └──────┬───────┘  └───────────┘ │
│         │                 │                         │
│  ┌──────▼─────────────────▼───────────────────────┐ │
│  │              RecordingSession                  │ │
│  │  (ObservableObject — single source of truth)  │ │
│  └────┬──────────────┬────────────────┬───────────┘ │
│       │              │                │             │
│  ┌────▼────┐  ┌──────▼──────┐  ┌─────▼──────────┐  │
│  │ Screen  │  │   Webcam    │  │  AudioMixer    │  │
│  │Capture  │  │  Capture    │  │  (AVAudioEngine│  │
│  │Engine   │  │  Engine     │  │  + SCKit audio)│  │
│  └────┬────┘  └──────┬──────┘  └─────┬──────────┘  │
│       │              │                │             │
│  ┌────▼──────────────▼────────────────▼───────────┐ │
│  │              CompositorPipeline                │ │
│  │   (merges screen + webcam pixel buffers)       │ │
│  └────────────────────┬───────────────────────────┘ │
│                       │                             │
│  ┌────────────────────▼───────────────────────────┐ │
│  │              FileWriter                        │ │
│  │     (AVAssetWriter → local .mp4)               │ │
│  └────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

---

## Project Structure (Target)

```
Crooner/
├── App/
│   ├── CroonerApp.swift          # @main, menu bar setup
│   └── AppDelegate.swift
├── UI/
│   ├── MenuBarView.swift
│   ├── SourcePickerView.swift
│   ├── ControlBarView.swift
│   ├── WebcamBubbleView.swift
│   └── SettingsView.swift
├── Recording/
│   ├── RecordingSession.swift    # ObservableObject coordinator
│   ├── ScreenCaptureEngine.swift # SCStream wrapper
│   ├── WebcamCaptureEngine.swift # AVCaptureSession wrapper
│   ├── AudioMixerEngine.swift    # AVAudioEngine multi-source
│   ├── CompositorPipeline.swift  # pixel buffer compositor
│   └── FileWriter.swift          # AVAssetWriter wrapper
├── Models/
│   ├── CaptureSource.swift
│   ├── AudioSource.swift
│   └── RecordingSettings.swift
└── Resources/
    └── Crooner.entitlements
```
