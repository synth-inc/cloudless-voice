# Privacy in Cloudless Voice

Cloudless Voice is built so that **speech recognition happens on your
Mac**.

- **Speech recognition runs on-device.** Audio is processed locally by the
  speech model you choose. Audio is never sent anywhere to be transcribed.
- **Dictation is free and unlimited in every build**, and it works without
  an account.
- **Audio and transcript text leave your Mac only when you choose to send
  them:** when you ask us to fix a transcript (official app only, see
  [Transcript fix requests](#transcript-fix-requests-official-app-only)),
  or when you turn on Rewrite with your own model (BYOK) and point it at a cloud provider.

This document lists every network request the app makes: when it happens,
what it sends, and whether it includes your audio or transcript text. The
app is open source, so you can check these claims in the code.

This is the privacy policy for Cloudless Voice and for the code in this
repository. The data controller is Synthetic Exploration, Inc. ("Synth",
"we"). Questions, and requests about data we hold about you, go to
contact@cloudless.so.

## Official app vs. builds from source

Some services are only configured in the official app that Synth builds
and signs. Their configuration (Firebase config, analytics key, update
feed) lives in Synth's private release setup, not in this repository.

| Service | Official app | Built from this repository (or a fork) |
| --- | --- | --- |
| Crash reports (Firebase Crashlytics) | Yes | No |
| Transcript fix requests (Firebase upload) | Yes, opt-in | No |
| Usage analytics (PostHog) | Yes, on by default, can be turned off | No |
| Update checks (Sparkle) | Yes | No |
| Sign-in and subscription check (Synth server) | Yes | Yes |
| Model downloads, local-model probe | Yes | Yes |

## Summary

| Data | Leaves your Mac? |
| --- | --- |
| Microphone audio | Never for transcription. In the official app, the audio clip of a transcript is uploaded to Synth only if you click **Request fix** on that transcript and agree to send it. |
| Transcript text | Only to the BYOK Rewrite provider **you** configure (Rewrite is off by default), and (official app) to Synth for a transcript you send with **Request fix**. Never in analytics. |
| Name and bundle ID of the app you dictate into | Official app: in usage analytics (can be turned off), and with a transcript you send with **Request fix**. |
| Account identifier (Firebase user ID) | Official app: with each transcript you send with **Request fix**; it is also part of the storage path. |
| Custom dictionary, snippets, transcript history | No. Analytics events include only counts and lengths, never the words. |
| Email address | To Synth's server when you sign in. Official app: also attached to usage analytics after you sign in. |
| Sign-in token | To Synth's server, to restore your session and check your subscription. |
| Crash reports | Official app only: stack traces and device information, sent automatically. |

## Network requests

Legend for the last column: **No** = neither audio nor transcript text is
included. Hosts in `code font` are the ones the app contacts directly.
"Synth server" is `onit-server-v2-a93590258ea2.herokuapp.com`.

| # | Request | Builds | When | Destination | What is sent | Audio or transcript? |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Speech and cleanup model downloads | All | First launch (default model), and when you pick a model in Settings | `huggingface.co` and its download CDN; `download.moonshine.ai` for Moonshine | Plain file requests (IP address, user agent). No account or token | No |
| 2 | Install ping | All | Every launch, signed in or not (sent from the app delegate at startup) | Synth server, `PATCH /v1/referral/journey/installed` | An empty request with no body and no token. The server may match it to a visit to our website by IP address | No |
| 3 | Sign-in | All | When you sign in, and when the app restores your session at launch | Synth server (`/v1/auth/...`); Google (`accounts.google.com`, `oauth2.googleapis.com`) for *Sign in with Google*; Apple for *Sign in with Apple* | Your email address (for an email sign-in link), or the identity token from Google or Apple. Google sign-in uses the default scopes only (no Drive, Gmail or Calendar access) | No |
| 4 | Account, subscription and Smart Cleanup check | All | At launch and on sign-in while you're signed in; on the Billing page | Synth server (`/v1/auth/account`, `/v1/subscription`, `/v1/lifetime-activation`) | Your sign-in token | No |
| 5 | Firebase sign-in | Official | After every sign-in | Firebase Authentication (Google) | A one-time token issued by the Synth server, so the app can store your fix requests (row 6) under your account | No |
| 6 | Transcript fix request | Official | Only when you click **Request fix** or **Save & request fix** on a transcript. The app first shows what will be sent and asks you to agree | Firebase Storage and Firestore (Google), project `onit-3b9d6` | **The audio clip (WAV)**; the raw, cleaned and corrected transcript text; the name and bundle ID of the app you dictated into; whether a snippet expanded; the time of the dictation; app, build and macOS version; your account's Firebase user ID. Text around the cursor is **not** sent | **Yes**, audio and text, to Synth |
| 7 | Crash reports | Official | Automatically after a crash | Firebase Crashlytics and Firebase Installations (Google) | Stack traces and device information. No transcript text, logs or user ID are attached by the app | No |
| 8 | Usage analytics and feature flags | Official | At launch and on about 170 app and dictation events | PostHog, `us.i.posthog.com` | See [Usage analytics](#usage-analytics-official-app-only) | No (lengths and counts only) |
| 9 | Update checks | Official | At launch and about once a day | Synth server, `/appcast.xml`, then the download host the feed names | App version and macOS version (standard Sparkle request). System profiling is off | No |
| 10 | Local model probe | All | Every launch | `localhost:11434` (Ollama), or the local address you configured | A request listing installed models | No |
| 11 | BYOK Rewrite | All | After each dictation, file transcription and re-transcription, only if you turned on **Rewrite with your own model** (off by default) and chose a cloud provider. Also when you click **Test connection** (a fixed sample sentence) or load the model list | The provider **you** chose (OpenAI, Anthropic, OpenRouter, or a Custom OpenAI-compatible URL), using your API key | The transcript text (after Smart Cleanup, if it is on), the rewrite prompt and the name of the dictation language; your custom dictionary terms and the name of the app you dictate into only if you turn those on (both off by default). Never the text around the cursor. **Never audio** | **Yes**, text, to your chosen provider only |
| 12 | BYOK Rewrite, local model | All | Same as 11, with a local provider (e.g. Ollama) | Your own machine (`localhost`) or the address you configured | Same as 11 | Yes, but it stays on the machine you configured |
| 13 | Community feed | All | Only while you are signed in: nothing is requested when you are signed out. On the Home page the section is shown to signed-in users unless a PostHog feature flag hides it. Builds without PostHog (every build from source) never fetch that flag, so the section is shown to every signed-in user. When it is shown, requests are made when the section appears and when you sign in; clicking the Reddit card on the Support page also loads the feed, whatever the flag says | Synth server (`/v1/curated-social-media-*`) | Your sign-in token, the IDs of posts you open, and the URLs of your own public comments that you paste in | No |
| 14 | Referrals and leaderboard | All | On the Support page, at sign-in, and when you edit your display name or links | Synth server (`/v1/referral/...`) | Your referral code, the display name you choose (shown publicly on the leaderboard), and links you add | No |
| 15 | Subscription purchase and management | All | When you click upgrade or manage subscription | Synth server returns a Stripe page, which opens in your browser | Handled by Stripe in your browser | No |

Links you click (our website, X, YouTube, Discord, Reddit, email) open in
your browser. The app does not send data with them.

## Transcript fix requests (official app only)

When a transcript came out wrong, you can click **Request fix** to send it
to us so we can improve recognition. This is optional.

- **Off by default.** Nothing is sent until you click **Request fix** or
  **Save & request fix** on a specific transcript and agree in the dialog
  that explains what is sent. Corrections you save without requesting a fix,
  including those made in the overlay right after dictating, stay on your
  Mac and are never uploaded later.
- **What is sent:** the audio clip of that dictation (a WAV file), the raw,
  cleaned and corrected transcript text, the name and bundle ID of the app
  you dictated into, whether a snippet expanded, the time of the dictation,
  the app, build and macOS versions, and your account's Firebase user ID.
  The text around your cursor is not sent. This data is identifiable: it is
  linked to your account and the audio contains your voice, so check that a
  transcript holds nothing sensitive before you request a fix.
- **Where it goes:** Google Firebase (Cloud Storage and Firestore, project
  `onit-3b9d6`) under your account, for the Synth team to use to improve
  dictation accuracy.
- **You must be signed in.**
- **Removing it:** deleting a transcript from your history also deletes the
  copy we stored, on a best-effort basis. Each fix request is a separate
  action; if you never click **Request fix** again, nothing more is sent.
- **Older local corrections.** Corrections saved by older builds that were
  never uploaded are marked at the first launch of this version as excluded
  from upload. They leave your Mac only if you click **Request fix** on that
  transcript.

## Usage analytics (official app only)

The official app sends usage events to PostHog to help us find bugs and
improve the app. You can turn this off in *Settings > General*. It is **on
by default**.

What the events contain:

- **The name and bundle ID of the app you dictate into**, on every
  dictation session event (started, completed, cancelled, failed) and on
  saved corrections, plus some accessibility error events;
- **after you sign in, your account ID and email address**: the app calls
  PostHog `identify` with your numeric account ID and sets your email address
  (the email or the Apple-provided email of the account) and an
  employee flag as properties, so every later event is linked to you
  (`AnalyticsManager+Identity.swift`);
- device model, CPU architecture, number of screens, and whether
  accessibility permissions are granted;
- timings, counts and text **lengths**, such as how many characters a
  dictation produced;
- error messages from failed dictations (including microphone errors),
  model downloads and warm-up, sign-in, and cleanup, as written by the
  system or by the libraries involved. Only the two Smart Cleanup error
  events are cut to 500 characters, and some model events replace your
  home-folder user name in file paths. The app's own code does not put
  transcript text in these messages. Messages written by third-party
  libraries and by the closed-source Smart Cleanup library are passed on as
  they are, so in rare cases they could contain a fragment of dictated text;
- feature-flag requests; PostHog derives a coarse location from your IP
  address to evaluate them;
- PostHog's automatic app lifecycle events (installed, updated, opened,
  backgrounded), which the pinned PostHog library (3.38.0) enables by
  default.

The analytics are therefore **not anonymous** once you sign in. Apart from
the error messages above, events do not include your audio, transcript
text, dictionary words, snippet text, search queries or window titles.

**After you turn analytics off,** the app stops sending events and PostHog's
automatic lifecycle events. Feature flags are different: the app sets PostHog
up at every launch whatever your choice, and the pinned PostHog library
requests feature flags at startup even when analytics are off. That request
carries PostHog's identifier for your install (or your account ID once you
have signed in).

## Crash reports (official app only)

The official app uses Firebase Crashlytics. After a crash it sends the
stack trace and device information to Google. The app attaches no
transcript text, logs or user ID. There is no setting in the app to turn
crash reporting off. Whether crashes are collected is fixed when the app is
built (the `FirebaseCrashlyticsCollectionEnabled` value in `Info.plist`,
which comes from a build setting that is `NO` in this repository). Builds
from this repository therefore do not collect crash reports.

## Updates (official app only)

The official app checks for updates with Sparkle at launch and about once a
day, using a signed feed from Synth's server. The request carries the app
and macOS version in its user agent; Sparkle's system profiling is off. You
can turn off automatic installation in *Settings > General*; there is no
setting to stop the checks themselves.

## BYOK Rewrite (bring your own key)

Rewrite with your own model is free and **off by default** (*Settings >
Rewrite*). If you turn it on:

- after each dictation, and for file transcription and re-transcription,
  Cloudless Voice sends **the transcript text** (after Smart Cleanup, if it
  is on), **the rewrite prompt** and the name of the dictation language to
  the provider you selected, using **your** API key. The default provider is
  Ollama on `localhost`; the other presets are LM Studio, OpenAI, Anthropic
  and OpenRouter, and Custom accepts any OpenAI-compatible URL;
- your custom dictionary terms and the name of the app you're dictating
  into are sent too only if you turn on **Send my dictionary** and **Send
  the app name** (both are off by default). Only the app's name is sent, not
  its bundle ID. The text before and after your cursor is never sent;
- **audio is never sent**;
- **Test connection** sends a fixed sample sentence, and loading the model
  list sends your API key to the provider; neither includes your dictation;
- the request goes directly from your Mac to that provider. It does not
  pass through Synth's servers. Redirects are refused, and no cookies or
  cache are kept;
- plain `http://` is accepted only for this Mac, private-network addresses
  and unqualified host names; any other address needs `https://`;
- that provider's own privacy policy and data retention apply;
- with a provider on your own machine (such as Ollama), nothing leaves the
  machine you configured. A private-network address you configure counts as
  local in the app but is another machine on your network.

Your API keys are stored in the macOS keychain, one item per provider, and
nowhere else. Builds without a signing entitlement (some builds from
source) fall back to the login keychain.

The key is sent only to the provider you configured, in the request that
provider expects. The app does not write request URLs, headers or keys to its
logs, and key-shaped strings are masked in the logs it does write.

## Smart Cleanup

Smart Cleanup (the paid, closed-source cleanup library bundled in this
repository and in official builds; forks may include it too) runs
**on-device**. To check your subscription and free monthly allowance, it
sends **only your sign-in token** to Synth's server (row 4). **It never
sends transcript text or audio.**

If you build the app with `scripts/build-fully-open.sh`, Smart Cleanup
isn't included and this check is never made.

## Beta and debug builds

Beta and debug builds contain two extra features that release builds
don't: *auto-edit* (off by default), which sends the text about to be
inserted to the local model address you configured (by default Ollama on
`localhost`), and a training-sentence generator that calls Synth's server
with built-in examples, not your dictation.

These builds are the ones compiled with the `DEBUG` or `ONIT_BETA` flag
(the `ONIT_BETA` flag belongs to the official release setup and is not set
in this repository's project files). They also write local files that
release builds do not:

- **Debug log.** In a `DEBUG` build only, the app writes a log to
  `~/Library/Logs/Cloudless Voice/Onit.log` (`macos/Onit/App.swift`). The
  folder is created readable by you only (0700) and the file likewise (0600).
  The log records sizes, counts, durations, model and stage names; it does
  not record dictated, cleaned or on-screen text, dictionary terms, window
  titles or file names. Key-shaped strings are masked as well. Release and
  Beta builds do not write this file.
- **Window screenshots.** In `DEBUG` and `ONIT_BETA` builds only, and only
  if you granted Screen Recording permission, the app saves a PNG of the
  frontmost window at the start of a dictation (`start_<timestamp>.png`)
  and, when on-screen term mining runs, one of the window it read
  (`layerc_<timestamp>.png`, the newest 20 are kept). They go to
  `transcription_history_screenshots/` (see below). Release builds do
  not save screenshots.

## Caps Lock remapping

Only if you choose Caps Lock as a shortcut (as the dictation shortcut, one
of its alternates, or a modifier in a typeahead shortcut), the app runs
`/usr/bin/hidutil` to remap the Caps Lock key to F18 so it can read it as a
shortcut. This is a temporary, per-session system setting that is not saved
across a reboot. The app reverts it when you quit it (and after a crash or
force quit, at its next launch). Whenever the app starts or quits without
needing it, it still runs `hidutil` to set the reverse mapping (F18 to Caps
Lock), which replaces any key mapping another tool had set with `hidutil`.

## What is stored on your Mac

Everything below stays on your Mac, in `~/Library/Application Support/Onit/`
unless noted. The app is not sandboxed (its entitlements file has no
`com.apple.security.app-sandbox` key), so any process running as your user
can read these files.

- downloaded speech and cleanup models (`Models/`);
- **transcript history, on by default.** The setting *Save Transcripts to
  History* (*Settings > Configuration*, key `transcriptionHistoryEnabled`)
  defaults to on. Each dictation then adds a row to
  `transcription_history.sqlite` (transcript text, app name and bundle ID,
  timings, model) and keeps its **audio** as a WAV file named
  `history_<timestamp>.wav` in `transcription_history_audio/`. Dictations
  made in the onboarding demo are not saved. The history is not limited in
  size or age, and the app has no automatic expiry for it;
- corrections you save, in `transcription_corrections.sqlite` with their
  audio in `transcription_audio/`, and the
  optional term memory (a dev-flagged feature), in `term_memory.sqlite`;
- your custom dictionary and snippets, in the app's preferences;
- **window screenshots (Debug and Beta builds only)**, as described under
  [Beta and debug builds](#beta-and-debug-builds), in
  `transcription_history_screenshots/`. A `start_<timestamp>.png` is linked
  to the history row of that dictation;
- **the SQLite databases are not encrypted** (they are plain files read
  with GRDB, with no passphrase), and neither are the WAV and PNG files.
  Disk encryption such as FileVault is what protects them at rest;
- your sign-in session token, in `token.enc`. It is encrypted with
  AES-GCM, but the key is stored in a file named `encryption.key` in the
  same folder. Anything that can read your Application Support folder can
  read both files and recover the token, so this is obfuscation at rest
  and not protection from other processes running as your user. Signing
  out removes `token.enc`; it leaves `encryption.key` in place;
- your BYOK API keys are in the macOS keychain, not here (see above);
- in Debug builds only, `~/Library/Logs/Cloudless Voice/Onit.log` (see
  above). The app does not rotate or delete it; remove the folder to clear it.

### Deleting this data

- *Settings > Configuration > History > Delete All* ("Delete Transcript
  History") removes every history row and every WAV file in
  `transcription_history_audio/`, and the matching saved corrections.
  "Delete Corrected Transcript History" does the same for corrected
  transcripts only, and deleting a single transcript removes its audio.
  These actions do **not** remove files in
  `transcription_history_screenshots/` (Debug and Beta builds).
- Turning *Save Transcripts to History* off stops new entries; it does
  not delete the existing ones.
- Term memory has its own *Erase term memory* action and an optional
  retention window (default: never).
- To remove everything, quit the app and delete the
  `~/Library/Application Support/Onit/` folder (this also signs you out and
  removes downloaded models), plus the app's preferences if you want your
  settings, dictionary and snippets gone too.
- *Delete account* (*Settings > Account*) sends one request to the Synth
  server (`DELETE /v1/auth/account`, with your sign-in token), then signs
  you out. It does not delete the local files above, nor transcript fix
  requests you already sent to Firebase: delete those transcripts first if
  you want that copy removed, or write to contact@cloudless.so.

## Changes to this document

Every pull request that adds or changes a network request must update this
file. See [CONTRIBUTING.md](CONTRIBUTING.md).

Questions: contact@cloudless.so.
