// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
// Minimal reproduction of a Parall-style app shortcut: a tiny launcher bundle
// whose executable execv()s the real app binary, so the target app keeps the
// launcher's PID. With this pattern NSRunningApplication can report a
// processIdentifier of -1 for the running app.
//
// The target executable path is read from the launcher bundle's Info.plist key
// `ReproTargetExecutable`.

#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <objc/message.h>
#include <objc/runtime.h>

// Brings up NSApplication and finishes launching, which checks this process in
// with LaunchServices under the launcher bundle's identity (own Dock tile)
// before the exec - the in-place re-exec pattern Parall uses.
static void checkInAsShortcut(void) {
    id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"), sel_getUid("sharedApplication"));
    ((void (*)(id, SEL))objc_msgSend)(app, sel_getUid("finishLaunching"));
}

int main(int argc, char *argv[]) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFStringRef target = bundle
        ? (CFStringRef)CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("ReproTargetExecutable"))
        : NULL;
    if (!target || CFGetTypeID(target) != CFStringGetTypeID()) {
        fprintf(stderr, "parall-repro: ReproTargetExecutable missing from Info.plist\n");
        return 1;
    }
    char path[PATH_MAX];
    if (!CFStringGetFileSystemRepresentation(target, path, sizeof(path))) {
        fprintf(stderr, "parall-repro: bad target path\n");
        return 1;
    }
    // Optional (Info.plist ReproCheckInBeforeExec = true): register with
    // LaunchServices as the shortcut first, like a launcher that owns its own
    // Dock identity, and only then exec into the target.
    CFBooleanRef checkIn = (CFBooleanRef)CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("ReproCheckInBeforeExec"));
    if (checkIn && CFGetTypeID(checkIn) == CFBooleanGetTypeID() && CFBooleanGetValue(checkIn)) {
        checkInAsShortcut();
    }
    argv[0] = path;
    execv(path, argv);
    perror("parall-repro: execv");
    return 1;
}
