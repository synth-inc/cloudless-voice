# On-device Transcription

This feature provides voice-to-text transcription using a user-selectable on-device ASR model. The user picks the active model from **Settings → Advanced Settings → AI Model → Browse all models…** (the "Local AI Models" sheet); each model runs entirely on Apple Silicon with no cloud round-trip.

## Available models

The picker (`SettingsASRModelsPickerSheet.swift`) exposes 4 user-visible models on top of a 5th legacy backend hidden from the UI:

| Model id | Backend (`TranscriptionBackend`) | Size | Languages | Inference framework | Source |
|---|---|---|---|---|---|
| `parakeet-v3` *(default)* | `.parakeetCoreML` | ~700 MB | Multilingual (25 EU) | Custom CoreML engine (`ParakeetCoreMLEngine`) | `FluidInference/parakeet-tdt-0.6b-v3-coreml` (HF) |
| `whisper-large-turbo-v3` | `.whisperCoreML` | ~950 MB | English (per Figma) | WhisperKit | `argmaxinc/whisperkit-coreml` (HF) |
| `whisper-medium` | `.whisperCoreML` | ~1.53 GB | Multilingual | WhisperKit | `argmaxinc/whisperkit-coreml` (HF) |
| `moonshine-base` | `.moonshineONNX` | ~250 MB | English | `MoonshineVoice.Transcriber` (ONNX Runtime, embedded as binary target) | Moonshine CDN (`download.moonshine.ai`, **not** HuggingFace) |
| `qwen3-asr-0.6b` | `.mlx` | ~700 MB | Multilingual (52 langs) | `Qwen3ASRModel` (MLX) | `mlx-community/Qwen3-ASR-0.6B-4bit` (HF) |
| `fluidAudio` *(legacy, hidden)* | `.fluidAudio` | n/a | n/a | FluidAudio Swift package | n/a |

Catalog lives in `Onit/Transcription/ASRModel.swift` (the `ASRModel.catalog` array). The default is `ASRModel.parakeetV3Id`.

## Architecture

### Overview

```
MicrophoneInputManager (AVAudioEngine, 16 kHz)
        ↓ AVAudioPCMBuffer (accumulation)
        ↓ [Recording complete]
TranscriptionManager.appendAudioToCurrentASR / transcribeWithCurrentBackend
        ↓ switch on TranscriptionConfig.backend
        ├── ParakeetCoreMLASRService → ParakeetCoreMLEngine (CoreML)
        ├── WhisperCoreMLASRService  → WhisperCoreMLEngine (WhisperKit)
        ├── MoonshineASRService      → MoonshineEngine (MoonshineVoice / ONNX)
        ├── MLXASRService            → MLXASREngine (Qwen3/Granite adapters, MLX)
        └── FluidAudioASRService     → FluidAudio (legacy, hidden)
        ↓ [NbestHypothesis], language?, vadSuppressed
TranscriptionCleanupPipeline (Smart Formatting, Swift-side)
        ↓
TranscriptionState → UI insertion
```

Each per-backend ASR service is a `@MainActor ObservableObject` with a uniform surface (`appendAudio`, `accumulatedSamples`, `accumulatedDuration`, `reset`, `transcribe`, `markAsReady`). The shared linear-resampling helper `AudioResampling.linear(...)` is used by Parakeet, Whisper, Moonshine and Qwen3 services. **No protocol is extracted yet** - duplication is acknowledged as a follow-up.

**Mode: Batch (not streaming).** Audio is accumulated for the duration of the shortcut press, then transcribed in one shot when the user releases. More accurate and predictable than streaming.

### Single source of truth for the active model

`TranscriptionConfig.selectedASRModelId` is the **only** writable knob. `backend` is computed from it, and `Defaults[ConfigKeys.backend]` is kept in sync by the `didSet` so legacy warmup-provider reads keep working. The contract is documented inline at the top of `TranscriptionConfig.swift` - never write `Defaults[ConfigKeys.backend]` directly.

### Warmup coordination

`AppModeCoordinator` registers 5 providers with `WarmupCoordinator` at app launch:
- `ParakeetCoreMLWarmupProvider`
- `WhisperCoreMLWarmupProvider`
- `MoonshineWarmupProvider`
- `MLXWarmupProvider`
- `FluidAudioWarmupProvider`
- `SileroVADWarmupProvider` (VAD gate, independent)
- `ScoringWarmupProvider` (Smart Formatting model)

