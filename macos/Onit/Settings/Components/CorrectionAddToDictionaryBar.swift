// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CorrectionAddToDictionaryBar.swift
//  Onit
//
//  "Add to dictionary" segment shown beneath a correction editor (the review
//  modal and the in-flow correction overlay). Candidates come from
//  CorrectionTermMiner (CapsTermSelector criteria) - terms the user introduced
//  that aren't in the dictionary yet.
//
//  Terms are OPT-IN (auto-add proved too aggressive in real use):
//    candidate [+ term ×]  mined, NOT added; + adds it, × dismisses
//    enabled   [term ×]    added this session; × removes + persists a dismissal
//    existing  [📕 term ×] already in the dictionary before this correction
//    disabled  [+ term]    dismissed; grayed out, + adds it and clears the dismissal
//  Dismissals persist (customDictionaryDismissedTerms): a ×'d term comes back
//  only as a disabled chip, never as a fresh candidate.
//  A chip leaves the bar when its term no longer appears in the correction text
//  (the user edited it away). The term itself stays in the dictionary - an
//  explicit + is committed; the × chip or the Dictionary page removes it.
//
//  Visuals follow the Figma "added/new terms" spec (Dictation Desktop 5802:122683):
//  14pt medium T_1 header, pill tags (radius 16, 8×4 padding, 14pt S_0 text, 6pt
//  gap) in a single horizontally-scrolling row showing every term (no "+N more").
//  Enabled chips use the solid T_9 fill; disabled chips the dashed T_4 outline.
//

import Defaults
import SwiftUI

struct CorrectionAddToDictionaryBar: View {
    /// Latest mined candidates (already filtered against dictionary + raw
    /// transcript). The bar reconciles these into its stateful chip list.
    let candidates: [String]
    /// The live correction text - used to drop chips whose term the user edited away.
    let correctionText: String
    /// True while a mining pass is pending/debouncing - drives the loading state.
    var isMining: Bool = false

    private enum ChipState { case candidate, enabled, existing, disabled }

    /// Insertion-ordered chips with their lifecycle state. Reset per transcript
    /// by the host applying `.id(...)` keyed to the item.
    @State private var order: [String] = []
    @State private var states: [String: ChipState] = [:]
    /// Terms THIS bar session auto-added - only these are rolled back from the
    /// dictionary when edited away (never terms that pre-existed).
    @State private var sessionAdded: Set<String> = []

