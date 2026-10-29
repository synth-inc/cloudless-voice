#!/usr/bin/env bash
#
# build-fully-open.sh: switch this checkout to the fully open build, or back.
#
# The official app links Smart Cleanup from a closed binary,
# libs/transcription-cleanup-swift/XCFramework/TranscriptionCleanup.xcframework.
# Everything that needs it is behind `#if canImport(TranscriptionCleanup)`, so the
# app builds, runs and passes its tests without it. This script proves that:
#
#   scripts/build-fully-open.sh            # swap in the stub, delete the binary
#   scripts/build-fully-open.sh --build    # ...then build the app (Debug, unsigned,
#                                          #    DerivedData in .build/fully-open)
#   scripts/build-fully-open.sh --restore  # put the closed library back from HEAD
#   scripts/build-fully-open.sh --status   # which build this checkout is set up for
#
# How: Xcode references the local package at libs/transcription-cleanup-swift and
# links its `TranscriptionCleanup` product, so deleting the folder breaks the
# project. Instead the package is replaced by a stub (scripts/fully-open/
# TranscriptionCleanupStub) whose product keeps that name but whose only target is
# an empty module named `TranscriptionCleanupUnavailable`. The app links, and
# `canImport(TranscriptionCleanup)` is false.
#
# While the stub is in, the app is built as inc.synth.Onit.dev.open (scripts/
# fully-open/FullyOpen.xcconfig), so it keeps its own preferences. Local.xcconfig
# and the official release overlay still override that.
#
# Safe to re-run. While stubbed, git ignores the swap (skip-worktree + info/exclude)
# and the pre-commit hook in .githooks/ refuses commits; --restore undoes both.
#
# Use a separate DerivedData for each build (as --build does), or clean when
# switching: a DerivedData that built the official app still holds the real
# TranscriptionCleanup module, and `canImport` would find it.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_REL="libs/transcription-cleanup-swift"
PKG_DIR="$REPO_ROOT/$PKG_REL"
STUB_DIR="$REPO_ROOT/scripts/fully-open/TranscriptionCleanupStub"
MARKER="$PKG_DIR/.fully-open-stub"
STUB_EXCLUDES=("/$PKG_REL/Sources" "/$PKG_REL/.fully-open-stub" "/$PKG_REL/FullyOpen.xcconfig")
# Build settings for the stubbed state (its own bundle ID), included by
# macos/Config/Base.xcconfig while this file exists.
XCCONFIG_SRC="$REPO_ROOT/scripts/fully-open/FullyOpen.xcconfig"
XCCONFIG="$PKG_DIR/FullyOpen.xcconfig"

usage() {
    sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'
}

is_stubbed() {
    [[ -f "$MARKER" ]]
}

# While stubbed, hide the swap from `git add -A` / `commit -a`: otherwise one careless
# commit deletes the closed binary from the official build. Tracked files get
# skip-worktree, the stub's untracked files go in info/exclude (the common git dir:
# a linked worktree doesn't read its own).
hide_stub_from_git() {
    git ls-files -z -- "$PKG_REL" | xargs -0 git update-index --skip-worktree
    local exclude
    exclude="$(git rev-parse --git-common-dir)/info/exclude"
    mkdir -p "$(dirname "$exclude")"
    printf '%s\n' "${STUB_EXCLUDES[@]}" >> "$exclude"
}

show_stub_to_git() {
    git ls-files -z -- "$PKG_REL" | xargs -0 git update-index --no-skip-worktree
    local exclude
    exclude="$(git rev-parse --git-common-dir)/info/exclude"
    if [[ -f "$exclude" ]]; then
        grep -vxF -f <(printf '%s\n' "${STUB_EXCLUDES[@]}") "$exclude" > "$exclude.tmp" || true
        mv "$exclude.tmp" "$exclude"
    fi
}

restore() {
    cd "$REPO_ROOT"
    if ! is_stubbed; then
        # Not ours to reset: e.g. a freshly rebuilt TranscriptionCleanup.xcframework.
        if [[ -n "$(git status --porcelain -- "$PKG_REL")" ]]; then
            echo "error: $PKG_REL isn't the fully open stub but has uncommitted changes;" >&2
            echo "       not discarding them. To drop them: git restore --source=HEAD --staged --worktree -- $PKG_REL" >&2
            exit 1
        fi
        echo "Already the official build ($PKG_REL is the closed library); nothing to restore."
        return
    fi
    # Remove the stub's untracked files, then bring back the tracked package.
    show_stub_to_git
    rm -rf "$PKG_DIR/Sources" "$XCCONFIG" "$MARKER"
    # Without hooks: the repo's post-checkout hook also fires on `git restore`, and
    # would reset submodules and delete SwiftPM caches as a side effect.
    git -c core.hooksPath=/dev/null restore --source=HEAD --staged --worktree -- "$PKG_REL"
    echo "Restored the closed TranscriptionCleanup library ($PKG_REL)."
}

stub() {
    cd "$REPO_ROOT"
    if ! is_stubbed && [[ -n "$(git status --porcelain -- "$PKG_REL")" ]]; then
        echo "error: $PKG_REL has uncommitted changes; commit or discard them first," >&2
        echo "       since --restore restores it from HEAD." >&2
        exit 1
    fi
    # Marker first, so --restore also undoes a swap that was interrupted halfway.
    echo "This package is the fully open stub. Undo with scripts/build-fully-open.sh --restore." > "$MARKER"
    rm -rf "$PKG_DIR/XCFramework" "$PKG_DIR/Sources"
    cp "$STUB_DIR/Package.swift" "$PKG_DIR/Package.swift"
    cp -R "$STUB_DIR/Sources" "$PKG_DIR/Sources"
    cp "$XCCONFIG_SRC" "$XCCONFIG"
    hide_stub_from_git
    echo "Switched to the fully open build: TranscriptionCleanup is now an empty stub."
    echo "Build with --build, or in a DerivedData that never built the official app:"
    echo "a stale TranscriptionCleanup module there would compile the closed code back in."
    echo "Undo with: scripts/build-fully-open.sh --restore"
}

build() {
    cd "$REPO_ROOT"
    xcodebuild \
        -project macos/Onit.xcodeproj \
        -scheme Onit \
        -configuration Debug \
        -derivedDataPath "${DERIVED_DATA_PATH:-$REPO_ROOT/.build/fully-open}" \
        -skipMacroValidation \
        -skipPackagePluginValidation \
        CODE_SIGNING_ALLOWED=NO \
        build
}

case "${1:-}" in
    "")
        stub
        ;;
    --build)
        stub
        build
        ;;
    --restore)
        restore
        ;;
    --status)
        if is_stubbed; then echo "fully open (stub)"; else echo "official (closed library present)"; fi
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