Each provider's `isEnabled` reads `Defaults[ConfigKeys.backend]` to decide whether to warm up. When the user picks a different model, `selectedASRModelId.didSet` calls `WarmupCoordinator.featureStateChanged()` which kicks off the new provider; in parallel, a Combine sink in `TranscriptionManager.setupObservers()` flips `isInitialized=false` so the Model Status pill in Settings reflects the hand-off.

### Download manager

`ASRModelDownloadManager` (`@MainActor`, singleton) tracks per-model install state, progress, and triggers downloads:
- **Parakeet** → `HuggingFaceModelDownloader.downloadParakeetIfNeeded()` (custom HF downloader, multi-file)
- **Whisper** → `WhisperKit.download(variant:progressCallback:)`
- **Moonshine** → `HuggingFaceModelDownloader.downloadMoonshineIfNeeded(modelId:)` against the Moonshine CDN (4 `.ort` files)
- **MLX models (Qwen3-ASR, Granite-Speech)** → `HuggingFaceModelDownloader.downloadMLXModelIfNeeded()` against each model's Hub repo

Cancel/re-download races are guarded by per-model monotonic tokens (`commitIfCurrent(token:modelId:state:)`). `delete(_:)` is `async`: it cancels in-flight tasks, removes the on-disk dir, then awaits the engine `unloadIfCurrent(modelId:)` so the next transcribe never sees a freed file handle.

### Main files

```
Onit/Transcription/
├── ASRModel.swift                          # ASRModel struct + catalog (5 entries)
├── ASRModelDownloadManager.swift           # per-model install state + download/cancel/delete
├── ASRModelsViewModel.swift                # picker UI state (Active/Downloaded/Downloading/Available/Failed)
├── TranscriptionConfig.swift               # selectedASRModelId source of truth, backend computed
├── TranscriptionManager.swift              # batch orchestrator + per-backend dispatch + warmup observation
├── TranscriptionState.swift                # UI state
├── TranscriptionHistory.swift              # GRDB history
├── NbestHypothesis.swift                   # hypothesis model
└── Services/
    ├── MicrophoneInputManager.swift        # mic capture (resampled to 16 kHz)
    ├── AudioResampling.swift               # shared linear resampler
    ├── ParakeetCoreMLEngine.swift          # custom CoreML engine for Parakeet TDT
    ├── ParakeetCoreMLASRService.swift      # service wrapping ParakeetCoreMLEngine
    ├── WhisperCoreMLEngine.swift           # WhisperKit wrapper (actor)
    ├── WhisperCoreMLASRService.swift
    ├── MoonshineEngine.swift               # MoonshineVoice.Transcriber wrapper (actor)
    ├── MoonshineASRService.swift
    ├── MLXASREngine.swift                  # unified MLX engine + Qwen3/Granite adapters (actor)
    ├── Qwen3ASRService.swift
    ├── FluidAudioASRService.swift          # legacy backend (hidden from UI)
    ├── WhisperLanguageDetector.swift       # auxiliary multi-language detector
    └── WhisperKit+Sendable.swift           # retroactive Sendable conformance

Onit/PythonServer/Warmup/
├── ParakeetCoreMLWarmupProvider.swift
├── WhisperCoreMLWarmupProvider.swift
├── MoonshineWarmupProvider.swift
├── MLXWarmupProvider.swift
├── FluidAudioWarmupProvider.swift
└── SileroVADWarmupProvider.swift

Onit/Settings/Pages/
├── SettingsTranscriptionBehavior.swift     # Settings page (Pop-Up + sheet trigger)
└── SettingsASRModelsPickerSheet.swift      # "Local AI Models" sheet (5 cards)
```

### Processing flow

