#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
#
# add-spdx-headers.sh
#
# Makes the SPDX license identifier the first line of every git-tracked
# .swift file under macos/ (app and tests). Existing headers such as
# "//  Created by ..." are kept below it. Safe to re-run: files that already
# start with the header are left untouched, and a different SPDX first line
# is replaced. A "#!" line stays first (the header goes on line 2), a UTF-8
# byte order mark stays in front of the header, and CRLF files get a CRLF
# header line.
#
# Usage:
#   scripts/add-spdx-headers.sh           # add missing headers
#   scripts/add-spdx-headers.sh --check   # list files missing it; exit 1 if any (for CI)

set -euo pipefail

HEADER='// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception'
SPDX_PREFIX='// SPDX-License-Identifier:'

mode="fix"
case "${1:-}" in
  "") ;;
  --check) mode="check" ;;
  -h|--help) sed -n '4,17p' "$0"; exit 0 ;;
  *) echo "Unknown argument: $1 (use --check or no argument)" >&2; exit 2 ;;
esac

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

missing=0
changed=0
total=0

while IFS= read -r -d '' file; do
  total=$((total + 1))
  # Read lines straight from the file (no pipes) so SIGPIPE can't trip pipefail.
  first_line="$(head -n 1 "$file")"

  # A UTF-8 byte order mark must stay at the very start of the file.
  has_bom=0
  if [ "$(head -c 3 "$file" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    has_bom=1
    first_line="${first_line#$'\xef\xbb\xbf'}"
  fi

  # Match the file's line endings, then strip a trailing CR for comparisons.
  eol=$'\n'
  if [[ "$first_line" == *$'\r' ]]; then eol=$'\r\n'; fi
  first_line="${first_line%$'\r'}"

  # A "#!" line must stay first, so the header goes on line 2.
  header_line=1
  target="$first_line"
  if [[ "$first_line" == '#!'* ]]; then
    header_line=2
    target="$(sed -n '2p' "$file")"
    target="${target%$'\r'}"
  fi

  if [ "$target" = "$HEADER" ]; then
    continue
  fi

  if [ "$mode" = "check" ]; then
    echo "missing SPDX header: $file"
    missing=$((missing + 1))
    continue
  fi

  # Line number where the original content resumes; an outdated SPDX line
  # at the header position is dropped (replaced).
  resume_at=$header_line
  if [[ "$target" == "$SPDX_PREFIX"* ]]; then
    resume_at=$((header_line + 1))
  fi

  tmp="$(mktemp)"
  {
    if [ "$has_bom" = 1 ]; then printf '\xef\xbb\xbf'; fi
    if [ "$header_line" = 2 ]; then printf '%s%s' "$first_line" "$eol"; fi
    printf '%s%s' "$HEADER" "$eol"
    if [ "$has_bom" = 1 ]; then
      tail -c +4 "$file" | tail -n +"$resume_at"
    else
      tail -n +"$resume_at" "$file"
    fi
  } > "$tmp"
  # Overwrite in place to keep the file's permissions.
  cat "$tmp" > "$file"
  rm -f "$tmp"
  changed=$((changed + 1))
done < <(git ls-files -z -- 'macos/*.swift')

if [ "$mode" = "check" ]; then
  if [ "$missing" -gt 0 ]; then
    echo "$missing of $total Swift files lack the SPDX header. Run scripts/add-spdx-headers.sh to fix." >&2
    exit 1
  fi
  echo "All $total Swift files under macos/ have the SPDX header."
else
  echo "Added or updated the SPDX header in $changed of $total Swift files under macos/."
fi
