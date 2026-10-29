// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptReviewModal.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-28.
//

import Defaults
import SwiftUI

/// Modal that lets the user step through unreviewed transcripts and either
/// confirm them as correct or rewrite them to teach future dictation.
///
/// The queue is a snapshot of `.unreviewed` items captured the first time the
/// modal opens (the seed item is forced to the front so the user lands on the
/// transcript they actually clicked). Save/Skip/Back navigate inside that
/// snapshot. When the queue is exhausted the modal swaps in
/// `TranscriptReviewQueueEndState`.
struct TranscriptReviewModal: View {
    // MARK: - Properties

    /// The transcript the user clicked "Review & teach Onit" on. Becomes the
    /// first item in the queue.
    let seed: TranscriptionHistory

    /// Order of the unreviewed queue. Defaults to `.newest` to match the
    /// historical behavior - callers that surface a sort selector to the
    /// user (e.g. the Transcripts tab) should forward their current choice
    /// so navigating "next" mirrors what the user sees in the list.
    ///
    /// Snapshot, not a live binding: the value is captured at modal open
    /// and the queue does not re-sort if the user changes the sort dropdown
    /// while the modal is up. Reopening the modal picks up the new order
    /// (the parent presents via `.sheet(item:)`, which reinitializes us).
    /// Don't promote this to `@Binding` - the UX of the queue reshuffling
    /// underneath an in-progress correction would be jarring.
    var sortOrder: TranscriptionHistoryManager.SortOrder = .newest

    /// Notify the parent so its row state stays in sync after each save.
    let onChanged: (TranscriptionHistory) -> Void

    /// Notify the parent that a row was permanently deleted from inside
    /// the modal (toolbar trash button). The parent uses this to drop the
    /// row from its visible list so the page reflects the change without
    /// needing a full reload. Default no-op so call sites that haven't
    /// opted in still compile.
    var onDeleted: (TranscriptionHistory) -> Void = { _ in }

    // MARK: - Environment

    @Environment(\.dismiss) private var dismiss

    // MARK: - Observations

    @ObservedObject private var historyManager = TranscriptionHistoryManager.shared
    @ObservedObject private var localization = LocalizationManager.shared

    // MARK: - States

    @State private var queue: [TranscriptionHistory] = []
    @State private var currentIndex: Int = 0
    @State private var hasLoadedQueue: Bool = false

    @State private var currentText: String = ""
    @State private var initialText: String = ""

    @State private var endStateMode: TranscriptReviewQueueEndState.Mode? = nil

    @State private var isSavingItem: Bool = false
    @State private var saveError: String? = nil

    /// True between the moment a save succeeds and the moment we advance to
    /// the next transcript. During this 1s window the textbox + audio player
    /// are visually disabled and the toolbar shows the new status badge so
    /// the user gets visible confirmation that the save landed before the
    /// next item slides in.
    @State private var isInTransition: Bool = false
    @State private var transitionTask: Task<Void, Never>? = nil

    @State private var showDiscardConfirmation: Bool = false
    /// Action to perform after the user confirms discarding their unsaved edits.
    @State private var pendingAfterDiscard: (() -> Void)? = nil

    /// Backing flag for the destructive "Delete transcript?" alert. Set by
    /// `handleDelete` and cleared once the user picks Cancel or Delete.
    @State private var showDeleteConfirmation: Bool = false
    @State private var deleteFailedErrorMessage: String? = nil

    @FocusState private var isTextboxFocused: Bool
    @State private var measuredTextHeight: CGFloat = 0

    /// The `TranscriptionCorrection` record (if any) for the current row.
    /// Looked up each time the queue pointer moves so the toolbar and footer can branch on the persisted upload state (`firestoreUploadedAt`).
    /// Nil for `.unreviewed` rows that have never been saved.
    @State private var currentCorrection: TranscriptionCorrection? = nil

    /// Per-row override that drops into "fix requested" UI immediately on click.
    /// The Firebase upload is fire-and-forget and we don't get a callback when it completes.
    ///     This flag bridges the gap until the user revisits the row (at which point the persisted `firestoreUploadedAt` takes over).
    /// Reset on transcript change.
    @State private var alreadyRequestedFix: Bool = false

    /// Entry point that summoned `RequestFixModal`.
    /// Drives both the `RequestFixModal`'s CTA shape (showAgreeAndSend) + what the "Agree & send" button does on click.
    enum RequestFixModalContext: Equatable {
        /// Save & request fix click on a dirty row. Agree → save with `excludedReason=nil` so the upload kicks off.
        case fromSaveAndRequestFix
        /// Request fix click on a corrected, not-yet-uploaded row.
        /// Agree → call `markEligibleForUpload` to flip the existing correction to eligible.
        case fromRequestFix
        /// "Learn More" click while the row is already uploaded.
        /// The modal is pure information here, so Agree & send is hidden.
        case informational
    }
    
