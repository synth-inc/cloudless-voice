<div align="center">
<a href="https://www.cloudless.so">
<img src="macos/Onit/Assets.xcassets/AppIcon.appiconset/onit_appicon_256.png" alt="Cloudless Voice icon" width="128" height="128">
</a>

# Cloudless Voice

**Cloudless Voice: local, private dictation for Mac. An open-source alternative to Wispr Flow.**

[Website](https://www.cloudless.so) · [Download](https://www.cloudless.so) · [Privacy](PRIVACY.md) · [Contributing](CONTRIBUTING.md) · [License](LICENSE)


Formerly Onit Dictate

</div>

Press a shortcut (default ⌥Space), speak, and your words are typed into
whatever app you're using. Speech recognition runs entirely on your Mac.

## Why it's different

- **On-device.** Speech recognition runs locally; your audio is never
  sent anywhere to be transcribed. Choose the model that fits your Mac: Parakeet v3,
  Whisper Large Turbo v3, Whisper Medium, Moonshine Base or Qwen3-ASR.
- **Pin your speech model.** Cloud dictation services can change their
  model under you overnight. With Cloudless Voice, the model only changes
  when you change it.
- **Backtest new models against your own words.** Before you switch, check
  a new model against your own corrected transcripts, so you see how it
  handles your voice, accent and vocabulary instead of trusting someone
  else's benchmark.
- **Free, unlimited dictation** in every build, with no account required.

Also included:

- **Dictate anywhere.** Works in any text field of any app, with a
  customizable global shortcut.
- **Smart formatting.** Cleans up punctuation, capitalization, numbers and
  spoken self-corrections.
- **Custom dictionary.** Teach it names, jargon and acronyms.
- **Transcript history and stats.** Review, search and correct past
  dictations.
- **Floating overlay.** Live audio visualization while you speak. You can
  cancel at any time.

## Get Cloudless Voice

### Download the official app

The easiest way. It's signed, notarized, updates itself, and includes Smart
Cleanup.

- Download from [cloudless.so](https://www.cloudless.so).

### Build from source

Requirements:

- macOS 14.0 (Sonoma) or later
- Xcode 26.6 or later (Swift 6 language mode). The prebuilt Smart Cleanup library in
  `libs/transcription-cleanup-swift` was built with Xcode 26.6, and a compiler older than the one
  that built a framework cannot read it. The fully open build (below) has no such limit and
  builds with any Xcode 26.
- The Metal Toolchain. Xcode 26 no longer bundles the `metal` compiler and
  the MLX dependency fails to build without it. Install it once per machine
  with `xcodebuild -downloadComponent MetalToolchain` (a download of about
  690 MB; CI does the same in `.github/workflows/build.yml`)
- An Apple Silicon Mac is recommended

```bash
git clone --recursive https://github.com/synth-inc/cloudless-voice.git
cd cloudless-voice
./.githooks/install.sh        # required once per clone; the build checks for it
open macos/Onit.xcodeproj
```

Then build and run the `Onit` scheme. A plain checkout has no signing team,
so it does not build as signed until you give it one. Either put your own
`DEVELOPMENT_TEAM` in `macos/Config/Local.xcconfig` (see
[CONTRIBUTING.md](CONTRIBUTING.md#build-identity-signing-updates-analytics)),
or, for a build you will not run with sign-in, build from the command line
without signing by adding `CODE_SIGNING_ALLOWED=NO` to the `xcodebuild`
command (this is what `scripts/ci-test.sh` does).

On first launch the app downloads the default speech model. Per the model
catalog (`macos/Onit/Transcription/ASRModel.swift`) that is Parakeet v3,
about 700 MB, or Qwen3-ASR 1.7B (4-bit), about 1.6 GB, on Macs with 32 GB
of memory or more. Speech recognition does not work until it finishes.

**Smart Cleanup in your own build.** A build that isn't signed with an
Apple Developer team gets no free Smart Cleanup allowance: Smart Cleanup
needs a subscription there, and the app tells you so. Dictation and BYOK
cleanup are free in every build.

To build with **no closed-source code at all**, the recommended way is:

```bash
./scripts/build-fully-open.sh --build     # swap in the open stub and build (unsigned, Debug)
./scripts/build-fully-open.sh --restore   # switch back to the official build
```

The script replaces the closed Smart Cleanup library with an empty stub, so
the app compiles without it. `--build` builds in its own DerivedData
(`.build/fully-open`). If you only run the swap (`./scripts/build-fully-open.sh`
without `--build`) and then build in Xcode, use a clean DerivedData: Xcode's
default one may still hold the closed module from an earlier official
build, and that compiles Smart Cleanup back in. A fully open build uses its
own bundle ID (`inc.synth.Onit.dev.open`), so it keeps its settings apart
from the official development build.

See [CONTRIBUTING.md](CONTRIBUTING.md) for command-line builds, tests and
troubleshooting.

## What's open and what's not

| Part | License | Cost |
| --- | --- | --- |
| The app: dictation, on-device speech recognition, UI, dictionary, history | Open source, [GPL-3.0-or-later](LICENSE) | Free. Dictation is unlimited in every build. |
| **BYOK cleanup**: bring your own model or API key (OpenAI, Anthropic, OpenRouter, Ollama, LM Studio, …) | Open source, part of the app | Free. You pay your provider directly, if anything. |
| **Smart Cleanup**: our on-device transcript cleanup model, in `libs/transcription-cleanup-swift` | **Closed source**, shipped as a prebuilt binary under its [own license](libs/transcription-cleanup-swift/LICENSE) | Paid, with a free monthly allowance. See [pricing](https://www.cloudless.so/pricing). |

- The Smart Cleanup binary is **bundled in this repository**, so official
  builds and forks can include it unmodified. Its usage is metered inside
  the binary. Forks can offer Smart Cleanup to users who have a Cloudless
  account.
- The app's license includes
  [additional permissions](LICENSE-EXCEPTION) that let GPL code be
  combined with the Smart Cleanup library and with OpenSSL-derived code
  (BoringSSL, which ships inside a Firebase dependency).
- `scripts/build-fully-open.sh` builds the app **without** Smart Cleanup or
  any other closed code. Everything else, including BYOK cleanup, still
  works.

## Privacy

Speech recognition runs on your Mac, and audio is never sent anywhere to be
transcribed. Audio and transcript text leave your Mac only when you choose
to send them: to the cloud provider you set up for BYOK cleanup (text
only, straight to that provider), or, in the official app, to us when you
click **Request fix** on a transcript. Smart Cleanup only sends your
sign-in token to check your subscription. It never sends your transcripts.

The official app also sends crash reports and usage analytics (which you
can turn off) and checks for updates; builds from source send no crash
reports, no analytics and make no update check.

A build from source still talks to Synth's server in two ways. On every
launch it sends an install ping, an empty `PATCH /v1/referral/journey/installed`
with no token and no body, which the server may match to a visit to our
website by IP address. And if you sign in, it contacts the server for
sign-in, your account and subscription, and the community feed. It also
downloads models from Hugging Face and, for Moonshine, from
`download.moonshine.ai`. [PRIVACY.md](PRIVACY.md) lists every network
request the app makes.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) to get
started, and look at [docs/good-first-issues.md](docs/good-first-issues.md)
for starter tasks. Contributions are accepted under the project's own
license; see [Licensing of contributions](CONTRIBUTING.md#licensing-of-contributions).
Please report security issues privately as
described in [SECURITY.md](SECURITY.md).

### Repository layout

- `macos/`: the macOS app (Swift / SwiftUI). Architecture docs are linked
  from [CONTRIBUTING.md](CONTRIBUTING.md#architecture-docs).
- `libs/transcription-cleanup-swift/`: the closed Smart Cleanup library,
  shipped as a prebuilt XCFramework.
- `libs/speech-swift-vendored/`: a vendored Apache-2.0 fork
  ([synth-inc/speech-swift-vendored](https://github.com/synth-inc/speech-swift-vendored))
  that provides Qwen3-ASR support.
- `scripts/`: build and maintenance scripts.

## License

Cloudless Voice is licensed under the [GNU General Public License v3.0 or
later](LICENSE), with [additional permissions](LICENSE-EXCEPTION) for
combining it with the Cloudless Smart Cleanup library and with OpenSSL
(including BoringSSL).

`SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception`

The Smart Cleanup library has [its own license](libs/transcription-cleanup-swift/LICENSE).
Third-party components keep their own licenses; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Trademarks

"Cloudless", "Cloudless Voice" and the app icon are trademarks of Synth,
Inc. Forks are welcome, but they need their own name and icon. See
[TRADEMARKS.md](TRADEMARKS.md).

© 2024-2026 Synthetic Exploration, Inc.