    var body: some View {
        Group {
            if order.isEmpty && !isMining {
                // Zero-height anchor so onChange still fires while the bar is empty.
                Color.clear.frame(height: 0)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(String.localized("Add to dictionary", table: "Transcription"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.T_1)
                        if isMining {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.6)
                        }
                    }

                    // One row, horizontally scrollable - every term is reachable.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(order, id: \.self) { term in
                                chip(term, state: states[term] ?? .candidate)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .onChange(of: candidates) { _, new in reconcile(with: new) }
        // Also reconcile on raw text edits: the mining debounce can return an
        // identical candidates array (no onChange) while the user already
        // edited a chip's term away - the edit-away cleanup must still run.
        .onChange(of: correctionText) { _, _ in reconcile(with: candidates) }
        .onAppear { reconcile(with: candidates) }
    }

    // MARK: - Chips

    @ViewBuilder
    private func chip(_ term: String, state: ChipState) -> some View {
        HStack(spacing: 5) {
            if state == .candidate || state == .disabled {
                // Not in the dictionary - + adds it (and clears any dismissal).
                Button {
                    if CustomDictionaryService.shared.addTerm(term) != nil {
                        states[term] = .enabled
                        sessionAdded.insert(term)
                    } else {
                        // addTerm rejects case-insensitive duplicates: the term
                        // landed in the dictionary since this chip was classified
                        // (Settings, another bar, a case-variant chip). Reflect
                        // reality instead of a dead button.
                        states[term] = .existing
                    }
                    Defaults[.customDictionaryDismissedTerms].removeAll { $0 == term.lowercased() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.S_0.opacity(state == .disabled ? 0.45 : 0.8))
                }
                .buttonStyle(PlainButtonStyle())
                .help(String.localized("Add to your dictionary", table: "Transcription"))
            }

            if state == .existing {
                // Already in the dictionary before this correction - distinct
                // from a freshly added term so it never reads as a re-add.
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 8))
                    .foregroundColor(Color.S_0.opacity(0.45))
                    .help(String.localized("Already in your dictionary", table: "Transcription"))
            }

            Text(term)
                .font(.system(size: 14))
                .lineLimit(1)
                .foregroundColor(Color.S_0.opacity(state == .disabled ? 0.45 : (state == .existing ? 0.7 : 1)))

            if state != .disabled {
                // × dismisses a candidate, or undoes a term added THIS session.
                // Pre-existing dictionary terms are NEVER deleted from here - a
                // mis-click in a transient popup must not destroy a curated term
                // and its calibration; deletion lives on the Dictionary page.
                // The dismissal persists so mining stops re-offering the term.
                Button {
                    if state == .enabled {
                        CustomDictionaryService.shared.removeTerm(term)
                    }
                    states[term] = .disabled
                    sessionAdded.remove(term)
                    // LRU append, capped: the list is append-only forever
                    // otherwise - unbounded UserDefaults growth and a term ×'d
                    // once could never be managed down.
                    var dismissed = Defaults[.customDictionaryDismissedTerms]
                    dismissed.removeAll { $0 == term.lowercased() }
                    dismissed.append(term.lowercased())
                    if dismissed.count > 200 { dismissed.removeFirst(dismissed.count - 200) }
                    Defaults[.customDictionaryDismissedTerms] = dismissed
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.S_0.opacity(0.6))
                }
                .buttonStyle(PlainButtonStyle())
                .help(state == .enabled
                      ? String.localized("Remove from dictionary", table: "Transcription")
                      : String.localized("Dismiss", table: "Transcription"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            state == .enabled ? Color.T_9
                : state == .existing ? Color.T_9.opacity(0.45)
                : Color.special1.opacity(state == .disabled ? 0.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            // Dashed outline marks not-in-dictionary chips (provisional, per the
            // Figma spec's unfilled tag); in-dictionary chips are the solid fill.
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    Color.T_4.opacity(state == .disabled ? 0.5 : 1),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                )
                .opacity(state == .candidate || state == .disabled ? 1 : 0)
        )
        .animation(.easeInOut(duration: 0.12), value: states[term] ?? .candidate)
    }

    // MARK: - Reconciliation

    /// Merge a fresh mining pass into the stateful chip list. New terms classify
    /// three ways:
    /// - already in the dictionary → existing chip (clear "it's in your
    ///   dictionary" state - hiding these read as the bar being broken),
    /// - previously dismissed (×) → disabled chip; never re-offered as fresh,
    /// - genuinely new → CANDIDATE chip; nothing is added until the user
    ///   clicks + (auto-add proved too aggressive in real use).
    /// Existing chips keep their state. Chips whose term no longer appears in
    /// the correction text are dropped from the bar, but the term stays in the
    /// dictionary (an explicit + is committed; undo via the × chip or the
    /// Dictionary page). Earlier auto-removal here also fired on transcript
    /// navigation and silently deleted a term the user had just added.
    private func reconcile(with mined: [String]) {
        for term in order where !containsToken(correctionText, term) {
            // Drop the chip from the bar, but DON'T remove the term from the
            // dictionary. The previous "self-clean" deleted a session-added term
            // whenever it left `correctionText` - which also fired on transcript
            // navigation: the host swaps in the next transcript's text (and clears
            // candidates) while this outgoing bar instance still holds
            // `sessionAdded`, so a term the user had *just* explicitly added was
            // silently removed before they ever saw the Dictionary page. An
            // explicit + is committed; undo lives on the × chip and the
            // Dictionary page.
            states[term] = nil
            sessionAdded.remove(term)
        }
        order.removeAll { states[$0] == nil }

        let inDictionary = Set(Defaults[.customDictionaryTermsV2].map(\.textLowercased))
        let dismissed = Set(Defaults[.customDictionaryDismissedTerms])
        for term in mined where states[term] == nil {
            guard containsToken(correctionText, term) else { continue }
            let key = term.lowercased()
            if inDictionary.contains(key) {
                order.append(term)                                  // already yours
                states[term] = .existing
            } else if dismissed.contains(key) {
                order.append(term)                                  // you said no once
                states[term] = .disabled
            } else {
                order.append(term)                                  // new: opt-in
                states[term] = .candidate
            }
        }
    }

    /// Whole-token, case-insensitive presence check ("Onit" doesn't linger when
    /// only "OnitTests" remains, and vice versa).
    private func containsToken(_ text: String, _ term: String) -> Bool {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" && $0 != "'" })
            .contains { $0.caseInsensitiveCompare(term) == .orderedSame }
    }
}
