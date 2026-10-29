# Security Policy

## Reporting a vulnerability

**Please don't report security issues in public GitHub issues, discussions
or pull requests.**

Report them privately using one of these:

1. **GitHub private vulnerability reporting.** This is the preferred
   channel. Go to the [Security tab](https://github.com/synth-inc/cloudless-voice/security)
   of this repository and click **Report a vulnerability**.
2. **Email:** contact@cloudless.so. Please put "Security" in the subject line.

Please include:

- a description of the issue and its impact;
- steps to reproduce, or a proof of concept;
- the app version (*Settings > About*) and your macOS version;
- whether the issue affects the official build, the fully open build
  (`scripts/build-fully-open.sh`), or both.

## What to expect

- We aim to acknowledge your report within 5 business days.
- We'll keep you updated while we investigate and fix it.
- Once a fix ships, we'll publish an advisory and credit you if you want
  credit.

## Scope

In scope:

- the Cloudless Voice macOS app in this repository;
- the update mechanism (Sparkle appcast and signature verification);
- how the app handles audio, transcripts, credentials and API keys.

Also in scope, through the same private channels: issues in the closed
Smart Cleanup library (`libs/transcription-cleanup-swift`). Please follow
its license, which does not permit reverse engineering.

Out of scope: vulnerabilities in third-party dependencies or in AI model
providers you configure for BYOK cleanup. Please report those upstream. If
one affects Cloudless Voice, we'd still like to hear about it.

## Supported versions

Only the latest release of Cloudless Voice receives security fixes. The
official app updates itself, so please keep it up to date.
