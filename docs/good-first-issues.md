# Good first issues

These are small, well-scoped tasks that each touch one area of the app. All
of them are real gaps in the current code. Before you start, comment on the
matching GitHub issue (or open one) so nobody else duplicates the work.
Then follow [CONTRIBUTING.md](../CONTRIBUTING.md).

## 1. Fill in missing French translations

**Area:** localization · **Skills:** French, Xcode string catalogs

The app ships in English and French. Most catalogs are complete, but
`macos/Onit/App.xcstrings` has about 44 strings with no French translation
(for example "Cloudless is free & local", "Leaderboard", "Comment
guidelines"), and `macos/Onit/MenuBar.xcstrings` is missing "Last
Transcript".

- Open the catalogs in Xcode and filter for strings that aren't translated
  into French.
- Skip strings marked *stale* or *Don't translate*.
- Build and run with the scheme's app language set to French to check that
  the text fits the layout.

**Done when:** every active string in both catalogs has a French
translation.

## 2. Show a specific alert when the selected microphone is missing

**Area:** audio input / hints · **Skills:** Swift, SwiftUI

`MicrophoneInputManager.setInputDevice(_:)`
(`macos/Onit/Transcription/Services/MicrophoneInputManager.swift`) sets
`MicrophoneError.inputAudioDeviceNotFound` when the requested device isn't
connected. It then reuses the generic `.inputDeviceFailed` hint, and a
`TODO` there notes that it should get its own case.

- Add a new case to the transcription alert enum in
  `macos/Onit/Hint/HintManager.swift`, next to `inputDeviceFailed`, with
  copy along the lines of "Your selected microphone isn't connected".
- Handle it in `macos/Onit/Hint/HintManager+Transcription.swift`.
- Use it in `setInputDevice(_:)`.
- Add the English and French strings.

**Done when:** selecting a microphone that has just been unplugged shows
the new alert, and the generic alert is still used everywhere else.

## 3. Align the test target's build settings with the app

**Area:** project configuration · **Skills:** Xcode build settings

In `macos/Onit.xcodeproj`, the `OnitTests` target uses
`MACOSX_DEPLOYMENT_TARGET = 15.2` and `SWIFT_VERSION = 5.0`, while the app
target uses `14.0` and `6.0`. As a result, tests can't run on macOS 14,
which the app still supports, and the tests compile under different
concurrency rules than the code they test.

- Lower the test target's deployment target to 14.0. Fix or gate
  (`if #available` or `@available`) any test that relies on a macOS 15 API.
- Try Swift 6 for the test target. If that causes a large number of
  concurrency errors, keep Swift 5. Document what you found in the pull
  request; that's a useful result too.

**Done when:** the test suite builds and passes with a 14.0 deployment
target. Either it uses Swift 6, or the pull request explains why it
doesn't yet.

## 4. Restore manual scrolling in the community carousel

**Area:** UI · **Skills:** SwiftUI scroll APIs

`CuratedSocialsCarousel`
(`macos/Onit/App/Components/CuratedSocialsCarousel.swift`) disables
scrolling with `.scrollDisabled(true)`. Cards only move with the chevron buttons or by clicking a card,
because free scrolling left cards stuck between positions.

- Re-enable scrolling, and make cards snap to the center, for example with
  `.scrollTargetBehavior(.viewAligned)` and `.scrollTargetLayout()`
  (macOS 14+).
- Keep `scrollPosition(id:)` bound to `centeredPostId` so the chevrons,
  card clicks and the "load more" logic keep working.

**Done when:** you can trackpad-scroll the carousel, it always settles on
a centered card, and the chevron buttons still work.
