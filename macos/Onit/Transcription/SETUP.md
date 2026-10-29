# Speech Transcription Feature

Real-time speech-to-text transcription using Parakeet CoreML models (from HuggingFace), integrated into the Onit app architecture.

## Features

- **Customizable shortcut** (default: ⌥Space) to toggle transcription on/off
- Real-time speech-to-text with Parakeet TDT 0.6B CoreML model
- Text inserted directly into the active text field as you speak
- Floating overlay UI with animated audio visualization
- Glass effect background consistent with the app design system
- Cancel button to abort transcription without inserting text
- Background model initialization at app launch
- Full onboarding flow with model warmup and interactive demo
- Settings page with shortcut customization and model status
- All processing done locally on-device (no cloud required)

## Prerequisites

- Xcode 15.0+
- macOS 14.0+ (Sonoma) target
- Apple Silicon Mac (M1/M2/M3/M4) for optimal performance

## Setup

### Step 1: Add Files to Xcode Project

Add the following folders to the Xcode project:
- `Onit/Transcription/` (entire folder with all subfolders)
- `Onit/Onboarding/Pages/OnboardingTranscriptionWarmup.swift`
- `Onit/Onboarding/Pages/OnboardingTranscriptionDemo.swift`
- `Onit/UI/Settings/Pages/SettingsTranscriptionBehavior.swift`

### Step 3: Verify Entitlements

The following entitlements are required in `Onit.entitlements`:

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

### Step 4: Build and Test

1. Build the project (⌘B)
2. Run the app
3. Models are downloaded automatically on first launch (~600MB)
4. Grant microphone permission when prompted (uses same permission as Screen Recording)

## Architecture Overview

```
Onit/
├── Transcription/
│   ├── TranscriptionManager.swift      # Main singleton manager
│   ├── TranscriptionState.swift        # Observable state for UI
│   ├── TranscriptionConfig.swift       # Configuration settings
│   ├── Services/
│   │   └── MicrophoneInputManager.swift    # Singleton for audio capture & level monitoring
│   └── UI/
│       ├── TranscriptionOverlayView.swift          # Floating overlay with audio bars
│       └── TranscriptionOverlayWindowController.swift  # Window positioning
│
├── Onboarding/Pages/
│   ├── OnboardingTranscriptionWarmup.swift  # Model loading status
│   └── OnboardingTranscriptionDemo.swift    # Interactive demo with editable shortcut
│
├── UI/Settings/Pages/
│   └── SettingsTranscriptionBehavior.swift  # Settings page
│
├── Data/Persistence/
│   └── Defaults.swift              # Transcription keys
│
├── Onboarding/
│   └── OnboardingStep.swift        # Transcription steps
│
├── KeyboardShortcuts/
│   ├── KeyboardShortcuts+Name.swift    # .toggleTranscription
│   └── KeyboardShortcutsManager.swift  # Shortcut execution
│
└── AppModeCoordinator.swift        # Feature lifecycle management
```

> **Note:** For permission-related files (OnboardingPermissions, SettingsSetup, MenuBarController, AppState+Status), see **[PERMISSIONS.md](../PERMISSIONS.md)**.

## Integration Points

### Defaults Keys (Defaults.swift)

```swift
// Feature toggle
static let transcriptionEnabled = Key<Bool>("transcriptionEnabled", default: true)

// Model status
static let transcriptionModelDownloaded = Key<Bool>("transcriptionModelDownloaded", default: false)
static let transcriptionModelInitialized = Key<Bool>("transcriptionModelInitialized", default: false)

// Onboarding
static let transcriptionSpecificStepsCompleted = Key<Bool>("transcriptionSpecificStepsCompleted", default: false)
```

### OnboardingStep Enum

Transcription onboarding cases:
- `transcriptionModelWarmup` - Model loading status (auto-advances when ready)
- `transcriptionDemo` - Interactive demo with editable shortcut

### Onboarding Flow

For new users with transcription enabled:
```
featureSelection → permissions → transcriptionModelWarmup → transcriptionDemo → discord → complete
```

For existing users enabling transcription later:
```
permissions → transcriptionModelWarmup → transcriptionDemo → discord
```

### Microphone Permission

