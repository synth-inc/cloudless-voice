# Transcription Analytics Documentation

This document describes the analytics events implemented for the Speech Transcription feature.

## Overview

The Transcription feature tracks user interactions through PostHog analytics to measure adoption, usage patterns, and identify potential issues. All events follow the existing `AnalyticsManager` pattern with common properties included in every event.

## Events Reference

### Feature Lifecycle Events

| Event Name | Description | Properties |
|------------|-------------|------------|
| `transcription_enabled` | User enables the transcription feature | Common properties only |
| `transcription_disabled` | User disables the transcription feature | Common properties only |

**Trigger locations:**
- `AppModeCoordinator.swift` - `startTranscription()` and `stopTranscription()`

---

### Model Initialization Events

| Event Name | Description | Properties |
|------------|-------------|------------|
| `transcription_model_initialization_started` | ASR model download/loading begins | Common properties only |
| `transcription_model_initialization_completed` | ASR model successfully initialized | `duration_ms` |
| `transcription_model_initialization_failed` | ASR model initialization error | `error` |
| `transcription_model_initialization_retry` | User retries after failure | Common properties only |

**Trigger locations:**
- `TranscriptionManager.swift` - `initializeModelsInBackground()`
- `OnboardingTranscriptionWarmup.swift` - `retryInitialization()`

---

### Session Events

| Event Name | Description | Properties |
|------------|-------------|------------|
| `transcription_session_started` | User starts a transcription session | `shortcut_type`, `app_name`, `app_bundle_id` |
| `transcription_session_completed` | Session ends with transcribed text | `shortcut_type`, `duration_ms`, `text_length`, `app_name`, `app_bundle_id` |
| `transcription_session_cancelled` | User cancels without inserting text | `shortcut_type`, `duration_ms`, `app_name`, `app_bundle_id` |
| `transcription_session_failed` | Session fails due to error | `shortcut_type`, `error`, `app_name`, `app_bundle_id` |

**Properties details:**
- `shortcut_type`: `capsLock`, `fn`, or `custom`
- `duration_ms`: Session duration in milliseconds
- `text_length`: Number of characters transcribed
- `app_name`: Target application name (e.g., "Slack", "Notes")
- `app_bundle_id`: Target app bundle identifier

**Trigger locations:**
- `TranscriptionManager.swift` - `startTranscription()`, `stopTranscription()`, `cancelTranscription()`, `performTranscription()`

---

### Settings Events

| Event Name | Description | Properties |
|------------|-------------|------------|
| `transcription_shortcut_type_changed` | User changes the activation shortcut | `old_value`, `new_value` |
| `transcription_settings_opened` | User opens transcription settings | Common properties only |

**Trigger locations:**
- `TranscriptionShortcutConfiguration.swift` - `apply(previousType:)`
- `SettingsTranscriptionBehavior.swift` - `onAppear`

---

### Onboarding Events

| Event Name | Description | Properties |
|------------|-------------|------------|
| `transcription_onboarding_warmup_shown` | Warmup step displayed | Common properties only |
| `transcription_onboarding_warmup_completed` | Model ready, proceeding to demo | Common properties only |
| `transcription_onboarding_warmup_retry` | User retries model initialization | Common properties only |
| `transcription_onboarding_demo_shown` | Demo step displayed | Common properties only |
| `transcription_onboarding_demo_completed` | User finishes setup | `text_length`, `shortcut_type` |
| `transcription_onboarding_demo_reset` | User resets the demo | Common properties only |

**Trigger locations:**
- `OnboardingTranscriptionWarmup.swift`
- `OnboardingTranscriptionDemo.swift`

---

## Common Properties

All events include these properties via `AnalyticsManager.getCommonProperties()`:

| Property | Description |
|----------|-------------|
| `device_model` | Mac model (e.g., "MacBookPro18,2") |
| `cpu_architecture` | CPU info (e.g., "Apple M1 Pro") |
| `screen_count` | Number of connected displays |
| `accessibility_trusted` | Whether app has accessibility permissions |
| `accessibility_highlight_enabled` | Auto-context from highlights setting |
| `accessibility_autocontext_enabled` | Auto-context from window setting |

---

## Implementation Files

| File | Purpose |
|------|---------|
| `Analytics/AnalyticsManager+Transcription.swift` | Event definitions and tracking methods |
| `Transcription/TranscriptionManager.swift` | Session and model events |
| `AppModeCoordinator.swift` | Feature enable/disable events |
| `Transcription/TranscriptionShortcutConfiguration.swift` | Shortcut change events |
| `Onboarding/Pages/OnboardingTranscriptionWarmup.swift` | Warmup onboarding events |
| `Onboarding/Pages/OnboardingTranscriptionDemo.swift` | Demo onboarding events |
| `UI/Settings/Pages/SettingsTranscriptionBehavior.swift` | Settings page events |

---

## Verification Checklist

After deployment, verify events are being captured correctly:

- [ ] Enable Transcription feature → `transcription_enabled` fires
- [ ] Model initialization starts → `model_initialization_started` fires
- [ ] Model ready → `model_initialization_completed` with `duration_ms`
- [ ] Start transcription session → `session_started` with app info
- [ ] Complete session → `session_completed` with duration and text length
- [ ] Cancel session → `session_cancelled` fires
- [ ] Change shortcut type → `shortcut_type_changed` with old/new values
- [ ] Open settings → `settings_opened` fires
- [ ] Complete onboarding → all onboarding events fire in sequence

---

## Changelog

| Date | Author | Changes |
|------|--------|---------|
| 2026-01-15 | Kévin Naudin | Initial implementation of 18 analytics events |