1. User holds the transcription shortcut (hold-to-record) or hits the hands-free toggle.
2. Audio is captured by `MicrophoneInputManager` and accumulated in the active backend's ASR service buffer (`appendAudioToCurrentASR`).
3. User releases the shortcut → recording stops.
4. `TranscriptionManager.transcribeWithCurrentBackend()` dispatches to the matching service (`[asr-dispatch]` log line names the active model).
5. The service runs inference (CoreML / WhisperKit / ONNX / MLX) and returns `([NbestHypothesis], language, vadSuppressed)`.
6. If Smart Formatting is enabled, `TranscriptionCleanupPipeline` cleans the text (Swift-side).
7. Text is inserted at the cursor (RELEASE mode) or shown in the overlay (DEBUG mode).
8. The user can correct the result in the overlay; corrections feed the dataset pipeline below.

### Audio file transcription

The "Transcribe an audio file" card on the Transcripts page (`FileTranscriptionCard`) runs a batch job owned by `FileTranscriptionService`:

1. `AudioResampling.decodeFile(at:)` decodes wav / m4a / mp3 / aiff / caf / flac to 16 kHz mono float32 (chunked read, channels mixed down). Files over 30 min are refused.
2. `TranscriptionManager.transcribeInSegments(_:)` cuts the clip with `StreamingSegmenter` and calls the active backend's `reTranscribe` once per segment, then `TranscriptStitcher` assembles the text. Offline tuning: segments of at least 8 s, cut at the first 0.2 s pause, hard cap 12 s. The live 0.6 s threshold turned every cut of fluent speech into a mid-word cut.
3. `cleanUpOffline` runs Smart Formatting, the same code as `reTranscribe`. Nothing is inserted or copied.
4. The row is saved with `TranscriptionHistory.sourceFilename` (nil for dictations). File rows stay out of lifetime stats, "last transcription" features and the correction backtest.

The ASR prompt gets the user's dictionary only (no screen terms, no term memory). A live dictation stays possible during a job: `ASREngineGate` serializes every inference (dictation, file segments, re-transcription, keep-alive ping, backtest), so a dictation waits at most for the segment in flight. `TranscriptionManager.isTranscribingOffline` keeps the ASR, cleanup and keep-alive lifecycles from unloading or pinging models under the job.

## Configuration

### User-visible Defaults

| Key | Type | Default | Description |
|---|---|---|---|
| `Defaults.Keys.TranscriptionConfigKeys.selectedASRModelId` | String | `"parakeet-v3"` | User-facing ASR model id (one of `ASRModel.catalog`) |
| `Defaults.Keys.TranscriptionConfigKeys.backend` | `TranscriptionBackend` | `.parakeetCoreML` | Mirror of `selectedASRModel.backend`; **read by warmup providers, do not write directly** |
| `Defaults.Keys.transcriptionEnabled` | Bool | true | Master switch for the transcription feature |
| `Defaults.Keys.TranscriptionConfigKeys.smartFormattingEnabled` | Bool | true | Enable Swift-side cleanup pipeline |

Per-backend warmup-completed flags (analytics only, distinguishes first-time downloads from reloads):
- `parakeetWarmupCompletedOnce`
- `whisperWarmupCompletedOnce`
- `moonshineWarmupCompletedOnce`
- `qwen3WarmupCompletedOnce`

### Enable / switch backend

1. **Settings → Advanced Settings → AI Model** - Pop-Up Button shows currently downloaded models + "Browse all models…".
2. "Browse all models…" opens the **Local AI Models** sheet - Download, Use, or Delete any of the 5 entries.
3. The transcription model is hot-swappable: switching to an already-downloaded backend takes effect on the next dictation; switching to a not-yet-downloaded backend opens the sheet so the user can trigger the download.

## SPM dependencies introduced

This feature adds two SPM packages on top of the existing `WhisperKit` and `FluidAudio`:

| Package | Version | License | Product used | Purpose |
|---|---|---|---|---|
| `libs/speech-swift-vendored` (submodule on `synth-inc/speech-swift-vendored`) | vendored from `soniqo/speech-swift@0.0.15` | Apache-2.0 | `Qwen3ASR` | Qwen3-ASR MLX inference |
| `github.com/moonshine-ai/moonshine-swift` | `0.0.61` (exact) | MIT (English models) | `MoonshineVoice` | Moonshine ONNX inference |

