# Parall compatibility repro

[Parall](https://parall.app/) app shortcuts are small launcher bundles that `execv` into the
original app's binary, so the target app keeps the launcher's PID. With that launch pattern
`NSRunningApplication.processIdentifier` can report `-1` for the running app. Cloudless used
that value as the paste target, so `CGEvent.postToPid(-1)` delivered ⌘V nowhere and dictation
never typed into Parall instances.

The fix is `NSRunningApplication.resolvedProcessIdentifier`
(`macos/Onit/General/Extensions/NSRunningApplication+ResolvedPid.swift`), covered by
`macos/OnitTests/ProcessIdentifierResolverTests.swift`.

## Tools

| Script / file | What it does |
| --- | --- |
| `build-notepad.sh` | Builds `build/Repro Notepad.app`, a one-window text editor used as the target, so tests never touch an app you already have open. Its title bar shows its real PID and what `NSRunningApplication` reports. |
| `make-shortcut.sh [Target.app]` | Builds `build/<Target> (Parall repro).app`, a launcher that checks in with LaunchServices under its own bundle ID and then `execv`s the target binary (same PID). Set `CHECK_IN=0` for a bare `execv` launcher. |
| `watch.swift` → `build/watch` | Long-running NSWorkspace observer (like Cloudless). Start it before launching a shortcut and it logs the PID that launch/activate notifications and `frontmostApplication` report. |
| `probe.swift` → `build/probe` | Prints once a second the frontmost-app PID from NSWorkspace, the AX focus owner and the frontmost window owner. |

```sh
cd tools/parall-repro
./build-notepad.sh
./make-shortcut.sh "build/Repro Notepad.app"
swiftc -O -o build/watch watch.swift && swiftc -O -o build/probe probe.swift
./build/watch &            # start before launching
open "build/Repro Notepad (Parall repro).app"
```

**Status:** on macOS 26.3 this launcher has *not* reproduced the `-1`; NSWorkspace reports
the real PID. Parall's shortcut engine is closed source and does something we haven't
matched. Use one of the two test paths below instead.

## Testing the fix

### A. Without Parall: simulate the `-1` (Debug builds only)

Launch the Debug build with `CLOUDLESS_SIMULATE_UNRESOLVED_PID=1` in its environment (Xcode:
Scheme → Run → Arguments → Environment Variables). Every app other than Cloudless itself then
reports pid `-1` to the resolver, which forces the fallback path for real apps:

1. Dictate into TextEdit, Notes, Slack, etc. Text should insert as normal.
2. In the log, look for `[PidResolve] pid -1 for <bundle id> resolved via AX focus to <pid>`.
3. To see the original bug, temporarily revert the `pid > 0` guard in
   `PasteboardManager.insertViaPaste` and make `resolvedProcessIdentifier` return the reported
   pid: dictation then types nothing.

### B. With Parall (end-to-end)

1. Install Parall (the developer offered a promo code) and create a shortcut for e.g.
   TextEdit or Slack.
2. Launch the shortcut, run `build/probe` and focus the Parall instance. Confirm the first
   column shows `-1` while the AX column shows the real PID.
3. Dictate into it with a build without the fix: nothing is typed. With the fix: text is
   inserted and the log shows a `[PidResolve]` line.
