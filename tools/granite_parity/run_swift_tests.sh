#!/usr/bin/env bash
#
# Author: Kévin Naudin
#
# Run the GraniteSpeech Swift parity tests from the CLI.
#
# `swift test` can't locate MLX's Metal `default.metallib` (it's a SwiftPM
# bundle resource that isn't staged next to the xctest binary). MLX's
# `load_colocated_library(device, "mlx")` looks for `mlx.metallib` in the same
# directory as the running binary, so we build the tests, copy the metallib
# from the most recent Onit.app build into the xctest's MacOS dir, then run.
#
# Usage: tools/granite_parity/run_swift_tests.sh [--filter <name>]
#   default filter: GraniteSpeechTests
#
set -euo pipefail

PKG_DIR="$(cd "$(dirname "$0")/../../libs/speech-swift-vendored" && pwd)"
FILTER="GraniteSpeechTests"
if [[ "${1:-}" == "--filter" && -n "${2:-}" ]]; then
  FILTER="$2"
fi

cd "$PKG_DIR"

# Locate the FULL MLX metallib (mlx-swift_Cmlx.bundle, ~3.8 MB with all
# kernels). NOT Onit.app/Contents/Resources/default.metallib - that one is a
# ~140 KB JIT stub without fused kernels like layer_norm and fails at runtime.
SRC_METALLIB="$(ls -t \
  "$HOME"/Library/Developer/Xcode/DerivedData/Onit-*/Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib \
  2>/dev/null | head -1 || true)"
if [[ -z "$SRC_METALLIB" ]]; then
  echo "ERROR: no mlx-swift_Cmlx.bundle metallib found. Build Onit (Debug) once in Xcode first." >&2
  exit 1
fi
echo "metallib source: $SRC_METALLIB"

echo "=== building tests ==="
swift build --build-tests

# Stage mlx.metallib next to the xctest executable.
XCTEST_EXE="$(find .build -path '*Qwen3SpeechPackageTests.xctest/Contents/MacOS/*' \
  -type f -perm +111 ! -name '*.dSYM' 2>/dev/null | grep -v dSYM | head -1)"
if [[ -z "$XCTEST_EXE" ]]; then
  echo "ERROR: xctest executable not found after build." >&2
  exit 1
fi
EXE_DIR="$(dirname "$XCTEST_EXE")"
cp "$SRC_METALLIB" "$EXE_DIR/mlx.metallib"
echo "staged mlx.metallib at $EXE_DIR"

echo "=== running tests (filter: $FILTER) ==="
swift test --filter "$FILTER"
