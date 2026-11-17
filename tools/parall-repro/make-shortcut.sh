#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
#
# Builds a Parall-style launcher shortcut for an installed app (execv into the
# original binary, same PID). See README.md in this directory.
#
# Usage: tools/parall-repro/make-shortcut.sh [/Applications/Target.app] [OutputDir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET_APP="$(cd "${1:-/System/Applications/TextEdit.app}" && pwd)"
OUT_DIR="${2:-$HERE/build}"
# CHECK_IN=1 makes the launcher check in with LaunchServices before exec.
CHECK_IN="${CHECK_IN:-1}"

TARGET_EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$TARGET_APP/Contents/Info.plist")"
TARGET_EXEC="$TARGET_APP/Contents/MacOS/$TARGET_EXEC_NAME"
TARGET_NAME="$(basename "$TARGET_APP" .app)"
SLUG="$(echo "$TARGET_NAME" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
SHORTCUT="$OUT_DIR/$TARGET_NAME (Parall repro).app"

[ -x "$TARGET_EXEC" ] || { echo "error: $TARGET_EXEC is not executable" >&2; exit 1; }

rm -rf "$SHORTCUT"
mkdir -p "$SHORTCUT/Contents/MacOS" "$SHORTCUT/Contents/Resources"

clang -O2 -framework CoreFoundation -framework AppKit -o "$SHORTCUT/Contents/MacOS/launcher" "$HERE/launcher.c"

ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$TARGET_APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$ICON_FILE" ]; then
  [[ "$ICON_FILE" == *.icns ]] || ICON_FILE="$ICON_FILE.icns"
  cp "$TARGET_APP/Contents/Resources/$ICON_FILE" "$SHORTCUT/Contents/Resources/" 2>/dev/null || ICON_FILE=""
fi

cat > "$SHORTCUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.cloudless.parall-repro.$SLUG</string>
  <key>CFBundleName</key><string>$TARGET_NAME (Parall repro)</string>
  <key>CFBundleExecutable</key><string>launcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>$ICON_FILE</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ReproCheckInBeforeExec</key><$( [ "$CHECK_IN" = 1 ] && echo true || echo false )/>
  <key>ReproTargetExecutable</key><string>$TARGET_EXEC</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$SHORTCUT" >/dev/null
echo "$SHORTCUT"
