## What and why

<!-- What does this change, and why? Link the issue: "Closes #123". -->

## How I tested it

<!-- Unit tests, manual steps, which apps you dictated into, which speech model. -->

## Checklist

- [ ] I license this contribution under GPL-3.0-or-later with the additional permissions in `LICENSE-EXCEPTION`, and I have the right to submit it under those terms (see [Licensing of contributions](https://github.com/synth-inc/cloudless-voice/blob/main/CONTRIBUTING.md#licensing-of-contributions)).
- [ ] Tests pass locally (`scripts/ci-test.sh build && scripts/ci-test.sh test`, see CONTRIBUTING.md), or I've noted which pre-existing failures I saw.
- [ ] New Swift files have the SPDX header (`scripts/add-spdx-headers.sh --check`).
- [ ] If this touches cleanup or Smart Cleanup: it still builds and works with `scripts/build-fully-open.sh --build` (then `--restore`).
- [ ] If this adds or changes a network request: I updated [PRIVACY.md](https://github.com/synth-inc/cloudless-voice/blob/main/PRIVACY.md).
- [ ] If this adds user-facing strings: they're in the string catalogs (French translation added, or noted below).

## Screenshots

<!-- For UI changes. -->