`moonshine-swift` is a remote SPM pin in `Package.resolved`. `speech-swift` is vendored as a local SPM package under `libs/speech-swift-vendored` so `MACOSX_DEPLOYMENT_TARGET` can stay at `14.0` (Sonoma support): upstream declares `.macOS("15.0")`, but the Qwen3-ASR MLX path actually runs on macOS 14 - the vendor lowers the platform requirement and gates the CoreML stateful-inference path (`CoreMLTextDecoder`, `CoreMLASRModel`, which use the macOS 15-only `MLState` API) behind `@available(macOS 15, iOS 18, *)`.

## Performance (rough)

| Operation | Duration (M1+) |
|---|---|
| Parakeet v3 transcribe (3–5 s audio) | 0.1–0.5 s |
| Whisper Medium transcribe (3–5 s) | 0.5–1.5 s |
| Qwen3-ASR 0.6B transcribe (3–5 s) | 0.3–1 s |
| Moonshine Base transcribe (3–5 s) | 0.05–0.2 s (the speed/latency king) |
| Smart Formatting | 0.3–0.8 s |

Memory footprint depends on the loaded model (700 MB – 1.5 GB resident).

## Debugging

Console filters (Apple unified logging):

| Filter | What you see |
|---|---|
| `[asr-dispatch]` | Single line per transcription: `model="…" id=… backend=…`. Best filter to answer "which model just transcribed?" |
| `[fileTranscription]` | Audio file job: START, cleanup, DONE (duration, characters), CANCELLED or FAILED with the underlying error |
| `TranscriptionConfig: selectedASRModelId` | Backend switches (id, new backend) |
| `TranscriptionManager [sink-asr-switch]` | Sink-side restart of warmup observation after a switch |
| `TranscriptionManager [init-backend]` | Per-backend init path + alreadyWarm flag |
| `WhisperCoreMLEngine`, `MoonshineEngine`, `MLXASREngine`, `ParakeetCoreMLEngine` | Per-engine load / inference logs |
| `ASRModelDownloadManager` | Download start / progress (per 10 % bucket) / completion / failure |
| `WhisperCoreMLASRService`, `MoonshineASRService`, … | Per-service transcribe timing |

## Safety / fallback

- **Transcribe timeout** in the warmup observation loop: 60 s for CoreML warmup, 30 min download budget.
- **Engine throws** are surfaced through `TranscriptionManager.errorMessage` and `WarmupCoordinator.failedProviders`; the Settings Model Status pill renders the error.
- **Delete-then-transcribe** is safe: `ASRModelDownloadManager.delete(_:)` awaits `unloadIfCurrent(modelId:)` on the matching engine before returning, so the next transcribe never references a freed `.mlmodelc` / `.ort` / `.safetensors`.
- **VAD gate**: Silero VAD suppresses short accidental clicks for every backend (`SileroVADWarmupProvider.isEnabled` covers all 5).

## Known limitations

- First load of any backend is slow (download + CoreML/MLX compile).
- WhisperKit auto-downloads silently inside `ensureLoaded` if the user circumvents the picker (e.g. trashes the model dir between sessions) - no progress UI in that path. Tracked as a follow-up.
- The picker shows up to 5 models; adding more requires implementing a new engine + service + warmup provider per backend.
- Batch mode only - no streaming intermediate results.
- In DEBUG mode, text is pasted only when closing the overlay.

## Corrections Collection

When the user validates a correction (dictation overlay or Transcripts review modal), `TranscriptionCorrectionManager.shared.saveCorrection(...)` persists the case:

1. **Local store** (always): writes a row in `~/Library/Application Support/Onit/transcription_corrections.sqlite` and dumps the audio as PCM 16-bit WAV in `~/Library/Application Support/Onit/transcription_audio/correction_<timestamp>.wav`.
2. **Firebase upload** (gated by the contribution opt-in, see below): `TranscriptionCorrectionFirebaseUploader.shared.upload(correctionId:)` mirrors the case to:
   - **Firestore**: `users/{accountId}/corrections/{correctionId}` with the raw, cleaned and corrected text, app context, schema version, etc.
   - **Storage**: `users/{accountId}/corrections/{correctionId}/raw.wav`

The uploader is implemented as an `actor`: concurrent calls (e.g. a fresh `saveCorrection` racing with the post-sign-in `retryPending()`) are serialized so each row only gets one `cloudCorrectionId` minted.