    /// Active context for the `RequestFixModal` overlay.
    /// `nil` means the modal is hidden.
    /// This dictates which downstream action runs when the user clicks "Agree & send" + whether that button is rendered at all in `RequestFixModal`.
    @State private var requestFixModalContext: RequestFixModalContext? = nil

    /// Last non-nil context shown in the `RequestFixModal`, retained across the dismiss fade so the modal's `showAgreeAndSend` doesn't flip mid-animation.
    /// Without this, dismissing an `.informational` modal (Cancel-only) would briefly render the Agree & send button during the fade-out because `nil != .informational` evaluates to true.
    @State private var displayedRequestFixModalContext: RequestFixModalContext? = nil

    @Default(.transcriptionHasConsentedToSendingTranscriptionData) private var hasConsentedToSendingTranscriptionData

    /// Candidate dictionary terms mined from the live correction (CapsTermSelector
    /// criteria; new-vs-raw and not-in-dictionary filtered). Drives the
    /// "Add to dictionary" segment at the bottom of the modal.
    @State private var dictionaryCandidates: [String] = []
    /// Debounce for per-keystroke candidate mining.
    @State private var dictionaryMineTask: Task<Void, Never>? = nil
    /// True while a mining pass is debouncing - drives the bar's loading state.
    @State private var isMiningDictionary: Bool = false

    // MARK: - Layout constants

    private let modalWidth: CGFloat = 620
    private let modalHeight: CGFloat = 460
    private let modalCornerRadius: CGFloat = 22

    // MARK: - Derived

    private var currentItem: TranscriptionHistory? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// The text displayed when the user lands on a fresh item - corrected text
    /// has priority over cleaned, matching the row's display rule. A rewritten row
    /// reviews what the recognizer produced (`rewriteSourceText`), not the model's
    /// prose: the correction teaches the recognizer.
    private var initialTextForCurrentItem: String {
        guard let item = currentItem else { return "" }
        return item.correctedTranscription ?? item.recognizerText
    }

    private var isDirty: Bool {
        currentText != initialText
    }

    private var canSubmit: Bool {
        !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !isSavingItem &&
            !isInTransition &&
            currentItem != nil
    }


    /// Whether the current correction's latest version has been pushed to Firebase.
    /// The optimistic flag covers the brief window between a "Request fix" click and the actual upload completion.
    private var hasBeenUploaded: Bool {
        if alreadyRequestedFix { return true }
        return currentCorrection?.firestoreUploadedAt != nil
    }

    /// Mode for the request-fix info footer, or nil to hide it entirely.
    /// CTA-visible cases take priority: if the user is looking at a button
    /// that could trigger a share, the footer reads as the forward-looking
    /// notice ("Requesting a fix will share…"). The "Fix requested." copy
    /// is reserved for the post-upload, no-CTA state.
    private var requestFixFooterMode: RequestFixInfoFooter.Mode? {
        // No Firebase (public/fork build): fixes can't be requested, so no footer.
        guard FirebaseSetup.isAvailable else { return nil }
        if isDirty { return .canRequestFix }
        
        guard let reviewStatus = currentItem?.reviewStatus else { return nil }
        
        switch reviewStatus {
        case .corrected:
            return hasBeenUploaded ?
                .alreadyRequestedFix :
                .canRequestFix
        default: // `.unreviewed`, `.reviewed`
            return nil
        }
    }

    // MARK: - Body

    var body: some View {
        Group {
            reviewBody
        }
        .frame(width: modalWidth, height: modalHeight)
        .background(
            RoundedRectangle(cornerRadius: modalCornerRadius)
                .fill(Color.surface3)
        )
        .onChange(of: endStateMode) { _, mode in
            if mode != nil {
                dismiss()
            }
        }
        .onChange(of: currentText) { _, newText in
            scheduleDictionaryMine(for: newText)
        }
        .overlay(
            RoundedRectangle(cornerRadius: modalCornerRadius)
                .stroke(Color.T_9, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: modalCornerRadius))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 2)
        .overlay {
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if let context = requestFixModalContext {
                            AnalyticsManager.AppTranscripts.requestFixConsentCancelled(
                                context: Self.analyticsConsentContext(for: context)
                            )
                        }
                        requestFixModalContext = nil
                    }

