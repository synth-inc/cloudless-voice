# Contributing to Cloudless Voice

Thanks for helping make local, private dictation better. This guide covers
building the app, running the tests, and getting a pull request merged.

New here? [docs/good-first-issues.md](docs/good-first-issues.md) lists a few
well-scoped starter tasks.

## Ground rules

- Be kind. Assume good intent, review the code and not the person.
- Report security issues privately. See [SECURITY.md](SECURITY.md). Don't
  open public issues for them.
- Contributions are licensed under the project's own license (see
  [Licensing of contributions](#licensing-of-contributions)).

## Building

### Requirements

- macOS 14.0 (Sonoma) or later. This is the app's deployment target.
- Xcode 26.6 or later for the official build, which links the prebuilt Smart Cleanup
  library (a compiler older than the one that built a framework cannot read it). The fully
  open build works with any Xcode 26. The app target uses the Swift 6 language mode.
- The Metal Toolchain. Xcode 26 no longer bundles the `metal` compiler, and
  the MLX dependency (`mlx-swift_Cmlx`) fails to build without it. Install it
  once per machine with `xcodebuild -downloadComponent MetalToolchain`
  (a download of about 690 MB; CI does the same in
  `.github/workflows/build.yml`).
- An Apple Silicon Mac is recommended.
- Free disk space for the default speech model, which is downloaded on first
  launch: about 700 MB for Parakeet v3, or about 1.6 GB for Qwen3-ASR 1.7B
  (4-bit), which is the default on Macs with 32 GB of memory or more (sizes
  from the catalog in `macos/Onit/Transcription/ASRModel.swift`).

### Official build (with Smart Cleanup)

This is the configuration we ship. It links the closed, prebuilt Smart
Cleanup library in `libs/transcription-cleanup-swift`, which is included in
the repository.

```bash
git clone --recursive https://github.com/synth-inc/cloudless-voice.git
cd cloudless-voice
./.githooks/install.sh        # once per clone; the build checks for it
open macos/Onit.xcodeproj
```

Then build and run the `Onit` scheme.

- **`install.sh` is required.** A build phase fails if the git hooks are
  not configured. The hooks keep submodules and the SwiftPM cache healthy
  when you switch branches.
- **Signing.** A plain checkout has no signing team (see
  [Build identity](#build-identity-signing-updates-analytics)). Set your
  own in `macos/Config/Local.xcconfig`. Signing is not needed for sign-in:
  the session token is kept in an encrypted file in Application Support
  (`TokenManager`), not in the keychain. It only matters for BYOK API keys:
  they go in the data-protection keychain, which needs a signing
  entitlement, and an unsigned build (`CODE_SIGNING_ALLOWED=NO`) falls back
  to the login keychain (`APIKeyStore`).
- **Smart Cleanup needs a subscription in builds that aren't signed with
  an Apple Developer team.** Those builds get no free Smart Cleanup
  allowance, and the app shows this. Dictation and BYOK cleanup work for
  free in every build, so you can develop and test everything else without
  an account.
- **Command-line builds** need `-skipMacroValidation`. Without it, SwiftPM's
  macro trust prompt fails non-interactively on every fresh clone. A plain
  checkout also has no signing team, so a build with no `Local.xcconfig` needs
  `CODE_SIGNING_ALLOWED=NO` (the way `scripts/ci-test.sh` builds), or your own
  `DEVELOPMENT_TEAM` in `macos/Config/Local.xcconfig`:

  ```bash
  xcodebuild -project macos/Onit.xcodeproj -scheme Onit \
    -configuration Debug -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO build
  ```

  Leave out `CODE_SIGNING_ALLOWED=NO` once `Local.xcconfig` sets a team. An
  unsigned app is for building and testing only, not for running day to day
  (see Signing above).

### Build identity (signing, updates, analytics)

Who builds the app is configured in
[macos/Config/Base.xcconfig](macos/Config/Base.xcconfig), not in the project
file. A plain checkout builds with no signing team, the `inc.synth.Onit.dev`
bundle ID, no Sparkle update feed (the updater never starts), no analytics
(PostHog is not set up) and no Firebase: `GoogleService-Info.plist` is not in
the repository, so Crashlytics and transcript-correction uploads ("Request
fix") are off and that UI is hidden.

A build from source is not fully silent: it still sends the install ping
(an empty `PATCH /v1/referral/journey/installed` at every launch, no token)
to Synth's server, downloads models from Hugging Face, and contacts the
server for sign-in and the community feed if you sign in. See
[PRIVACY.md](PRIVACY.md).

- **Run it locally:** create `macos/Config/Local.xcconfig` (gitignored) with
  your own `DEVELOPMENT_TEAM` (and optionally `PRODUCT_BUNDLE_IDENTIFIER`),
  or build with `CODE_SIGNING_ALLOWED=NO`. The keychain access group in
  `macos/Onit/Onit.entitlements` follows your team and bundle ID
  (`$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`), so it needs no
  changes.
- **Official builds:** Synth's release overlay is included from
  `release/Official.xcconfig` at the repository root (gitignored). Synth's
  private release wrapper links it in with its `scripts/link_overlay.sh`,
  which makes `release/` a symlink to the overlay. The overlay supplies the
  team, the release bundle ID, the update feed, the analytics keys and
  `GoogleService-Info.plist` (copied into the bundle by the Crashlytics build
  phase). Signing, notarization and publishing live outside this repository.
- **Precedence**, lowest to highest: `Base.xcconfig`, the fully open build's
  `FullyOpen.xcconfig` (only while its stub is swapped in, see below),
  `Local.xcconfig`, then the release overlay.

### Fully open build (no closed code)

`scripts/build-fully-open.sh` builds the app without the Smart Cleanup
library or any other closed-source code. You get dictation and BYOK cleanup
(bring your own model or API key). Smart Cleanup is not available. If your
change doesn't touch Smart Cleanup, it should work in both builds.

```bash
./scripts/build-fully-open.sh --build     # swap in the stub, build (Debug, unsigned)
./scripts/build-fully-open.sh --status    # which build this checkout is set up for
./scripts/build-fully-open.sh --restore   # put the closed library back
```

- **How it works.** The script replaces the local package in
  `libs/transcription-cleanup-swift` with an empty stub (from
  `scripts/fully-open/`) and deletes the closed binary. Everything that
  needs Smart Cleanup is behind `#if canImport(TranscriptionCleanup)`.
  Running it without a flag only swaps; `--build` also builds.
- **Use a separate DerivedData.** `--build` builds in `.build/fully-open`.
  A DerivedData that built the official app (such as Xcode's default one)
  still holds the closed `TranscriptionCleanup` module, and `canImport`
  would find it and compile Smart Cleanup back in. If you build in Xcode
  after a plain swap, clean the build folder first.
- **Separate bundle ID.** While the stub is swapped in, the app is built as
  `inc.synth.Onit.dev.open`, so it doesn't share settings with the official
  development build.
- **Don't commit the stubbed state.** Run `--restore` first. The pre-commit
  hook (installed by `.githooks/install.sh`) refuses a commit while the stub
  is in place.

## Tests

Unit tests live in `macos/OnitTests`. Run them the way CI does:

```bash
scripts/ci-test.sh build   # build the app and tests (unsigned, Debug)
scripts/ci-test.sh test    # run the default test plan
```

The default `Onit` plan skips tests that need downloaded models, local data or
hardware a clean checkout doesn't have, or that touch files outside the test
sandbox; `macos/skipped-tests.txt`
gives the reason for each, and `scripts/check-ci-testplan.py` checks the
list. For the fully open build, run `scripts/build-fully-open.sh` first and
`--restore` afterwards; `ci-test.sh` uses a separate DerivedData for each.

In Xcode, ⌘U runs the `Onit` plan, but Xcode (like `xcodebuild`) ignores the
plan's skip list for Swift Testing tests, so run through `scripts/ci-test.sh`
when you want the clean-checkout result. To run one test class from the
command line, add
`-only-testing:OnitTests/<ClassName>`.

Tests that need speech models or local data must skip themselves when those
are missing, never fail. A test that
fails on a clean `main` is not a regression from your change; mention it
in your pull request.

## Pull requests

1. **Open an issue first** for anything bigger than a small fix, so we can
   agree on the approach before you write it.
2. **Branch** from `main`. Keep each pull request to one topic.
3. **Write tests** for logic changes where practical, especially in
   transcription, formatting and dictionary code.
4. **Check both builds** if you touch anything near Smart Cleanup or the
   cleanup pipeline.
5. **Fill in the pull request template**, including the licensing checkbox.
6. **Review.** A maintainer reviews every pull request. We may ask for
   changes, and we squash-merge once it's approved and CI passes.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
(`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`), optionally with
a scope, for example `fix(auth): ...`.

## Code style

- Swift, formatted with 4-space indentation (see `.swift-format` at the
  repository root). Match the style of the file you're editing.
- New Swift files start with the SPDX license header. Run
  `scripts/add-spdx-headers.sh` to add it, or
  `scripts/add-spdx-headers.sh --check` to verify:

  ```swift
  // SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
  ```

- The app target uses Swift 6 with strict concurrency checking. Don't
  silence concurrency warnings with `@unchecked Sendable` or
  `nonisolated(unsafe)` without a comment that explains why it's safe.
- User-facing strings go through the string catalogs (`*.xcstrings` in
  `macos/Onit`). We ship English and French. If you add a string, add the
  French translation too if you can; otherwise say so in the pull request.
- Don't add network calls without discussing them first. Every network
  call is documented in [PRIVACY.md](PRIVACY.md). Audio and transcript text
  must never leave the device unless the user explicitly chose to send them
  (a BYOK cleanup provider, or a transcript fix request).

## Architecture docs

- [macos/TRANSCRIPTION_LLM.md](macos/TRANSCRIPTION_LLM.md): transcription
  and cleanup architecture
- [macos/Onit/Transcription/SETUP.md](macos/Onit/Transcription/SETUP.md):
  transcription feature guide
- [macos/Onit/PERMISSIONS.md](macos/Onit/PERMISSIONS.md): permissions
  (microphone, accessibility, screen recording)
- [macos/Onit/Transcription/Analytics.md](macos/Onit/Transcription/Analytics.md):
  analytics event reference

## Releases

Official releases (the signed, notarized app on cloudless.so, its update
feed and the Homebrew cask) are built and published by Synth's
maintainers from this source code, using private release tooling and
signing credentials. Contributors don't need to do anything for a release.

## Licensing of contributions

There is no contributor agreement to sign. The rule is "inbound =
outbound": by submitting a contribution (a pull request, patch or other
code or documentation you intend for inclusion), you:

- license it under the project's license: the GNU General Public License
  v3.0 or later ([LICENSE](LICENSE)), including both additional
  permissions in [LICENSE-EXCEPTION](LICENSE-EXCEPTION) (combining with
  the Cloudless Smart Cleanup library, and with OpenSSL); and
- confirm that you have the right to submit it under those terms, for
  example because you wrote it, or because your employer allows it.

You keep the copyright to your work.

## License

By contributing, you agree that your contributions are licensed under the
terms in [LICENSE](LICENSE) and [LICENSE-EXCEPTION](LICENSE-EXCEPTION) (see
[Licensing of contributions](#licensing-of-contributions)). The "Cloudless" names
and icon are covered by [TRADEMARKS.md](TRADEMARKS.md), not by the code
license.