The Storage upload and the Firestore write are tracked independently (`audioUploadedAt` / `firestoreUploadedAt` columns). A partial failure leaves the row in a state that `retryPending()` resumes on the next successful sign-in. Local edits clear `firestoreUploadedAt` so the doc is re-pushed; `everUploadedAt` records the first successful end-to-end upload and is never cleared, so a re-upload after a local edit doesn't double-count toward the contributions counter.

### Contribution opt-in

User-facing state lives in `Defaults[.transcriptionContribution]` (a `TranscriptionContribution` struct):
- `status: notContributing | contributing` - opt-out is the default
- `nuxFirstSeen: Bool` - flips on the first NUX user choice
- `savesSinceLastNUX: Int` - counts saves while still opt-out; the NUX re-surfaces every 10

The lifetime per-account count of successful uploads is stored separately in `Defaults[.transcriptionContributionsByAccount]` (`[String: Int]`, keyed by Firebase UID). Splitting the two keys lets the uploader actor bump the counter without racing main-actor writes to the NUX state.

Each correction row carries its own upload-eligibility flag in `excludedReason` (text column, nullable):
- `nil` - eligible, will be uploaded if `status == .contributing` and the user is signed into Firebase
- `noEdit` - Mark as correct / no real change, never uploaded
- `paused` - saved while a pause flag (per-transcript or per-session) was active in the review modal, never uploaded
- `optOut` - saved while `status == .notContributing`; can be flipped back to `nil` only via the NUX "Contribute N existing corrections" checkbox flow

`savedByAccountId` captures the Firebase UID at save time so the NUX retro-upload only un-excludes rows that belong to the currently signed-in user (or were saved offline with no account).

### Pause levels

The Transcripts review modal (`TranscriptReviewModal`) hosts two transient pause flags that are NOT persisted:
- `pausedForCurrentTranscript` - auto-resumes on transcript change
- `pausedForSession` - resets at the next modal opening

A correction saved while either flag is active is stamped with `excludedReason = "paused"` so it stays permanently excluded from upload, even after the flag resets. "Turn off completely" from the pause menu flips `status` back to `notContributing` and resets `savesSinceLastNUX` so the NUX surfaces again 10 saves later.

### NUX (permission modal)

`ContributionPermissionModal` is shown over the review modal when:
- The user makes their first save while `nuxFirstSeen == false`, OR
- `savesSinceLastNUX >= 10` while still opt-out, OR
- The user clicks "Start" in the contribution footer

The "Contribute N existing corrections" checkbox is rendered only when there are `optOut` rows owned by the current account. Accept-with-checkbox calls `promoteOptOutToEligible(forAccountId:)` to flip those rows back to `excludedReason = nil`, then triggers `retryPending()` to upload them. A dismiss without choice (X / outside click) makes the NUX re-surface on the next save until the user explicitly picks Accept or Keep local.

### Firebase Auth bridge

`FirebaseAuthService` exchanges the backend session token for a Firebase custom token, then signs in with `Auth.auth().signIn(withCustomToken:)`. The resulting Firebase UID equals the onit `accountId` (as a string), so Security Rules can simply check `request.auth.uid == accountId`.

`AuthManager` calls `signIn()` after each login (Apple/Google/magic-link) and after `restoreSession()`. `signOut()` is called from `AuthManager.logout()`.

### Privacy posture

The corrections pipeline is **pseudonymized**, not anonymous - the consent
copy must reflect that:

- Audio carries a biometric signature (the user's voice). Two recordings
  from the same speaker remain linkable even with all other metadata
  stripped.
- Storage paths and Firestore docs are keyed on the Firebase UID, which
  equals the onit account id.
- We do NOT upload `precedingText` / `followingText` (surrounding text
  from the user's target app - could be passwords, private messages,
  etc.). They live on the device for the dedup pipeline and are also
  excluded from the local "Export to ZIP" path for the same reason.

## Known Limitations

- First load is slow (model loading)
- Parakeet CoreML backend requires Python server running (launched by app)
- Batch mode: no streaming intermediate results
- In DEBUG mode, text is pasted only when closing the overlay
- Correction uploads have no offline retry queue - failures are logged and the local copy is preserved
