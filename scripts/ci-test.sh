#!/usr/bin/env bash
#
# ci-test.sh: what .github/workflows/build.yml runs, so it can be run locally too.
#
#   scripts/ci-test.sh build   # build the app and tests (unsigned, Debug)
#   scripts/ci-test.sh test    # run the default test plan against that build
#
# For the fully open job, run scripts/build-fully-open.sh first (and --restore after).
#
# Environment:
#   DERIVED_DATA   DerivedData path   (default: .build/ci/<official|fully-open>/DerivedData,
#                  one per build, since a DerivedData that built the official app
#                  keeps a TranscriptionCleanup module the fully open build would
#                  pick up). SwiftPM checkouts land in its SourcePackages/, where
#                  the Crashlytics build phase expects them; CI caches that folder.
#   RESULT_BUNDLE  .xcresult to write (default: none)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f libs/transcription-cleanup-swift/.fully-open-stub ]]; then mode=fully-open; else mode=official; fi
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/.build/ci/$mode/DerivedData}"

common=(
    -project macos/Onit.xcodeproj
    -scheme Onit
    -testPlan Onit
    -configuration Debug
    -destination 'platform=macOS'
    -derivedDataPath "$DERIVED_DATA"
    -skipMacroValidation
    -skipPackagePluginValidation
)

case "${1:-}" in
    build)
        xcodebuild build-for-testing "${common[@]}" CODE_SIGNING_ALLOWED=NO
        ;;
    test)
        # xcodebuild ignores the plan's skippedTests for Swift Testing (suites and
        # functions alike), so pass every skipped test as a flag too (see
        # scripts/check-ci-testplan.py).
        skip=()
        while IFS= read -r arg; do
            skip+=("$arg")
        done < <(python3 scripts/check-ci-testplan.py --skip-testing-args)
        result=()
        if [[ -n "${RESULT_BUNDLE:-}" ]]; then
            rm -rf "$RESULT_BUNDLE"
            result=(-resultBundlePath "$RESULT_BUNDLE")
        fi
        xcodebuild test-without-building "${common[@]}" \
            ${skip[@]+"${skip[@]}"} ${result[@]+"${result[@]}"} \
            CODE_SIGNING_ALLOWED=NO
        ;;
    *)
        sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 2
        ;;
esac
