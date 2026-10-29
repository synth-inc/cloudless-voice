// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptionCorrectionFirebaseUploader.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-30.
//

import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import Foundation

/// Uploads transcription corrections (audio + metadata) to Firebase.
///
/// Firestore: `users/{accountId}/corrections/{correctionId}`
/// Storage:   `users/{accountId}/corrections/{correctionId}/raw.wav`
///
/// Each correction owns a stable `cloudCorrectionId` minted **at insert time**
/// by `TranscriptionCorrectionManager.saveCorrection(...)` - the uploader
/// never has to assign one. Retries therefore reuse the same Storage path and
/// Firestore docId without coordination, so the upload is idempotent by
/// construction (no orphan blobs, even under concurrent attempts).
///
/// Concurrency model. Swift actors interleave between `await` points, so two
/// invocations of `upload(correctionId:)` for the same row can be in flight
/// simultaneously - the design is robust to that:
///
/// - The cloud id is already set, so neither call can mint a divergent UUID.
/// - `markAudioUploaded(...)` is single-flight in SQL (`WHERE audioUploadedAt
///   IS NULL`) so a second writer becomes a no-op rather than overwriting.
/// - Firestore stamping is gated on the `editVersion` captured at snapshot
///   time. A stale upload that finishes after a fresh `applyEdit(...)` bumped
///   the version sees a mismatch in `markFirestoreUploaded(...)` and silently
///   yields, leaving the post-edit re-push free to succeed with current data.
///
/// Skipped silently when the user is not signed into Firebase Auth or when
/// the correction was saved/uploaded under a different account.
///
/// Consent. A row is uploaded only if its `excludedReason` is NULL, and a new row
/// gets NULL only from an explicit "Request fix" on that transcript. Rows that
/// predate this rule are stamped `legacyUnconsented` by the
/// `v5_excludeUnconsentedLegacyRows` migration.
///
/// What leaves the device per correction: the audio clip (WAV), the raw, cleaned and
/// corrected transcript, the account identifier (Firebase user ID, also in the
/// storage path), the app name and bundle ID, the snippet-expanded flag, timestamp,
/// app version, build number and macOS version. Never the text around the cursor.
actor TranscriptionCorrectionFirebaseUploader {

    static let shared = TranscriptionCorrectionFirebaseUploader()

    /// Schema version for the Firestore document. Bump when the shape changes
    /// so that consumers can branch on older payloads.
    /// v2: replaces `originalTranscription` with `cleanedTranscription`,
    ///     adds `rawTranscription`, drops `locale`, drops redundant
    ///     `correctionId` field (already the doc id).
    private static let schemaVersion = 3

    private init() {}

    /// Uploads (or resumes uploading) the correction with the given local id.
    /// Both the Storage upload and the Firestore write are tracked
    /// independently - a partial failure leaves the row in a state that can
    /// be resumed by `retryPending()`.
    ///
    /// The actor re-fetches the canonical row from the local DB at entry so
    /// it never operates on a stale snapshot.
    func upload(correctionId localId: Int64) async {
        guard FirebaseSetup.isAvailable else { return }
        guard let user = Auth.auth().currentUser else {
            log.info("[CorrectionUploader] Skipped \(localId): not signed into Firebase")
            return
        }
        let accountId = user.uid

        let manager = TranscriptionCorrectionManager.shared
        guard let correction = await manager.fetchOne(id: localId) else {
            log.warning("[CorrectionUploader] Skipped \(localId): row not found in local DB")
            return
        }

        // Permanent exclusion gate: skip rows that were saved while the
        // user did not request a fix, or as a no-edit "Mark as correct".
        // The upload eligibility decision is made at save time and stored in
        // `excludedReason`; we never re-evaluate it here. Rows can only be
        // un-excluded by an explicit "Request fix" on that transcript.
        if let reason = correction.excludedReason {
            log.info("[CorrectionUploader] Skipped \(localId): excludedReason=\(reason)")
            return
        }

        // Account isolation - saver side. A row saved while another Firebase
        // account was signed in must never be uploaded under the current one,
        // even if it has never been claimed yet. Without this check, a shared
        // Mac would silently route account A's pending corrections into
        // account B as soon as B logs in. Legacy rows with `savedByAccountId
        // == nil` predate this column and remain eligible.
        if let savedBy = correction.savedByAccountId, savedBy != accountId {
            log.info("[CorrectionUploader] Skipped \(localId): saved under different account (\(savedBy) vs \(accountId))")
            return
        }

        // Account isolation - claim side. Same idea, but for rows that have
        // already started uploading under another account.
        if let owner = correction.uploadedForAccountId, owner != accountId {
            log.info("[CorrectionUploader] Skipped \(localId): uploaded under different account (\(owner) vs \(accountId))")
            return
        }

        // Cloud id is minted at insert (`saveCorrection`); the only way it can
        // be nil here is if the row predates that change AND somehow escaped
        // the migration backfill. Bail rather than racing a fresh mint.
        guard let correctionDocId = correction.cloudCorrectionId else {
            log.error("[CorrectionUploader] Skipped \(localId): missing cloudCorrectionId (legacy row not backfilled?)")
            return
        }

        // Atomically claim the row for this account on first upload. The
        // SQL is `WHERE uploadedForAccountId IS NULL`, so two concurrent
        // claimants converge on the same winner; we re-read the resulting
        // owner and bail if it isn't us.
        do {
            let resolvedOwner = try await manager.claimForAccount(id: localId, accountId: accountId)
            if let resolvedOwner, resolvedOwner != accountId {
                log.info("[CorrectionUploader] Skipped \(localId): another claim won (\(resolvedOwner) vs \(accountId))")
                return
            }
        } catch {
            log.error("[CorrectionUploader] Failed to claim correction \(localId): \(error)")
            return
        }

        // Snapshot the edit version *now*, before any I/O. The Firestore
        // stamp at the end is gated on this value, so a fresh `applyEdit(...)`
        // landing during the round-trip can't suppress the next push.
        let snapshotEditVersion = correction.editVersion

        let storagePath = "users/\(accountId)/corrections/\(correctionDocId)/raw.wav"

        // Step 1 - Storage. Skip if already uploaded.
        // If the audio was never uploaded, the local file MUST exist - otherwise we'd
        // write a Firestore doc with no `audioStoragePath`, mark the row as uploaded,
        // and count an audio-less row toward the contributions total. Bail out instead
        // so the row stays pending for a future retry (or for manual investigation).
        var audioPathForDoc: String? = correction.audioUploadedAt != nil ? storagePath : nil
        if correction.audioUploadedAt == nil {
            let audioFileURL = manager.audioFileURL(for: correction)
            guard let audioFileURL,
                  FileManager.default.fileExists(atPath: audioFileURL.path) else {
                log.error("[CorrectionUploader] Audio file missing for \(correctionDocId) (localId=\(localId)); skipping upload to avoid orphan Firestore doc")
                return
            }
            do {
                let ref = Storage.storage().reference(withPath: storagePath)
                let metadata = StorageMetadata()
                metadata.contentType = "audio/wav"
                _ = try await ref.putFileAsync(from: audioFileURL, metadata: metadata)
                try? await manager.markAudioUploaded(id: localId)
                audioPathForDoc = storagePath
            } catch {
                log.error("[CorrectionUploader] Storage upload failed for \(correctionDocId): \(error)")
                return
            }
        }

        // Step 2 - Firestore. Written when not yet uploaded; the doc is also
        // re-written when a local update sets `firestoreUploadedAt` back to
        // nil, propagating edits to the cloud.
        if correction.firestoreUploadedAt == nil {
            do {
                try await writeDocument(
                    correction: correction,
                    accountId: accountId,
                    correctionDocId: correctionDocId,
                    audioStoragePath: audioPathForDoc
                )
                let stamped = (try? await manager.markFirestoreUploaded(
                    id: localId,
                    expectedEditVersion: snapshotEditVersion
                )) ?? false
                guard stamped else {
                    // A local edit landed while we were uploading. The fresh
                    // `applyEdit(...)` already enqueued a follow-up upload that
                    // will push the new content; ours wrote stale data, but
                    // the follow-up will overwrite both the doc and the local
                    // markers. Don't increment the contributions counter here:
                    // the follow-up owns that decision when it succeeds.
                    log.info("[CorrectionUploader] Stale upload for \(correctionDocId) (snapshot v\(snapshotEditVersion) outdated); deferring counter to next push")
                    return
                }
                log.info("[CorrectionUploader] Uploaded correction \(correctionDocId) for account \(accountId)")

                // Counter is derived from a SQL COUNT (single source of truth)
                // rather than RMW'd here. We only fire the recompute when our
                // markEverUploaded call actually stamped the row - `markEverUploaded`
                // is gated on `everUploadedAt IS NULL`, so two interleaved uploads
                // for the same row converge on a single increment naturally.
                let firstStamp = (try? await manager.markEverUploaded(id: localId)) ?? false
                if firstStamp {
                    await manager.refreshContributionsCount(forAccountId: accountId)
                }
            } catch {
                log.error("[CorrectionUploader] Firestore upload failed for \(correctionDocId): \(error)")
            }
        }
    }

    /// Best-effort cloud-side delete for corrections that have been removed
    /// locally (e.g. cascade-delete from history-row deletion). Failures are
    /// logged and swallowed - the row stays in Firebase as orphan data until
    /// a subsequent retry or the per-user retention policy purges it. We
    /// never block the local delete on these calls.
    func deleteUploaded(_ corrections: [TranscriptionCorrection]) async {
        guard FirebaseSetup.isAvailable else { return }
        guard let user = Auth.auth().currentUser else {
            log.info("[CorrectionUploader] deleteUploaded skipped: not signed in")
            return
        }
        let accountId = user.uid

        for correction in corrections {
            // Only delete what was actually uploaded under THIS account.
            guard let cloudId = correction.cloudCorrectionId,
                  let owner = correction.uploadedForAccountId,
                  owner == accountId else { continue }

            let storagePath = "users/\(accountId)/corrections/\(cloudId)/raw.wav"
            let storageRef = Storage.storage().reference(withPath: storagePath)
            do {
                try await storageRef.delete()
            } catch {
                log.warning("[CorrectionUploader] Storage delete failed for \(cloudId): \(error)")
            }

            let doc = Firestore.firestore()
                .collection("users")
                .document(accountId)
                .collection("corrections")
                .document(cloudId)
            do {
                try await doc.delete()
            } catch {
                log.warning("[CorrectionUploader] Firestore delete failed for \(cloudId): \(error)")
            }
        }
    }

    /// Reattempts every correction that still has a missing Storage upload or
    /// Firestore write under the currently signed-in account. Called after a
    /// successful Firebase sign-in.
    func retryPending() async {
        guard FirebaseSetup.isAvailable else { return }
        guard let user = Auth.auth().currentUser else { return }
        let accountId = user.uid

        let manager = TranscriptionCorrectionManager.shared
        let pending = await manager.fetchPendingUploads(forAccountId: accountId)
        guard !pending.isEmpty else { return }

        log.info("[CorrectionUploader] Retrying \(pending.count) pending upload(s) for account \(accountId)")
        for correction in pending {
            guard let id = correction.id else { continue }
            await upload(correctionId: id)
        }
    }

    // MARK: - Helpers

    private func writeDocument(
        correction: TranscriptionCorrection,
        accountId: String,
        correctionDocId: String,
        audioStoragePath: String?
    ) async throws {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        var data: [String: Any] = [
            "accountId": accountId,
            "cleanedTranscription": correction.originalTranscription,
            "correctedTranscription": correction.correctedTranscription,
            "timestamp": Timestamp(date: correction.timestamp),
            "appVersion": appVersion,
            "buildNumber": buildNumber,
            "osVersion": osVersion,
            "schemaVersion": Self.schemaVersion,
        ]

        if let rawTranscription = correction.rawTranscription {
            data["rawTranscription"] = rawTranscription
        }
        // `precedingText` / `followingText` are intentionally NOT uploaded:
        // they capture surrounding text from the user's target app and may
        // contain arbitrary private content (passwords, private messages, …).
        // The consent text lists exactly what is sent (audio, transcripts, account
        // identifier, app name, versions), so this surrounding text must stay out of
        // it. It remains in the local DB (used to update the history record) and
        // never leaves the device.
        if let appName = correction.appName {
            data["appName"] = appName
        }
        if let appBundleId = correction.appBundleId {
            data["appBundleId"] = appBundleId
        }
        // Non-sensitive metadata: lets the training pipeline identify/filter
        // dictations where a user snippet expansion fired.
        if let snippetExpanded = correction.snippetExpanded {
            data["snippetExpanded"] = snippetExpanded
        }
        if let audioStoragePath {
            data["audioStoragePath"] = audioStoragePath
        }

        let doc = Firestore.firestore()
            .collection("users")
            .document(accountId)
            .collection("corrections")
            .document(correctionDocId)

        try await doc.setData(data)
    }
}
