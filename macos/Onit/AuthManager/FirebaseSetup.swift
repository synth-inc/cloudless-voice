// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  FirebaseSetup.swift
//  Onit
//

import FirebaseCore
import FirebaseFirestore
import Foundation

/// Firebase (Crashlytics, transcript-correction uploads) is only part of official
/// builds: `GoogleService-Info.plist` is not in the public repo and is copied into
/// the bundle from the private release overlay at build time. Public and fork
/// builds never configure Firebase, so every Firebase entry point must check
/// `isAvailable` first (`Auth.auth()` / `Firestore.firestore()` raise without a
/// configured app).
enum FirebaseSetup {
    static let isAvailable: Bool =
        Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil

    /// Configures Firebase when the build ships its config. Call once at launch.
    static func configureIfAvailable() {
        guard isAvailable else {
            log.info("[FirebaseSetup] No GoogleService-Info.plist in bundle; Firebase disabled")
            return
        }
        FirebaseApp.configure()
        // Use a memory-only Firestore cache: we only write to Firestore from
        // this client, so the default disk cache (which lands in ~/Documents
        // on non-sandboxed macOS and triggers a TCC permission popup) is
        // wasteful for our use case.
        let firestoreSettings = FirestoreSettings()
        firestoreSettings.cacheSettings = MemoryCacheSettings()
        Firestore.firestore().settings = firestoreSettings
    }
}