                RequestFixModal(
                    showAgreeAndSend: displayedRequestFixModalContext != .informational,
                    onCancel: {
                        if let context = requestFixModalContext {
                            AnalyticsManager.AppTranscripts.requestFixConsentCancelled(
                                context: Self.analyticsConsentContext(for: context)
                            )
                        }
                        requestFixModalContext = nil
                    },
                    onAgreeAndSend: {
                        hasConsentedToSendingTranscriptionData = true
                        let context = requestFixModalContext
                        if let context {
                            AnalyticsManager.AppTranscripts.requestFixConsentGranted(
                                context: Self.analyticsConsentContext(for: context)
                            )
                        }
                        requestFixModalContext = nil

                        switch context {
                        case .fromSaveAndRequestFix:
                            performSave(intent: .saveAndRequestFix)
                        case .fromRequestFix:
                            performRequestFix()
                        case .informational, .none:
                            break
                        }
                    }
                )
            }
            .opacity(requestFixModalContext != nil ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: requestFixModalContext)
            .allowsHitTesting(requestFixModalContext != nil)
        }
        .onChange(of: requestFixModalContext) { oldContext, newContext in
            if let newContext {
                displayedRequestFixModalContext = newContext
                // Fire the "shown" event once per transition into a
                // non-nil context. The cancel/granted handlers above
                // already wrap the nil-transition direction.
                if oldContext == nil {
                    AnalyticsManager.AppTranscripts.requestFixConsentShown(
                        context: Self.analyticsConsentContext(for: newContext)
                    )
                }
            }
        }
        .alert(
            String.localized("Discard Changes?", table: "Transcription"),
            isPresented: $showDiscardConfirmation
        ) {
            Button(String.localized("Keep Editing", table: "Transcription"), role: .cancel) {
                pendingAfterDiscard = nil
            }
            Button(String.localized("Close & Discard", table: "Transcription"), role: .destructive) {
                let action = pendingAfterDiscard
                pendingAfterDiscard = nil
                action?()
            }
        } message: {
            Text(String.localized("Exiting will cancel any unsaved changes.", table: "Transcription"))
        }
        // Esc / outside-click closes the alert without firing either button -
        // drop any stranded action so a future dirty interaction doesn't
        // accidentally execute it.
        .onChange(of: showDiscardConfirmation) { _, isPresented in
            if !isPresented { pendingAfterDiscard = nil }
        }
        .alert(
            String.localized("Delete Transcript?", table: "Transcription"),
            isPresented: $showDeleteConfirmation
        ) {
            Button(String.localized("No, Cancel", table: "Transcription"), role: .cancel) {}
            Button(String.localized("Delete", table: "Transcription"), role: .destructive) {
                performDelete()
            }
        } message: {
            Text(String.localized("Deleting a transcript is permanent. Are you sure?", table: "Transcription"))
        }
        .alert(
            String.localized("Delete failed", table: "Transcription"),
            isPresented: .init(
                get: { deleteFailedErrorMessage != nil },
                set: { if !$0 { deleteFailedErrorMessage = nil } }
            )
        ) {
            Button(String.localized("OK", table: "Transcription"), role: .cancel) {}
        } message: {
            if let message = deleteFailedErrorMessage {
                Text(message)
            }
        }
        .task {
            // Fire once per modal-open. `.task` runs on view appearance and
            // SwiftUI re-mounts a `.sheet(item:)` presentation on each
            // open, so without the prior `hasLoadedQueue` guard this is
            // already per-open in practice. The guard is removed so that
            // any future re-mount path (e.g. parent ancestor reflow) also
            // records the open.
            AnalyticsManager.AppTranscripts.reviewOpened(
                transcriptId: seed.id.map { String($0) }
            )
            await loadQueue(initial: true)
        }
        .onDisappear {
            transitionTask?.cancel()
            transitionTask = nil
        }
        .id(localization.currentLanguage)
    }

    // MARK: - Review body (header + content + toolbar)

    private var reviewBody: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                modalHeader

                Group {
                    transcriptTextbox
                        .disabled(isInTransition)

                    if let item = currentItem {
                        TranscriptReviewAudioPlayer(historyItem: item)
                            // Composite identity: `currentIndex` alone misses
                            // delete-and-advance (the next item slides into the
                            // same slot, so the index doesn't change and
                            // SwiftUI keeps the stale player); `item.id` alone
                            // is optional and would silently degrade to a
                            // shared identity for unsaved rows. Combining
                            // both guarantees a tear-down whenever EITHER
                            // changes.
                            .id("\(currentIndex)-\(item.id ?? -1)")
                            .disabled(isInTransition)
                    }

                    if let saveError {
                        Text(saveError)
                            .styleText(size: 12, color: Color.red500)
                    }
                }
                // Soft fade conveys the "frozen" feel during the 1s post-save
                // window without dragging the toast or the status badge with it
                // (those live outside this VStack).
                .opacity(isInTransition ? 0.5 : 1)
                .animation(.easeInOut(duration: 0.15), value: isInTransition)

                Spacer(minLength: 0)
            }
            .padding(16)
            
            VStack(alignment: .leading, spacing: 6) {
                CorrectionAddToDictionaryBar(
                    candidates: dictionaryCandidates,
                    correctionText: currentText,
                    isMining: isMiningDictionary
                )
                    // Chip add/dismiss state is per-transcript: same composite
                    // identity rule as the audio player above.
                    .id("dict-\(currentIndex)-\(currentItem?.id ?? -1)")

                TranscriptReviewToolbar(
                    canGoBack: currentIndex > 0,
                    canSkip: currentItem != nil,
                    canSubmit: canSubmit,
                    isDirty: isDirty,
                    currentStatus: currentItem?.reviewStatus ?? .unreviewed,
                    hasBeenUploaded: hasBeenUploaded,
                    reviewedCount: historyManager.reviewedCount,
                    totalCount: historyManager.historyCount,
                    reviewedTodayCount: historyManager.reviewedTodayCount,
                    onBack: handleBack,
                    onSkip: handleSkip,
                    onDelete: handleDelete,
                    onMarkAsCorrect: handleMarkAsCorrect,
                    onSave: handleSave,
                    onSaveAndRequestFix: handleSaveAndRequestFix,
                    onRequestFix: handleRequestFix,
                    onRevert: handleRevert
                )

                if let footerMode = requestFixFooterMode {
                    RequestFixInfoFooter(
                        mode: footerMode,
                        learnMoreAction: {
                            switch footerMode {
                            case .canRequestFix:
                                requestFixModalContext = isDirty ? .fromSaveAndRequestFix : .fromRequestFix
                            case .alreadyRequestedFix:
                                requestFixModalContext = .informational
                            }
                        }
                    )
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .addBorder(sides: .top, stroke: Color.T_7)
        }
    }

    private var modalHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String.localized("Fix any transcript mistakes", table: "Transcription"))
                    .styleText(
                        size: 15,
                        weight: .regular,
                        color: Color.S_0
                    )

                Text(String.localized(
                    "Your corrections help Cloudless identify new terms for your dictionary.",
                    table: "Transcription"
                ))
                .styleText(
                    weight: .regular,
                    color: Color.T_1
                )
            }
            
            Spacer()
            
            closeButton
        }
    }

    private var closeButton: some View {
        Button(action: requestClose) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.T_3)
                // Align the glyph to the trailing edge of the 28pt hit-zone so
                // the visible icon's right edge sits at the same x as the
                // textbox/player (i.e. 16pt from the modal's trailing edge),
                // while preserving a comfortable click area.
                .frame(width: 28, height: 28, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .offset(y: -8)
    }

    /// Match TextEditor's internal `lineFragmentPadding` so the invisible
    /// sizing guide wraps at the same width as the editor itself.
    private let textEditorLineFragmentPadding: CGFloat = 5

    private var transcriptTextbox: some View {
        ZStack(alignment: .topLeading) {
            // Invisible sizing guide: an off-stage `Text` whose layout matches
            // the editor's, used to drive the editor's frame height. Without
            // this the native `TextEditor` collapses to a single fixed line.
            Text(currentText.isEmpty ? " " : currentText)
                .styleText(size: 14, color: Color.S_0)
                .padding(.horizontal, 10 + textEditorLineFragmentPadding)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .opacity(0)
                .allowsHitTesting(false)
                .onHeightChanged { measuredTextHeight = $0 }

            if currentText.isEmpty {
                Text(String.localized("Correct this transcription", table: "Transcription"))
                    .styleText(
                        weight: .regular,
                        color: Color.T_1
                    )
                    .padding(.horizontal, 10 + textEditorLineFragmentPadding)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $currentText)
                .scrollContentBackground(.hidden)
                .styleText(
                    weight: .regular
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .focused($isTextboxFocused)
                .frame(height: max(measuredTextHeight, 80))
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.special1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.T_8, lineWidth: 1)
        )
        .onAppear {
            // Defer focus so the field has its first responder by the time the
            // user starts typing - setting @FocusState immediately on appear
            // is unreliable on macOS.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTextboxFocused = true
            }
        }
    }

    // MARK: - Queue management

    /// Loads the snapshot of unreviewed transcripts for this session.
    /// On the initial load the seed is forced to the front so the user opens
    /// on the row they clicked.
    private func loadQueue(initial: Bool) async {
        let unreviewed = await historyManager.fetchPaginated(
            limit: 200,
            offset: 0,
            sortOrder: sortOrder,
            reviewStatus: .unreviewed
        )

        var items = unreviewed

        if initial {
            // Always show the seed first, even when it's already reviewed/corrected
            // (the user explicitly asked to re-review it from the row CTA).
            items.removeAll { $0.id == seed.id }
            items.insert(seed, at: 0)
        }

        await MainActor.run {
            queue = items
            currentIndex = 0
            hasLoadedQueue = true
            loadCurrentItemText()

            if items.isEmpty {
                showEndState()
            }
        }
    }

    /// Re-mine "add to dictionary" candidates from the live correction, debounced
    /// so per-keystroke edits don't thrash. Candidates are terms the user
    /// introduced (CapsTermSelector criteria, absent from the raw transcript and
    /// the dictionary) - see CorrectionTermMiner.
    private func scheduleDictionaryMine(for text: String) {
        dictionaryMineTask?.cancel()
        guard let item = currentItem else {
            dictionaryCandidates = []
            isMiningDictionary = false
            return
        }
        // Baseline = raw ASR text + the text the editor STARTED from. The editor
        // opens on cleaned/corrected text, so terms the cleanup pipeline invented
        // (absent from raw, present initially) are not user-typed - without the
        // initial text in the baseline they produced chips at modal open, and
        // accepting one would feed an LLM artifact into the biasing glossary.
        let baseline = item.rawTranscription + "\n" + initialText
        isMiningDictionary = true
        dictionaryMineTask = Task { @MainActor in
            // 1s: long enough that half-typed words don't mine (and get
            // auto-added to the dictionary) mid-keystroke.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            dictionaryCandidates = CorrectionTermMiner.newTerms(
                correction: text,
                raw: baseline
            )
            isMiningDictionary = false
        }
    }

    private func loadCurrentItemText() {
        let text = initialTextForCurrentItem
        currentText = text
        initialText = text
        saveError = nil
        dictionaryMineTask?.cancel()
        dictionaryCandidates = []
        // Per-row UI state (correction snapshot + fix already requested flag)
        // is owned per-transcript: clear here and re-fetch from disk so
        // the toolbar and footer reflect the new row immediately. The
        // optimistic flag is intentionally not persisted - the next
        // visit relies on the canonical `firestoreUploadedAt`.
        currentCorrection = nil
        alreadyRequestedFix = false
        if let id = currentItem?.id {
            Task {
                await loadCurrentCorrection(forHistoryId: id)
            }
        }
    }

    /// End-of-queue: pick the right closing screen depending on whether any
    /// unreviewed transcripts remain in the database.
    private func showEndState() {
        let remaining = max(0, historyManager.historyCount - historyManager.reviewedCount)
        endStateMode = remaining == 0 ? .allReviewed : .queueComplete
    }

    private func keepReviewing() {
        Task {
            await loadQueue(initial: false)
            await MainActor.run {
                if !queue.isEmpty {
                    endStateMode = nil
                }
            }
        }
    }

    // MARK: - Actions

    private func handleBack() {
        guard !isSavingItem, !isInTransition else { return }
        guard currentIndex > 0 else { return }
        guardAgainstDirty {
            currentIndex -= 1
            loadCurrentItemText()
        }
    }

    private func handleSkip() {
        guard !isSavingItem, !isInTransition else { return }
        guardAgainstDirty {
            advanceOrEnd()
        }
    }

    // MARK: - Save / Request fix intents

    /// Classifies which primary-CTA action initiated `performSave(intent:)`.
    /// Drives the exclusion reason routed to the corrections store and the
    /// post-save UI affordances (optimistic "fix requested" flag, toast copy).
    private enum SaveIntent {
        case markAsCorrect
        case save
        case saveAndRequestFix
        case requestFix
    }

    private func handleMarkAsCorrect() {
        performSave(intent: .markAsCorrect)
    }

    private func handleSave() {
        performSave(intent: .save)
    }

    private func handleSaveAndRequestFix() {
        if hasConsentedToSendingTranscriptionData {
            performSave(intent: .saveAndRequestFix)
        } else {
            requestFixModalContext = .fromSaveAndRequestFix
        }
    }

    private func handleRequestFix() {
        if hasConsentedToSendingTranscriptionData {
            performRequestFix()
        } else {
            requestFixModalContext = .fromRequestFix
        }
    }

    private func performSave(intent: SaveIntent) {
        guard !isSavingItem, !isInTransition else { return }
        guard let item = currentItem, let id = item.id else { return }
        // Capture the slot we're about to write into - the user could (in
        // theory) navigate away while the async save is in flight, in which
        // case `currentIndex` no longer points at this item. We `guard`
        // against that on the main-actor write below.
        let savedIndex = currentIndex
        let pendingText = currentText

        // Only the edit-bearing intents hit the corrected-text write path.
        let editPath = intent != .markAsCorrect


        isSavingItem = true
        saveError = nil

        Task {
            do {
                let updated: TranscriptionHistory?
                var editedText: String? = nil
                if editPath {
                    let sanitized = StringHelpers.removeWhiteSpaceAndNewLines(pendingText)
                    editedText = sanitized
                    updated = try await historyManager.update(
                        id: id,
                        correctedTranscription: sanitized
                    )
                } else {
                    updated = try await historyManager.updateReviewStatus(
                        id: id,
                        status: .reviewed
                    )
                }

                AnalyticsManager.AppTranscripts.correctionSaved(
                    transcriptId: String(id),
                    wasEdited: editPath,
                    intent: Self.analyticsIntent(for: intent)
                )

                // Always mirror into the corrections store - for both
                // edits (real corrections) and "Mark as correct" (no-edit).
                // The manager dedups by historyId; per EC7=A, a no-edit
                // save on a transcript that already has a real correction
                // is a no-op (the existing row stays untouched).
                //
                // `correctionSaveFailed` gates the post-save UX downstream:
                // when the mirror fails we must NOT show the success toast
                // or auto-advance, because doing so would steal the
                // saveError off-screen before the user can read it.
                var correctionSaveFailed = false
                if let updated {
                    let textForCorrection = editedText ?? updated.recognizerText
                    let updatedRow = updated
                    let manager = historyManager
                    let samples = await Task.detached {
                        manager.loadAudioSamples(for: updatedRow)
                    }.value
                    let savedByAccountId = AuthManager.shared.account.map { String($0.id) }
                    // Per-intent exclusion routing replaces the old
                    // global-contribution-status read. The intent encodes
                    // an explicit user choice, so pause flags and the
                    // global toggle no longer gate these writes:
                    //   - .markAsCorrect → nil (manager auto-stamps noEdit)
                    //   - .save           → optOut (kept off the uploader)
                    //   - .saveAndRequest → nil (uploader picks it up)
                    let resolvedExclusion: String? = {
                        switch intent {
                        case .markAsCorrect:
                            return nil
                        case .save:
                            return TranscriptionCorrection.ExclusionReason.optOut
                        case .saveAndRequestFix, .requestFix:
                            return nil
                        }
                    }()
                    do {
                        try await TranscriptionCorrectionManager.shared.saveCorrection(
                            originalTranscription: updated.recognizerText,
                            rawTranscription: updated.rawTranscription,
                            correctedTranscription: textForCorrection,
                            audioSamples: samples,
                            sampleRate: 16000,
                            precedingText: updated.precedingText,
                            followingText: updated.followingText,
                            appName: updated.appName,
                            appBundleId: updated.appBundleId,
                            historyId: updated.id,
                            excludedReason: resolvedExclusion,
                            savedByAccountId: savedByAccountId
                        )
                    } catch {
                        // The history row was already updated above (so the
                        // user sees their text), but the correction-store
                        // mirror failed. Surface it explicitly rather than
                        // silently leaving a "ghost reviewed" row with no
                        // correction record (the I6 bug).
                        correctionSaveFailed = true
                        log.error("[TranscriptReviewModal] Local correction save failed: \(error)")
                        await MainActor.run {
                            saveError = String.localized(
                                "Saved review, but couldn't store the correction locally.",
                                table: "Transcription"
                            )
                        }
                    }
                }

                await MainActor.run {
                    isSavingItem = false
                    guard let updated else {
                        // The transcript was deleted between fetch and save -
                        // treat as a hard error so the user notices instead of
                        // silently advancing past a no-op.
                        saveError = String.localized(
                            "Could not save - this transcript may have been deleted.",
                            table: "Transcription"
                        )
                        return
                    }
                    // Only mutate the queue slot if it still points at this id.
                    // The slot update has to land BEFORE the transition window
                    // starts - the toolbar reads `currentItem.reviewStatus` to
                    // pick its rendering, so an outdated slot would still show
                    // "Mark as correct" / "Save" during the 1s pause
                    // instead of the green status badge.
                    if queue.indices.contains(savedIndex), queue[savedIndex].id == id {
                        queue[savedIndex] = updated
                    }
                    onChanged(updated)
                    // The upload is fire-and-forget - drop into the
                    // "Fix requested" toolbar/footer immediately so the
                    // user sees confirmation, then let the persisted
                    // `firestoreUploadedAt` take over on the next visit.
                    // Skipped on mirror-failure so the optimistic UI
                    // doesn't lie about the upload state.
                    if intent == .saveAndRequestFix && !correctionSaveFailed {
                        alreadyRequestedFix = true
                    }
                    // Bail out before the success toast / auto-advance so
                    // the user can read the saveError. They can retry by
                    // re-clicking the CTA; the history row is already saved.
                    guard !correctionSaveFailed else { return }
                    ToastPanelController.shared.show(message: selectToastMessage(for: intent))
                    startPostSaveTransition()
                }

                // Refresh the per-row correction snapshot AFTER the UI
                // settles so `hasBeenUploaded` reflects the newly cleared
                // `firestoreUploadedAt` (and any pending upload that
                // happens to land before the user advances).
                await loadCurrentCorrection(forHistoryId: id)
            } catch {
                await MainActor.run {
                    saveError = error.localizedDescription
                    isSavingItem = false
                }
            }
        }
    }

    /// Flips the existing correction for the current row from any exclusion
    /// state back to upload-eligible and kicks the uploader, without
    /// rewriting the text or advancing the queue. Used by the "Request fix"
    /// button on a `.corrected` row that has not yet been pushed.
    private func performRequestFix() {
        guard !isSavingItem,
              !isInTransition
        else {
            return
        }
        
        guard let item = currentItem,
              let id = item.id
        else {
            return
        }
        
        if hasBeenUploaded { return }

        isSavingItem = true
        saveError = nil

        Task {
            do {
                try await TranscriptionCorrectionManager.shared.markEligibleForUpload(historyId: id)
                AnalyticsManager.AppTranscripts.correctionSaved(
                    transcriptId: String(id),
                    wasEdited: false,
                    intent: .requestFix
                )
                await MainActor.run {
                    isSavingItem = false
                    alreadyRequestedFix = true
                    ToastPanelController.shared.show(message: selectToastMessage(for: .requestFix))
                }
                await loadCurrentCorrection(forHistoryId: id)
            } catch {
                await MainActor.run {
                    isSavingItem = false
                    saveError = error.localizedDescription
                }
            }
        }
    }

    /// Maps the modal's private SaveIntent to the analytics-namespace
    /// SaveIntent (separate types because the analytics enum lives in the
    /// app-wide namespace and gives us a stable PostHog string).
    private static func analyticsIntent(
        for intent: SaveIntent
    ) -> AnalyticsManager.AppTranscripts.SaveIntent {
        switch intent {
        case .markAsCorrect:     return .markAsCorrect
        case .save:              return .save
        case .saveAndRequestFix: return .saveAndRequestFix
        case .requestFix:        return .requestFix
        }
    }

    /// Mirror of the SaveIntent mapping for the consent modal's context
    /// enum - same type-separation rationale.
    private static func analyticsConsentContext(
        for context: RequestFixModalContext
    ) -> AnalyticsManager.AppTranscripts.ConsentContext {
        switch context {
        case .fromSaveAndRequestFix: return .fromSaveAndRequestFix
        case .fromRequestFix:        return .fromRequestFix
        case .informational:         return .informational
        }
    }

    private func selectToastMessage(for intent: SaveIntent) -> String {
        switch intent {
        case .markAsCorrect,
             .save:
            return String.localized("Transcript reviewed", table: "Transcription")
        case .saveAndRequestFix, .requestFix:
            return String.localized("Fix requested", table: "Transcription")
        }
    }

    /// Async-fetches the `TranscriptionCorrection` tied to the given
    /// history row, swapping it into `currentCorrection` only if the user
    /// is still on the same transcript. Guards against the user navigating
    /// away mid-fetch and silently clobbering the next row's snapshot.
    private func loadCurrentCorrection(forHistoryId historyId: Int64) async {
        let fetched = await TranscriptionCorrectionManager.shared.fetchByHistoryId(historyId)
        await MainActor.run {
            if let current = currentItem,
               current.id == historyId
            {
                currentCorrection = fetched
            }
        }
    }

    private func requestClose() {
        // Intentionally NOT gated on `isInTransition` - a close request should
        // always win over the post-save freeze. `onDisappear` cancels the
        // pending `transitionTask` so the in-flight advance hop never
        // mutates @State after teardown.
        guard !isSavingItem else { return }
        guardAgainstDirty {
            dismiss()
        }
    }

    /// Toolbar Delete entry-point. Asks for confirmation, then routes to
    /// `performDelete()` after the user accepts. Mirrors the dirty-edit
    /// guard so a user mid-typing isn't surprised by a destructive action
    /// silently throwing away their unsaved text.
    private func handleDelete() {
        guard !isSavingItem, !isInTransition else { return }
        guard currentItem != nil else { return }
        guardAgainstDirty {
            showDeleteConfirmation = true
        }
    }

    /// Actual deletion path. Removes the history row (which cascade-deletes
    /// the matching correction + audio file + cloud copy via the manager
    /// hook) and advances the queue. We bias toward "stay on the same
    /// index" because the next item naturally slides into that slot - the
    /// user keeps reviewing without losing their place.
    private func performDelete() {
        guard let item = currentItem, let id = item.id else { return }
        let savedIndex = currentIndex

        isSavingItem = true
        Task {
            do {
                try await historyManager.delete(id: id)
                AnalyticsManager.AppTranscripts.transcriptDeleted(transcriptId: String(id))
                await MainActor.run {
                    isSavingItem = false
                    // Tell the parent so it drops the row from its visible
                    // list - without this the Transcripts page keeps
                    // showing the deleted item until something else
                    // (filter change, re-sort, etc.) triggers a reload.
                    onDeleted(item)
                    // Drop the row from our snapshot so the next save/skip
                    // doesn't try to operate on a now-deleted id.
                    if queue.indices.contains(savedIndex), queue[savedIndex].id == id {
                        queue.remove(at: savedIndex)
                    }
                    // The next item now lives at `savedIndex` - stay there
                    // unless we've fallen off the end of the queue.
                    if queue.isEmpty {
                        showEndState()
                    } else if savedIndex >= queue.count {
                        currentIndex = max(0, queue.count - 1)
                        loadCurrentItemText()
                    } else {
                        currentIndex = savedIndex
                        loadCurrentItemText()
                    }
                    ToastPanelController.shared.show(message: String.localized("Transcript deleted", table: "Transcription"))
                }
            } catch {
                await MainActor.run {
                    isSavingItem = false
                    deleteFailedErrorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Reverts the current transcript back to `.unreviewed`, clearing any
    /// previously saved correction. Called when the user clicks the green
    /// "Reviewed" / "Corrected" badge in the toolbar.
    private func handleRevert() {
        guard !isSavingItem, !isInTransition else { return }
        guard let item = currentItem, let id = item.id else { return }
        guard item.reviewStatus != .unreviewed else { return }

        let savedIndex = currentIndex
        let hadCorrection = item.correctedTranscription != nil

        isSavingItem = true
        saveError = nil

        Task {
            do {
                if hadCorrection {
                    // Drop the saved correction first - it leaves reviewStatus
                    // untouched, so the explicit demote below is still required.
                    _ = try await historyManager.update(
                        id: id,
                        correctedTranscription: nil
                    )
                }
                let updated = try await historyManager.updateReviewStatus(
                    id: id,
                    status: .unreviewed
                )

                await MainActor.run {
                    isSavingItem = false
                    guard let updated else {
                        saveError = String.localized(
                            "Could not save - this transcript may have been deleted.",
                            table: "Transcription"
                        )
                        return
                    }
                    if queue.indices.contains(savedIndex), queue[savedIndex].id == id {
                        queue[savedIndex] = updated
                        // Refresh the editor only if we're still standing on
                        // the same item - avoid clobbering the user's text on
                        // a transcript they navigated to in the meantime.
                        if savedIndex == currentIndex {
                            loadCurrentItemText()
                        }
                    }
                    onChanged(updated)
                    ToastPanelController.shared.show(message: String.localized("Marked as unreviewed", table: "Transcription"))
                }
            } catch {
                await MainActor.run {
                    saveError = error.localizedDescription
                    isSavingItem = false
                }
            }
        }
    }

    /// Runs `action` immediately when the editor is clean; otherwise asks the
    /// user to confirm discarding their unsaved edits first.
    private func guardAgainstDirty(_ action: @escaping () -> Void) {
        if isDirty {
            pendingAfterDiscard = action
            showDiscardConfirmation = true
        } else {
            action()
        }
    }

    /// Holds the textbox + audio player in a disabled "frozen" state for 1s
    /// after a save, then advances to the next transcript. Gives the user
    /// time to register the new status badge and toast as confirmation that
    /// the save landed before the next item slides in. Cancellable so a
    /// fresh save (or modal teardown) doesn't double-fire `advanceOrEnd`.
    ///
    /// Cancellation handling: `try await Task.sleep` (without `try?`) lets
    /// the `CancellationError` propagate out of the Task body, so neither
    /// `MainActor.run` nor the post-sleep mutations run on a cancelled task -
    /// avoids touching `@State` after the modal has been torn down.
    private func startPostSaveTransition() {
        transitionTask?.cancel()
        isInTransition = true
        transitionTask = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await MainActor.run {
                isInTransition = false
                advanceOrEnd()
            }
        }
    }

    private func advanceOrEnd() {
        if currentIndex + 1 < queue.count {
            currentIndex += 1
            loadCurrentItemText()
        } else {
            showEndState()
        }
    }

}