The microphone permission is required for voice transcription. For detailed information about the permission system, entry points, and implementation, see **[PERMISSIONS.md](../PERMISSIONS.md)**.

### MicrophoneInputManager

Singleton manager for audio capture (permission handling documented in PERMISSIONS.md):

```swift
// Access the singleton
MicrophoneInputManager.shared

// Start/stop recording
try await MicrophoneInputManager.shared.startRecording()
MicrophoneInputManager.shared.stopRecording()

// Access audio buffer stream for processing
for await buffer in MicrophoneInputManager.shared.audioBufferStream {
    // Process audio buffer
}
```

**Key properties:**
- `isRecording: Bool` - Whether audio capture is active
- `audioLevel: Float` - Current audio level (0.0 - 1.0) for visualization
- `audioBufferStream: AsyncStream<AVAudioPCMBuffer>` - Stream of audio buffers for processing
- `error: MicrophoneError?` - Last error if any

### KeyboardShortcuts

- `.toggleTranscription` - Default: ⌥Space (customizable)
- Registered globally in `KeyboardShortcutsManager.configure()`

## Usage

### Keyboard Shortcut (Primary)

1. Click in any text field
2. Press **⌥Space** (or your custom shortcut) to start transcription
3. Speak into your microphone
4. Text is inserted in real-time
5. Press the shortcut again to stop and insert final text
6. Click the **X** button on the overlay to cancel without inserting

### Programmatic Usage

```swift
// Toggle transcription
TranscriptionManager.shared.toggle()

// Start/stop explicitly
TranscriptionManager.shared.startTranscription()
TranscriptionManager.shared.stopTranscription()

// Cancel without inserting text
TranscriptionManager.shared.cancelTranscription()

// Check state
if TranscriptionManager.shared.isTranscribing {
    print("Currently transcribing...")
}

// Access state for UI binding
let state = TranscriptionManager.shared.state
print(state.currentTranscription)  // Volatile text (may change)
print(state.insertedText)          // Confirmed inserted text
print(state.audioLevel)            // 0.0 - 1.0 for visualization
```

## Overlay UI

The transcription overlay appears at the bottom center of the screen and includes:

- **Onit logo** - Brand identification
- **Microphone icon** - Indicates recording
- **Audio level bars** - 7 animated bars showing real-time audio levels
- **Cancel button (X)** - Cancels transcription without inserting text

The overlay uses the design system:
- Glass effect background (`Backgrounds.BrushedGlass()`)
- `Color.S_10.opacity(0.4)` base
- `Color.T_7` border
- `Color.S_0` for audio bars
- `Color.S_1` for icons

## Stop vs Cancel

- **Stop** (shortcut press): Finishes transcription and inserts any remaining text
- **Cancel** (X button): Immediately stops without inserting any text

## Performance

- **Real-time factor**: ~190x on M4 Pro (1 hour audio in ~19 seconds)
- **Memory**: Models run on Apple Neural Engine (ANE)
- **Streaming latency**: ~160-320ms chunks
- **Model size**: ~600MB download, ~200MB on disk

## Settings

Access via Settings window → Transcription section:

- **Shortcut** - Customize the keyboard shortcut (default: ⌥Space)
- **Model Status** - View initialization status and retry if failed

Note: The enable toggle sits at the top of the Behavior settings page.

## Troubleshooting

### Microphone permission denied
- See **[PERMISSIONS.md](../PERMISSIONS.md)** for detailed permission troubleshooting
- The permission row appears in Onboarding and Settings only when transcription is enabled

### Reset permissions for testing
See **[PERMISSIONS.md](../PERMISSIONS.md#testing-permissions)** for commands to reset permissions.

### Model download fails
- Check internet connection
- Models download from HuggingFace on first use
- For corporate networks, configure proxy

### Text not being inserted
- Ensure cursor is in a text field
- Check that the app has accessibility permissions
- Text is copied to clipboard as fallback

### Audio format mismatch crash
- Fixed: The microphone manager now uses `nil` format to automatically use the hardware's native format
- This avoids mismatches between different microphone sample rates (16kHz vs 48kHz)

### Audio bars not moving
- Verify microphone permission is granted
- Check that the correct microphone is selected in System Settings
- The bars use RMS calculation with dB normalization for responsive visualization
