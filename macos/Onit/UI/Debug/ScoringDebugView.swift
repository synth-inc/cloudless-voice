// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ScoringDebugView.swift
//  Onit
//
//  Standalone scoring debug window mirroring the gen_viewer.py HTML output.
//  Shows live results from cleanup calls, with a browsable history sidebar.
//

#if DEBUG

#if canImport(TranscriptionCleanup)

import AppKit
import SwiftUI
import TranscriptionCleanup

// Uses scoringAccentGreen, ScoreTokenChip, ScoreTokenChipFlow from ScoringDebugComponents.swift

// MARK: - Tab

private enum DebugTab: String, CaseIterable {
    case cleanup = "Cleanup"
    case dictionary = "Dictionary"
    case kws = "KWS"
}

// MARK: - Root View

struct ScoringDebugView: View {

    @State private var activeTab: DebugTab = .cleanup

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            switch activeTab {
            case .cleanup:
                CleanupDebugTabView()
            case .dictionary:
                CTCDebugTabView()
            case .kws:
                KWSDebugTabView()
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 700, minHeight: 400)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(DebugTab.allCases, id: \.self) { tab in
                Button {
                    activeTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 12, weight: activeTab == tab ? .semibold : .regular))
                        .foregroundColor(activeTab == tab ? scoringAccentGreen : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            activeTab == tab
                                ? scoringAccentGreen.opacity(0.08)
                                : Color.clear
                        )
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Cleanup Tab

/// Layer C diagnostics: the captured screenshot, the mined terms, the full OCR
/// text, and the per-token caps-selection trace (why each token was kept/dropped).
/// Always-visible format-matcher status card: every dictation explains whether
/// the matcher was off, ran with N terms and changed nothing, or made
/// replacements - and for each replacement, which dictionary term produced it.
/// No more wondering where a rewrite came from.
private struct FormatMatcherDebugCard: View {
    let entry: CleanupDebugEntry

    private var changed: Bool {
        entry.formatBefore != nil && entry.formatBefore != entry.formatAfter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Format matcher")
                    .font(.system(size: 12, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundColor(statusColor)
                    .cornerRadius(4)
            }
            if changed, let b = entry.formatBefore, let a = entry.formatAfter {
                Text("before: \(b)").font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary).textSelection(.enabled)
                Text("after:  \(a)").font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green).textSelection(.enabled)
                ForEach(entry.formatReplacements, id: \.self) { repl in
                    Label(repl, systemImage: "arrow.triangle.swap")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.green)
                        .textSelection(.enabled)
                }
            }
            // Perplexity-gate vetoes: ambiguous merges the gate kept as a
            // natural phrase - shown even when nothing else changed, so a
            // "missing" replacement is explained, not mysterious.
            ForEach(entry.formatVetoed, id: \.self) { veto in
                Label("\(veto)  (perplexity gate: kept as phrase)", systemImage: "hand.raised")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background((changed ? Color.green : Color.gray).opacity(0.08))
        .cornerRadius(6)
    }

    private var statusText: String {
        if !entry.formatEnabled { return "off" }
        if entry.formatTermCount == 0 { return "on · no terms" }
        if !changed { return "on · \(entry.formatTermCount) terms · no changes" }
        return "on · \(entry.formatTermCount) terms · \(entry.formatReplacements.count) replacement\(entry.formatReplacements.count == 1 ? "" : "s")"
    }

    private var statusColor: Color {
        if !entry.formatEnabled { return .gray }
        return changed ? .green : .secondary
    }
}

private struct OnScreenTermsDebugCard: View {
    let entry: CleanupDebugEntry

    private var screenshot: NSImage? {
        guard let name = entry.onScreenScreenshot,
              let dir = TranscriptionHistoryManager.shared.screenshotDirectoryURL else { return nil }
        return NSImage(contentsOf: dir.appendingPathComponent(name))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("On-screen terms - Layer C: \(entry.onScreenTerms.count) kept")
                    .font(.system(size: 12, weight: .semibold))
                if !entry.onScreenHasCommonList {
                    Text("⚠︎ word list not loaded (OOV test off)")
                        .font(.system(size: 10)).foregroundColor(.orange)
                }
            }
            if let source = entry.onScreenSource {
                Text("Source: \(source)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(source.hasPrefix("OCR") ? .purple : .teal)
            }
            if entry.onScreenTerms.isEmpty {
                Text("no terms selected").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Text(entry.onScreenTerms.joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08)).cornerRadius(6)
            }
            if let img = screenshot {
                DisclosureGroup("Captured screenshot (\(Int(img.size.width))×\(Int(img.size.height)))") {
                    Image(nsImage: img).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                }.font(.system(size: 11))
            }
            if !entry.onScreenDecisions.isEmpty {
                let kept = entry.onScreenDecisions.filter { $0.kept }.count
                DisclosureGroup("Selection trace (\(entry.onScreenDecisions.count) unique tokens, \(kept) kept)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(entry.onScreenDecisions.enumerated()), id: \.offset) { _, d in
                                HStack(spacing: 6) {
                                    Text(d.kept ? "✓" : "✗").foregroundColor(d.kept ? .green : .secondary)
                                    Text(d.token).fontWeight(d.kept ? .semibold : .regular)
                                    Text(d.reason).foregroundColor(.secondary)
                                    Spacer(minLength: 0)
                                }.font(.system(size: 10, design: .monospaced))
                            }
                        }.padding(.vertical, 2)
                    }.frame(maxHeight: 280)
                }.font(.system(size: 11))
            }
            if let ocr = entry.onScreenOCRText, !ocr.isEmpty {
                DisclosureGroup("Raw \(entry.onScreenSource?.hasPrefix("OCR") == false ? "accessibility" : "OCR") text (\(ocr.count) chars)") {
                    ScrollView {
                        Text(ocr).font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 280)
                }.font(.system(size: 11))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.04))
        .cornerRadius(8)
    }
}

private struct CleanupDebugTabView: View {

    @ObservedObject private var service = CleanupDebugHistory.shared
    @State private var selectedEntryId: UUID?

    private var selectedEntry: CleanupDebugEntry? {
        guard let id = selectedEntryId else { return service.debugHistory.first }
        return service.debugHistory.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            cleanupSidebar
            Divider()
            VStack(spacing: 0) {
                cleanupToolbar
                Divider()
                if let entry = selectedEntry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let prompt = entry.asrPrompt, !prompt.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("ASR Prompt (dictionary biasing → Qwen/Granite)")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(prompt)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.gray.opacity(0.12))
                                        .cornerRadius(6)
                                }
                            }
                            if entry.onScreenOCRText != nil || !entry.onScreenTerms.isEmpty {
                                OnScreenTermsDebugCard(entry: entry)
                            }
                            FormatMatcherDebugCard(entry: entry)
                            PDIOCard(info: entry.info, precedingText: entry.precedingText, followingText: entry.followingText, deletePrecedingChars: entry.deletePrecedingChars, autoEditText: entry.autoEditText, debugReport: entry.debugReport, suppressedTrailingPunct: entry.suppressedTrailingPunct, trailingFormattingSuffix: entry.trailingFormattingSuffix)
                            if !entry.info.decisions.isEmpty {
                                PDDecisionSection(info: entry.info)
                            }
                            if !entry.info.variant_groups.isEmpty {
                                candidateGroupsSection(info: entry.info)
                            }
                        }
                        .padding(16)
                    }
                    .id(entry.id)
                } else {
                    cleanupEmptyState
                }
            }
        }
        .onChange(of: service.debugHistory.first?.id) { _, newId in
            selectedEntryId = newId
        }
    }

    private var cleanupSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(service.debugHistory.count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            if service.debugHistory.isEmpty {
                Text("No results yet")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(service.debugHistory) { entry in
                            SidebarRow(entry: entry, isSelected: isSelected(entry))
                                .onTapGesture { selectedEntryId = entry.id }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
            }
        }
        .frame(width: 200)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func isSelected(_ entry: CleanupDebugEntry) -> Bool {
        if let id = selectedEntryId { return entry.id == id }
        return entry.id == service.debugHistory.first?.id
    }

    private var cleanupToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu").foregroundColor(scoringAccentGreen)
            Text("Smart Cleanup").font(.system(size: 14, weight: .semibold))
            if let entry = selectedEntry {
                Text("·").foregroundColor(.secondary)
                Text("\(entry.info.num_kept) applied · \(entry.info.num_reverted) reverted")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
            if let entry = selectedEntry {
                Text(formattedDate(entry.date))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private var cleanupEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 32)).foregroundColor(.secondary)
            Text("No cleanup data yet").font(.system(size: 14, weight: .medium))
            Text("Run a transcription with Smart Cleanup enabled to see results here.")
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private func candidateGroupsSection(info: CleanupDebugInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Variant Evaluations (\(info.variant_groups.count) group\(info.variant_groups.count == 1 ? "" : "s"))")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            ForEach(Array(info.variant_groups.enumerated()), id: \.offset) { gi, group in
                PDComboGroupCard(groupIndex: gi, evals: group)
            }
        }
    }
}

// MARK: - CTC Dictionary Tab

private let ctcOrange = Color(red: 0.92, green: 0.56, blue: 0.10)

private struct CTCDebugTabView: View {
    @ObservedObject private var history = CTCDebugHistory.shared
    @State private var selectedEntryId: UUID?

    private var selectedEntry: CTCDebugEntry? {
        guard let id = selectedEntryId else { return history.entries.first }
        return history.entries.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            ctcSidebar
            Divider()
            VStack(spacing: 0) {
                ctcToolbar
                Divider()
                if let entry = selectedEntry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            CTCIOCard(entry: entry)
                            if !entry.termDebug.isEmpty {
                                CTCTermsSection(termDebug: entry.termDebug)
                            }
                        }
                        .padding(16)
                    }
                    .id(entry.id)
                } else {
                    ctcEmptyState
                }
            }
        }
        .onChange(of: history.entries.first?.id) { _, newId in
            selectedEntryId = newId
        }
    }

    // MARK: Sidebar

    private var ctcSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(history.entries.count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            if history.entries.isEmpty {
                Text("No results yet")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(history.entries) { entry in
                            CTCSidebarRow(entry: entry, isSelected: ctcIsSelected(entry))
                                .onTapGesture { selectedEntryId = entry.id }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
            }
        }
        .frame(width: 200)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func ctcIsSelected(_ entry: CTCDebugEntry) -> Bool {
        if let id = selectedEntryId { return entry.id == id }
        return entry.id == history.entries.first?.id
    }

    // MARK: Toolbar

    private var ctcToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.magnifyingglass").foregroundColor(scoringAccentGreen)
            Text("CTC Dictionary").font(.system(size: 14, weight: .semibold))
            if let entry = selectedEntry {
                Text("·").foregroundColor(.secondary)
                let replaced = entry.termDebug.filter { $0.wasReplaced }.count
                let acousticHit = entry.termDebug.filter {
                    if case .acousticHit = $0.detectionState { return true }; return false
                }.count
                let nearMiss = entry.termDebug.filter {
                    if case .nearMiss = $0.detectionState { return true }; return false
                }.count
                if replaced > 0 {
                    Text("\(replaced) replaced")
                        .font(.system(size: 12)).foregroundColor(scoringAccentGreen)
                }
                if acousticHit > 0 {
                    Text("\(acousticHit) acoustic hit")
                        .font(.system(size: 12)).foregroundColor(ctcOrange)
                }
                if nearMiss > 0 {
                    Text("\(nearMiss) near miss")
                        .font(.system(size: 12)).foregroundColor(ctcOrange)
                }
                if replaced == 0 && acousticHit == 0 && nearMiss == 0 {
                    Text("no detections")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            Spacer()
            if let entry = selectedEntry {
                Text(ctcFormattedDate(entry.date))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private static let ctcDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func ctcFormattedDate(_ date: Date) -> String {
        Self.ctcDateFmt.string(from: date)
    }

    // MARK: Empty State

    private var ctcEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.closed").font(.system(size: 32)).foregroundColor(.secondary)
            Text("No dictionary data yet").font(.system(size: 14, weight: .medium))
            Text("Run a transcription with the Custom Dictionary enabled to see CTC scores here.")
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: - CTC Sidebar Row

private struct CTCSidebarRow: View {
    let entry: CTCDebugEntry
    let isSelected: Bool

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private var statusLabel: (text: String, color: Color) {
        let replaced = entry.termDebug.filter { $0.wasReplaced }.count
        let acousticHit = entry.termDebug.filter {
            if case .acousticHit = $0.detectionState { return true }; return false
        }.count
        let nearMiss = entry.termDebug.filter {
            if case .nearMiss = $0.detectionState { return true }; return false
        }.count
        if replaced > 0 {
            return ("\(replaced) replaced", isSelected ? .white.opacity(0.9) : scoringAccentGreen)
        } else if acousticHit > 0 {
            return ("\(acousticHit) acoustic hit", isSelected ? .white.opacity(0.9) : ctcOrange)
        } else if nearMiss > 0 {
            return ("\(nearMiss) near miss", isSelected ? .white.opacity(0.9) : ctcOrange)
        } else if !entry.termDebug.isEmpty {
            return ("no signal", isSelected ? .white.opacity(0.7) : .secondary)
        } else {
            return ("no terms", isSelected ? .white.opacity(0.7) : .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.fmt.string(from: entry.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(isSelected ? .white : .secondary)
            Text(verbatim: entry.input)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(statusLabel.text)
                .font(.system(size: 9))
                .foregroundColor(statusLabel.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? scoringAccentGreen : Color.clear)
        .cornerRadius(5)
    }
}

// MARK: - CTC IO Card

private struct CTCIOCard: View {
    let entry: CTCDebugEntry
    @State private var appeared = false

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    pdRowLabel("input")
                    Text(verbatim: entry.input)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 5)
                .animation(.easeOut(duration: 0.2).delay(0.05), value: appeared)

                HStack(alignment: .top, spacing: 8) {
                    pdRowLabel("output")
                    Text(verbatim: entry.output)
                        .font(.system(size: 13))
                        .foregroundColor(entry.output == entry.input ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 5)
                .animation(.easeOut(duration: 0.2).delay(0.12), value: appeared)

                if entry.output != entry.input {
                    HStack(alignment: .top, spacing: 8) {
                        pdRowLabel("diff")
                        PDDiffText(ops: diff(text1: entry.input, text2: entry.output), fontSize: 13)
                    }
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 5)
                    .animation(.easeOut(duration: 0.2).delay(0.20), value: appeared)
                }
            }
        }
        .onAppear { withAnimation { appeared = true } }
    }
}

// MARK: - CTC Terms Section

private struct CTCTermsSection: View {
    let termDebug: [CTCTermDebug]
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dictionary Terms (\(termDebug.count))")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            ForEach(Array(termDebug.enumerated()), id: \.element.id) { idx, term in
                CTCTermCard(term: term)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .animation(.easeOut(duration: 0.25).delay(0.05 + Double(idx) * 0.06), value: appeared)
            }
        }
        .onAppear { withAnimation { appeared = true } }
    }
}

// MARK: - CTC Term Card

private struct CTCTermCard: View {
    let term: CTCTermDebug

    private var stateColor: Color {
        switch term.detectionState {
        case .replaced:    return scoringAccentGreen
        case .acousticHit: return ctcOrange
        case .nearMiss:    return ctcOrange
        case .noSignal:    return .secondary
        }
    }

    private var stateIcon: String {
        switch term.detectionState {
        case .replaced:    return "checkmark.circle.fill"
        case .acousticHit: return "waveform.badge.exclamationmark"
        case .nearMiss:    return "exclamationmark.triangle.fill"
        case .noSignal:    return "minus.circle"
        }
    }

    private var stateLabel: String {
        switch term.detectionState {
        case .replaced:              return "REPLACED"
        case .acousticHit:           return "ACOUSTIC HIT"
        case .nearMiss(let gap):     return String(format: "NEAR MISS  −%.2f", gap)
        case .noSignal:              return "NO SIGNAL"
        }
    }

    /// Secondary note explaining why an acoustic hit didn't produce a replacement.
    private var acousticHitReason: String? {
        guard case .acousticHit = term.detectionState else { return nil }
        if !term.productionDetected {
            return "ctcWordSpotMultiple did not fire - constrained found signal but production algorithm missed"
        }
        return "production detected acoustically, but no word in transcript matched \"\(term.term)\""
    }

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: 8) {
                // Header row: term name + state badge
                HStack(spacing: 6) {
                    Image(systemName: stateIcon)
                        .foregroundColor(stateColor)
                        .font(.system(size: 12))
                    Text(verbatim: "\"\(term.term)\"")
                        .font(.system(size: 13, weight: .semibold))
                        .textSelection(.enabled)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("\(term.tokenCount) token\(term.tokenCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(stateLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(stateColor)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(stateColor.opacity(0.1))
                        .cornerRadius(4)
                }

                // Score row
                HStack(spacing: 16) {
                    ctcScorePill(label: "threshold", value: term.threshold, color: .secondary)
                    if let score = term.bestScore {
                        ctcScorePill(label: "best score", value: score, color: stateColor)
                        if case .nearMiss = term.detectionState,
                           let needed = term.thresholdNeeded {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 9))
                                    .foregroundColor(ctcOrange)
                                Text(String(format: "lower to %.2f to admit", needed))
                                    .font(.system(size: 10))
                                    .foregroundColor(ctcOrange)
                            }
                        }
                    } else {
                        Text("no acoustic signal")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                // Acoustic-hit explanation: why no replacement despite threshold being met
                if let reason = acousticHitReason {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func ctcScorePill(label: String, value: Float, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .tracking(0.3)
            Text(String(format: "%.2f", value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(color)
        }
    }
}

// MARK: - Inline Diff Text
// Uses the same diff(text1:text2:) Myers algorithm and the same colors as SelectableTextView.

private struct PDDiffText: View {
    let ops: [DiffOperation]
    var fontSize: CGFloat = 12

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for op in ops {
            switch op {
            case .equal(let s):
                var a = AttributedString(s)
                a.font = .system(size: fontSize)
                result.append(a)
            case .delete(let s):
                var a = AttributedString(s)
                a.font = .system(size: fontSize)
                a.foregroundColor = Color(NSColor.redPale400)
                a.backgroundColor = Color(NSColor.redPale400).opacity(0.15)
                a.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Color(NSColor.redPale400))
                result.append(a)
            case .insert(let s):
                var a = AttributedString(s)
                a.font = .system(size: fontSize)
                a.foregroundColor = Color(NSColor.lime400)
                a.backgroundColor = Color(NSColor.lime400).opacity(0.1)
                result.append(a)
            }
        }
        return result
    }
}

// MARK: - Before / After / Diff Row

/// Reusable 3-row component: before text, after text, inline diff.
/// Uses the same diff(text1:text2:) algorithm as the QuickEdit diff view.
private struct PDBeforeAfterDiff: View {
    let before: String
    let after: String
    var beforeSumScore: Double? = nil
    var afterSumScore: Double? = nil
    var fontSize: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                pdRowLabel("before")
                Text(verbatim: before)
                    .font(.system(size: fontSize))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                Spacer()
                scoreBadge(avg: nil, sum: beforeSumScore)
            }
            HStack(alignment: .top, spacing: 8) {
                pdRowLabel("after")
                Text(verbatim: after)
                    .font(.system(size: fontSize))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                Spacer()
                scoreBadge(avg: nil, sum: afterSumScore, highlight: scoreImproved)
            }
            HStack(alignment: .top, spacing: 8) {
                pdRowLabel("diff")
                PDDiffText(ops: diff(text1: before, text2: after), fontSize: fontSize)
            }
        }
    }

    /// True when the after sentence has lower sum Score (better scoring) than before.
    private var scoreImproved: Bool {
        guard let b = beforeSumScore, let a = afterSumScore else { return false }
        return a < b
    }
}

@ViewBuilder
private func scoreBadge(avg: Double?, sum: Double?, highlight: Bool = false) -> some View {
    if avg != nil || sum != nil {
        HStack(spacing: 4) {
            if let s = sum {
                scorePill(label: "sum", value: s, color: Color(red: 0.58, green: 0.21, blue: 0.30))
            }
            if let a = avg {
                scorePill(label: "avg", value: a,
                        color: highlight ? Color(NSColor.lime400) : Color(red: 0.10, green: 0.35, blue: 0.18))
            }
        }
        .padding(.top, 2)
    }
}

private func pdRowLabel(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(.secondary)
        .textCase(.uppercase)
        .tracking(0.3)
        .frame(width: 56, alignment: .trailing)
        .padding(.top, 2)
}

// MARK: - IO Card (animated)

private struct PDIOCard: View {
    let info: CleanupDebugInfo
    var precedingText: String?
    var followingText: String?
    var deletePrecedingChars: Int?
    var autoEditText: String?
    var debugReport: String?
    var suppressedTrailingPunct: Bool = false
    var trailingFormattingSuffix: String? = nil
    @State private var appeared = false

    /// Render whitespace as visible glyphs so spurious phantom-padding is
    /// obvious. Spaces become "·", tabs "→", newlines "↵\n", NBSP/U+202F
    /// "⍽", U+2028 "↵\n".
    private static func visualizeWhitespace(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case " ": out += "·"
            case "\t": out += "→"
            case "\n": out += "↵\n"
            case "\u{00A0}", "\u{202F}": out += "⍽"
            case "\u{2028}": out += "↵\n"
            default: out.append(ch)
            }
        }
        return out
    }

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: 8) {
                if let preceding = precedingText {
                    let tail = preceding.count > 120 ? "…" + preceding.suffix(120) : preceding
                    labeledRow("preceding", Self.visualizeWhitespace(tail),
                               color: .secondary, delay: 0.0, monospaced: true)
                        .opacity(0.85)
                }
                if let following = followingText {
                    let head = following.count > 120 ? following.prefix(120) + "…" : Substring(following)
                    labeledRow("following", Self.visualizeWhitespace(String(head)),
                               color: .secondary, delay: 0.02, monospaced: true)
                        .opacity(0.85)
                }
                if let preceding = precedingText {
                    let preTail = preceding.count > 60 ? "…" + preceding.suffix(60) : preceding
                    let follow = followingText ?? ""
                    let folHead = follow.count > 60 ? follow.prefix(60) + "…" : Substring(follow)
                    let flow = Self.visualizeWhitespace(preTail)
                        + "[" + info.final_output + "]"
                        + Self.visualizeWhitespace(String(folHead))
                    labeledRow("flow", flow, color: .primary, delay: 0.04, monospaced: true)
                }
                labeledRow("input", info.input_text, delay: 0.05)
                labeledRow("output", info.final_output,
                           color: info.final_output == info.input_text ? .secondary : .primary,
                           delay: 0.15)
                if let autoEdit = autoEditText {
                    labeledRow("auto-edit", autoEdit,
                               color: autoEdit == info.final_output ? .secondary : scoringAccentGreen,
                               delay: 0.18)
                }
                if info.final_output != info.input_text {
                    HStack(alignment: .top, spacing: 8) {
                        pdRowLabel("diff")
                        PDDiffText(ops: diff(text1: info.input_text, text2: info.final_output), fontSize: 13)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 5)
                    .animation(.easeOut(duration: 0.25).delay(0.25), value: appeared)
                }
                if let report = debugReport, !report.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        pdRowLabel("report")
                        Text(verbatim: report)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 5)
                    .animation(.easeOut(duration: 0.25).delay(0.30), value: appeared)
                }
                if suppressedTrailingPunct {
                    // Gate skipped: the user's final dictated token was itself
                    // punctuation/symbol/formatting, so we honoured it verbatim.
                    let suffixTag: String = {
                        guard let s = trailingFormattingSuffix else { return "" }
                        let visible = s.replacingOccurrences(of: "\n", with: "\\n")
                            .replacingOccurrences(of: "\t", with: "\\t")
                        return " [preserved break: \(visible)]"
                    }()
                    labeledRow("trail.punct", "→ skipped (user dictated punctuation)\(suffixTag)",
                               color: scoringAccentGreen, delay: 0.36, monospaced: true)
                }
                if let deletes = deletePrecedingChars, deletes > 0 {
                    labeledRow("deletes", "\(deletes) char\(deletes == 1 ? "" : "s") removed before paste",
                               color: Color(NSColor.redPale400), delay: 0.42, monospaced: false)
                }
            }
        }
        .onAppear { withAnimation { appeared = true } }
    }

    private func labeledRow(_ label: String, _ text: String, color: Color = .primary, delay: Double, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            pdRowLabel(label)
            Text(verbatim: text)
                .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
                .foregroundColor(color)
                .textSelection(.enabled)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 5)
        .animation(.easeOut(duration: 0.25).delay(delay), value: appeared)
    }
}

// MARK: - Decision Section (staggered)

private struct PDDecisionSection: View {
    let info: CleanupDebugInfo
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spans (\(info.decisions.count))")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            ForEach(Array(info.decisions.enumerated()), id: \.offset) { idx, decision in
                PDDecisionCard(decision: decision, inputText: info.input_text)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .animation(.easeOut(duration: 0.3).delay(0.05 + Double(idx) * 0.08), value: appeared)
            }
        }
        .onAppear { withAnimation { appeared = true } }
    }
}

// MARK: - Sidebar Row

private struct SidebarRow: View {
    let entry: CleanupDebugEntry
    let isSelected: Bool

    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.fmt.string(from: entry.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(isSelected ? .white : .secondary)
            Text(verbatim: entry.info.input_text)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 4) {
                if entry.info.num_kept > 0 {
                    Text("\(entry.info.num_kept) applied")
                        .font(.system(size: 9))
                        .foregroundColor(isSelected ? Color.white.opacity(0.75) : scoringAccentGreen)
                }
                if entry.info.num_reverted > 0 {
                    Text("\(entry.info.num_reverted) reverted")
                        .font(.system(size: 9))
                        .foregroundColor(isSelected ? Color.white.opacity(0.65) : .secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? scoringAccentGreen : Color.clear)
        .cornerRadius(5)
    }
}

// MARK: - Decision Card

private struct PDDecisionCard: View {
    let decision: CleanupDebugInfo.Decision
    let inputText: String
    @State private var expanded = false

    private var chosenAfterText: String? {
        guard !decision.kept_original, let rep = decision.chosen_replacement else { return nil }
        return buildReplacedText(original: decision.full_original_text ?? inputText,
                                 spanStart: decision.span_start, spanEnd: decision.span_end, replacement: rep)
    }

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: 8) {
                // ── Header row ──
                HStack(spacing: 6) {
                    Image(systemName: decision.kept_original ? "xmark.circle" : "checkmark.circle.fill")
                        .foregroundColor(decision.kept_original ? .secondary : scoringAccentGreen)
                        .font(.system(size: 12))
                    Text(verbatim: "\"\(decision.original_text)\"")
                        .font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                    if !decision.kept_original, let rep = decision.chosen_replacement {
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(.secondary)
                        Text(verbatim: rep.isEmpty ? "(removed)" : "\"\(rep)\"")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(scoringAccentGreen).textSelection(.enabled)
                    }
                    Spacer()
                    if let rule = decision.chosen_rule {
                        Text(rule)
                            .font(.system(size: 10))
                            .foregroundColor(Color(red: 0.10, green: 0.35, blue: 0.18))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(red: 0.85, green: 0.96, blue: 0.88))
                            .cornerRadius(4)
                    }
                    Text(String(format: "ppl %.3f", decision.final_score))
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // ── Always-visible diff (above the fold) ──
                if let beforeText = decision.full_original_text, let afterText = chosenAfterText {
                    PDDiffText(ops: diff(text1: beforeText, text2: afterText), fontSize: 12)
                        .padding(.leading, 20)
                }

                if expanded {
                    // Slot-level before / after / diff (detail)
                    if let beforeText = decision.full_original_text, let afterText = chosenAfterText {
                        Divider()
                        PDBeforeAfterDiff(before: beforeText, after: afterText, fontSize: 13)
                    }

                    // Original full-sentence token chips
                    if let tokens = decision.original_tokens, !tokens.isEmpty {
                        Divider()
                        PDScoreRow(label: "original", tokens: tokens,
                                 sumScore: decision.original_sum_score)
                    }

                    // Candidates
                    if !decision.candidates.isEmpty {
                        Divider()
                        Text("Candidates")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                            .textCase(.uppercase).tracking(0.5)
                        ForEach(Array(decision.candidates.enumerated()), id: \.offset) { _, cand in
                            let isChosen = cand.rule_name == decision.chosen_rule
                                && cand.replacement == decision.chosen_replacement
                            PDCandidateRow(
                                candidate: cand,
                                isChosen: isChosen,
                                originalText: decision.full_original_text ?? inputText,
                                spanStart: decision.span_start,
                                spanEnd: decision.span_end,
                                originalSumScore: decision.original_sum_score
                            )
                        }
                    }
                }
            }
        }
    }
}

/// Builds a full string with a single span replaced.
/// Note: spanStart/spanEnd are Unicode scalar (code-point) offsets, matching the Python server output.
private func buildReplacedText(original: String, spanStart: Int, spanEnd: Int, replacement: String) -> String {
    let sv = original.unicodeScalars
    let n = sv.count
    let si = sv.index(sv.startIndex, offsetBy: min(spanStart, n))
    let ei = sv.index(sv.startIndex, offsetBy: min(spanEnd, n))
    return String(sv[..<si]) + replacement + String(sv[ei...])
}

// MARK: - Candidate Row

private struct PDCandidateRow: View {
    let candidate: CleanupDebugInfo.Candidate
    let isChosen: Bool
    let originalText: String
    let spanStart: Int
    let spanEnd: Int
    var originalSumScore: Double? = nil

    private var afterText: String {
        candidate.full_text
            ?? buildReplacedText(original: originalText, spanStart: spanStart,
                                  spanEnd: spanEnd, replacement: candidate.replacement)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Rule + replacement label
            HStack(spacing: 6) {
                Circle()
                    .fill(isChosen ? scoringAccentGreen : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(verbatim: candidate.rule_name)
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Text("→").font(.system(size: 11)).foregroundColor(.secondary)
                Text(verbatim: candidate.replacement.isEmpty ? "(remove)" : "\"\(candidate.replacement)\"")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isChosen ? scoringAccentGreen : .primary)
                    .textSelection(.enabled)
            }

            // Before / After / Diff - with scoring scores on each row
            PDBeforeAfterDiff(
                before: originalText,
                after: afterText,
                beforeSumScore: originalSumScore,
                afterSumScore: candidate.sum_score,
                fontSize: 12
            )
            .padding(.leading, 14)

            // Full-sentence token chips
            if let tokens = candidate.tokens, !tokens.isEmpty {
                ScoreTokenChipFlow(tokens: tokens, showScoreValues: true, spacing: 3, fontSize: 11)
                    .padding(.leading, 14)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isChosen ? scoringAccentGreen.opacity(0.06) : Color.clear)
        .cornerRadius(5)
    }
}

// MARK: - Combo Group Card

private struct PDComboGroupCard: View {
    let groupIndex: Int
    let evals: [CleanupDebugInfo.VariantEval]
    @State private var expanded = true

    /// Double equality is safe here: values come from the same JSON decode with no intermediate arithmetic.
    private var winnerScore: Double? { evals.filter { !$0.is_original }.map(\.score).min() }

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Group \(groupIndex + 1)").font(.system(size: 12, weight: .semibold))
                    Text("· \(evals.count) variants").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                if expanded {
                    HStack(spacing: 0) {
                        Text("TEXT").frame(maxWidth: .infinity, alignment: .leading)
                        Text("SUM Score").frame(width: 90, alignment: .trailing)
                        Text("AVG Score").frame(width: 80, alignment: .trailing)
                        Text("CHOICES").frame(width: 120, alignment: .trailing)
                    }
                    .font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                    .textCase(.uppercase).tracking(0.4).padding(.horizontal, 6)
                    Divider()
                    ForEach(Array(evals.enumerated()), id: \.offset) { _, eval in
                        PDComboRow(eval: eval, isWinner: !eval.is_original && eval.score == winnerScore)
                    }
                }
            }
        }
    }
}

private struct PDComboRow: View {
    let eval: CleanupDebugInfo.VariantEval
    let isWinner: Bool
    @State private var showTokens = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    if eval.is_original {
                        Image(systemName: "equal.circle").font(.system(size: 9)).foregroundColor(.secondary)
                    } else if isWinner {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundColor(scoringAccentGreen)
                    }
                    Text(verbatim: eval.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    if let tokens = eval.tokens, !tokens.isEmpty {
                        Button { withAnimation { showTokens.toggle() } } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8))
                                .rotationEffect(.degrees(showTokens ? 90 : 0))
                                .foregroundColor(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(String(format: "%.3f", eval.score))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isWinner ? scoringAccentGreen : .primary)
                    .fontWeight(isWinner ? .semibold : .regular)
                    .frame(width: 90, alignment: .trailing)
                Text("-").font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(verbatim: eval.choices.map { $0 == 1 ? "✓" : "✗" }.joined(separator: " "))
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 120, alignment: .trailing)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(isWinner ? scoringAccentGreen.opacity(0.06) : Color.clear)
            .cornerRadius(4)
            if showTokens, let tokens = eval.tokens, !tokens.isEmpty {
                ScoreTokenChipFlow(tokens: tokens, showScoreValues: true, spacing: 3, fontSize: 11)
                    .padding(.leading, 16).padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Score Token Row

private struct PDScoreRow: View {
    let label: String
    let tokens: [CleanupDebugInfo.TokenScore]
    let sumScore: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: label)
                .font(.system(size: 10)).foregroundColor(.secondary)
                .frame(width: 52, alignment: .trailing).padding(.top, 3)
            ScoreTokenChipFlow(tokens: tokens, showScoreValues: true, spacing: 3, fontSize: 11)
            VStack(alignment: .trailing, spacing: 2) {
                if let sum = sumScore { scorePill(label: "sum", value: sum, color: Color(red: 0.58, green: 0.21, blue: 0.30)) }
            }
        }
    }
}

// Token chips use ScoreTokenChipFlow / ScoreTokenChip from ScoringDebugComponents.swift

// MARK: - KWS Tab

private let kwsBlue = Color(red: 0.20, green: 0.55, blue: 0.95)

/// Per-term Layer A vs Layer B attribution for a rescore, derived from the
/// entry: a term gate-substituted from a `commonMistake` span came from
/// **Layer A**; a term already present in the raw ASR transcript came from
/// **Layer B** (the dictionary glossary in the Qwen3/Granite prompt made the
/// model emit it directly - cross-check the glossary in the Cleanup tab).
private struct KWSProvenanceSection: View {
    let entry: KWSDebugEntry

    private enum Source { case layerA(from: String), layerB }

    private func inTranscript(_ term: String) -> Bool {
        entry.transcript.range(
            of: "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b",
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private var rows: [(term: String, source: Source)] {
        entry.activeTerms.compactMap { term in
            if let m = entry.commonMistakeMatches.first(where: {
                $0.accepted == true
                    && $0.matchedTerm.caseInsensitiveCompare(term) == .orderedSame
            }) {
                return (term, .layerA(from: m.span))
            }
            return inTranscript(term) ? (term, .layerB) : nil
        }
    }

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recovered terms - layer attribution")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(rows, id: \.term) { row in
                    HStack(spacing: 6) {
                        switch row.source {
                        case .layerA(let span):
                            Text("Ⓐ").foregroundColor(ctcOrange).fontWeight(.bold)
                            Text(row.term).fontWeight(.medium)
                            Text("Layer A - gate-substituted from \"\(span)\"")
                                .foregroundColor(.secondary)
                        case .layerB:
                            Text("Ⓑ").foregroundColor(.blue).fontWeight(.bold)
                            Text(row.term).fontWeight(.medium)
                            Text("Layer B - in raw ASR output (prompt biasing)")
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .cornerRadius(6)
        }
    }
}

private struct KWSDebugTabView: View {
    @ObservedObject private var history = KWSDebugHistory.shared
    @State private var selectedEntryId: UUID?

    private var selectedEntry: KWSDebugEntry? {
        guard let id = selectedEntryId else { return history.entries.first }
        return history.entries.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            kwsSidebar
            Divider()
            VStack(spacing: 0) {
                kwsToolbar
                Divider()
                if let entry = selectedEntry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            KWSIOCard(entry: entry)
                            KWSProvenanceSection(entry: entry)
                            if !entry.activeKeywords.isEmpty {
                                KWSKeywordsCard(entry: entry)
                            }
                            if !entry.rawDetections.isEmpty {
                                KWSDetectionsSection(entry: entry)
                            }
                            if entry.didFireCommonMistake {
                                KWSCommonMistakesSection(entry: entry)
                            }
                            if !entry.gateEvaluations.isEmpty {
                                KWSGateEvaluationsSection(entry: entry)
                            }
                        }
                        .padding(16)
                    }
                    .id(entry.id)
                } else {
                    kwsEmptyState
                }
            }
        }
        .onChange(of: history.entries.first?.id) { _, newId in
            selectedEntryId = newId
        }
    }

    private var kwsSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Text("\(history.entries.count)")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if history.entries.isEmpty {
                Text("No results yet")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(history.entries) { entry in
                            KWSSidebarRow(entry: entry, isSelected: kwsIsSelected(entry))
                                .onTapGesture { selectedEntryId = entry.id }
                        }
                    }
                    .padding(.vertical, 4).padding(.horizontal, 4)
                }
            }
        }
        .frame(width: 200)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func kwsIsSelected(_ entry: KWSDebugEntry) -> Bool {
        if let id = selectedEntryId { return entry.id == id }
        return entry.id == history.entries.first?.id
    }

    private var kwsToolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundColor(kwsBlue)
            Text("Keyword Spotting").font(.system(size: 14, weight: .semibold))
            if let entry = selectedEntry {
                Text("·").foregroundColor(.secondary)
                if let err = entry.error {
                    Text("error: \(err)").font(.system(size: 12)).foregroundColor(.red)
                } else if entry.didReplace {
                    Text("replaced").font(.system(size: 12)).foregroundColor(scoringAccentGreen)
                } else if entry.didDetectRelevant {
                    Text("\(entry.relevantDetections.count) detected · no replacement")
                        .font(.system(size: 12)).foregroundColor(kwsBlue)
                } else if entry.didDetectAny {
                    Text("\(entry.rawDetections.count) raw · no term match")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    Text("no detection").font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
            Spacer()
            if let entry = selectedEntry {
                Text(kwsFmt.string(from: entry.date))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private let kwsFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private var kwsEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 32)).foregroundColor(.secondary)
            Text("No KWS data yet").font(.system(size: 14, weight: .medium))
            Text("Run a transcription with the Custom Dictionary enabled to see KWS results here.")
                .font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

// MARK: - KWS Sidebar Row

private struct KWSSidebarRow: View {
    let entry: KWSDebugEntry
    let isSelected: Bool

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private var badge: (text: String, color: Color) {
        if let _ = entry.error {
            return ("error", isSelected ? .white.opacity(0.8) : .red)
        } else if entry.didReplace {
            return ("replaced", isSelected ? .white.opacity(0.9) : scoringAccentGreen)
        } else if entry.didDetectRelevant {
            return ("detected", isSelected ? .white.opacity(0.9) : kwsBlue)
        } else if entry.didDetectAny {
            return ("no match", isSelected ? .white.opacity(0.7) : .secondary)
        } else {
            return ("miss", isSelected ? .white.opacity(0.6) : .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Self.fmt.string(from: entry.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(isSelected ? .white : .secondary)
            Text(verbatim: entry.transcript)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2).truncationMode(.tail)
            Text(badge.text)
                .font(.system(size: 9)).foregroundColor(badge.color)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? kwsBlue : Color.clear)
        .cornerRadius(5)
    }
}

// MARK: - KWS IO Card

private struct KWSIOCard: View {
    let entry: KWSDebugEntry
    @State private var appeared = false

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    pdRowLabel("input")
                    Text(verbatim: entry.transcript)
                        .font(.system(size: 13)).foregroundColor(.primary).textSelection(.enabled)
                }
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 5)
                .animation(.easeOut(duration: 0.2).delay(0.05), value: appeared)

                if entry.didReplace {
                    HStack(alignment: .top, spacing: 8) {
                        pdRowLabel("output")
                        Text(verbatim: entry.output)
                            .font(.system(size: 13)).foregroundColor(scoringAccentGreen).textSelection(.enabled)
                    }
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 5)
                    .animation(.easeOut(duration: 0.2).delay(0.12), value: appeared)

                    HStack(alignment: .top, spacing: 8) {
                        pdRowLabel("diff")
                        PDDiffText(ops: diff(text1: entry.transcript, text2: entry.output), fontSize: 13)
                    }
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 5)
                    .animation(.easeOut(duration: 0.2).delay(0.20), value: appeared)
                }

                if let err = entry.error {
                    HStack(alignment: .top, spacing: 8) {
                        pdRowLabel("error")
                        Text(verbatim: err).font(.system(size: 12)).foregroundColor(.red).textSelection(.enabled)
                    }
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 5)
                    .animation(.easeOut(duration: 0.2).delay(0.12), value: appeared)
                }
            }
        }
        .onAppear { withAnimation { appeared = true } }
    }
}

// MARK: - KWS Keywords Card

private struct KWSKeywordsCard: View {
    let entry: KWSDebugEntry

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Active KWS Keywords (\(entry.activeKeywords.count))")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                FlowLayout(spacing: 4) {
                    ForEach(entry.activeKeywords, id: \.self) { kw in
                        Text(verbatim: kw)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(kwsBlue)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(kwsBlue.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                if !entry.activeTerms.isEmpty {
                    Text("Terms: " + entry.activeTerms.map { "\"\($0)\"" }.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Common Mistakes Section

/// Distinct accent for substring-match (text-driven) candidates so they're
/// visually obvious vs. audio-driven KWS detections above.
private let commonMistakeAmber = Color(red: 0.91, green: 0.62, blue: 0.16)

private struct KWSCommonMistakesSection: View {
    let entry: KWSDebugEntry
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Known Confusions (\(entry.commonMistakeMatches.count))")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            ForEach(Array(entry.commonMistakeMatches.enumerated()), id: \.offset) { idx, match in
                KWSCommonMistakeCard(match: match)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .animation(.easeOut(duration: 0.25).delay(0.05 + Double(idx) * 0.06), value: appeared)
            }
        }
        .onAppear { withAnimation { appeared = true } }
    }
}

private struct KWSCommonMistakeCard: View {
    let match: CommonMistakeMatch

    private var didReplace: Bool { match.accepted == true }

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass")
                        .foregroundColor(commonMistakeAmber)
                        .font(.system(size: 14))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: "\"\(match.span)\"")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(commonMistakeAmber)
                                .textSelection(.enabled)
                            Text("→").font(.system(size: 11)).foregroundColor(.secondary)
                            Text(verbatim: "\"\(match.matchedTerm)\"")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(scoringAccentGreen)
                        }
                        Text("substring match · text-driven")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    statusBadge
                }

                if match.accepted == nil {
                    Divider()
                    Text("No Score trace - term has no proxy word, so the gate rejects without scoring.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Divider()
                    Text("Gate trace in the Gate Evaluations section below.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if match.accepted == nil {
            Text("NO PROXY")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        } else if didReplace {
            Text("REPLACED")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(scoringAccentGreen)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(scoringAccentGreen.opacity(0.1))
                .cornerRadius(4)
        } else {
            Text("REJECTED")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.red)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.red.opacity(0.1))
                .cornerRadius(4)
        }
    }
}

// MARK: - KWS Detections Section

private struct KWSDetectionsSection: View {
    let entry: KWSDebugEntry
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detections (\(entry.rawDetections.count))")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            ForEach(Array(entry.rawDetections.enumerated()), id: \.offset) { idx, det in
                KWSDetectionCard(detection: det, isRelevant: entry.relevantDetections.contains { $0.keyword == det.keyword })
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .animation(.easeOut(duration: 0.25).delay(0.05 + Double(idx) * 0.06), value: appeared)
            }
        }
        .onAppear { withAnimation { appeared = true } }
    }
}

private struct KWSDetectionCard: View {
    let detection: KWSDetectionResult
    let isRelevant: Bool

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: isRelevant ? "waveform.badge.checkmark" : "waveform.badge.exclamationmark")
                        .foregroundColor(isRelevant ? kwsBlue : .secondary)
                        .font(.system(size: 14))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: detection.keyword)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(isRelevant ? kwsBlue : .primary)
                            if let term = detection.matchedTerm {
                                Text("→").font(.system(size: 11)).foregroundColor(.secondary)
                                Text(verbatim: "\"\(term)\"")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(scoringAccentGreen)
                            } else {
                                Text("no term match")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(String(format: "%.2fs – %.2fs", detection.startSec, detection.endSec))
                                .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                            if let span = detection.originalSpan {
                                Text("·").foregroundColor(.secondary).font(.system(size: 10))
                                Text(verbatim: "span: \"\(span)\"")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    Spacer()

                    Text(isRelevant ? "RELEVANT" : "UNMATCHED")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(isRelevant ? kwsBlue : .secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((isRelevant ? kwsBlue : Color.secondary).opacity(0.1))
                        .cornerRadius(4)
                }

                // Gate decision is rendered in the Gate Evaluations section
                // - detections don't 1:1 map to gate evaluations, so this card
                // intentionally doesn't carry an inline trace.
            }
        }
    }
}

// MARK: - Gate Evaluations Section

/// Truth-of-record list of every Score gate evaluation the rescorer ran for this
/// rescore - one row per `DictionaryReplacement` that reached the gate. The
/// detections / common-mistakes sections above show audio-level / text-level
/// candidates that *fed* the rescorer; this section shows what the gate
/// actually decided. Multiple evaluations of the same term appear as multiple
/// rows because they ran against different `originalSpan`s.
private struct KWSGateEvaluationsSection: View {
    let entry: KWSDebugEntry
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gate Evaluations (\(entry.gateEvaluations.count))")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            ForEach(Array(entry.gateEvaluations.enumerated()), id: \.element.id) { idx, eval in
                GateEvaluationCard(evaluation: eval)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
                    .animation(.easeOut(duration: 0.25).delay(0.05 + Double(idx) * 0.06), value: appeared)
            }
        }
        .onAppear { withAnimation { appeared = true } }
    }
}

private struct GateEvaluationCard: View {
    let evaluation: GateEvaluation

    private var sourceLabel: String {
        switch evaluation.source {
        case .kws:           return "audio KWS"
        case .commonMistake: return "known confusion"
        }
    }

    var body: some View {
        PDCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "scope")
                        .foregroundColor(evaluation.trace.accepted ? scoringAccentGreen : .red)
                        .font(.system(size: 14))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: "\"\(evaluation.originalSpan)\"")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                            Text("→").font(.system(size: 11)).foregroundColor(.secondary)
                            Text(verbatim: "\"\(evaluation.termText)\"")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(scoringAccentGreen)
                        }
                        Text("source: \(sourceLabel)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text(evaluation.trace.accepted ? "ACCEPT" : "REJECT")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(evaluation.trace.accepted ? scoringAccentGreen : .red)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background((evaluation.trace.accepted ? scoringAccentGreen : Color.red).opacity(0.1))
                        .cornerRadius(4)
                }

                Divider()
                ScoreTraceView(trace: evaluation.trace)
            }
        }
    }
}

/// Renders the exact strings + Scores the scoring gate evaluated. Use this
/// to confirm that no leading/trailing punctuation is leaking into the input.
private struct ScoreTraceView: View {
    let trace: NLLGateTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(label: "Original",
                text: trace.originalText,
                score: trace.originalNLL,
                color: .secondary,
                isWinner: false)
            // Render every variant. The winner is highlighted via Score color
            // and a "← won" marker; losers show in muted grey so it's obvious
            // the gate considered them but rejected.
            ForEach(Array(trace.variants.enumerated()), id: \.offset) { idx, variant in
                let isWinner = variant.label == trace.winningVariantLabel
                let label = isWinner
                    ? "Replaced (\(variant.label)) ← won"
                    : "Replaced (\(variant.label))"
                row(
                    label: label,
                    text: variant.text,
                    score: variant.nll,
                    color: isWinner && trace.accepted ? scoringAccentGreen : .secondary,
                    isWinner: isWinner
                )
            }
            HStack(spacing: 6) {
                Text("proxy: \"\(trace.proxyWord)\"")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("·").foregroundColor(.secondary).font(.system(size: 10))
                Text(String(format: "Δ_norm %.4f", trace.deltaNorm))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("·").foregroundColor(.secondary).font(.system(size: 10))
                Text(String(format: "thresh %.4f", trace.threshold))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("·").foregroundColor(.secondary).font(.system(size: 10))
                Text(trace.accepted ? "ACCEPT" : "REJECT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(trace.accepted ? scoringAccentGreen : .red)
            }
        }
    }

    private func row(label: String, text: String, score: Double, color: Color, isWinner: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: isWinner ? .bold : .semibold))
                .foregroundColor(isWinner ? scoringAccentGreen : .secondary)
                .frame(width: 168, alignment: .trailing)
            Text(verbatim: "\u{201C}\(text)\u{201D}")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.3f Score", score))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(color)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.1))
                .cornerRadius(4)
        }
    }
}

// MARK: - Shared Helpers

private func scorePill(label: String, value: Double, color: Color) -> some View {
    HStack(spacing: 2) {
        Text(label).font(.system(size: 8, weight: .bold))
        Text(String(format: "%.3f", value)).font(.system(size: 9, design: .monospaced))
    }
    .foregroundColor(color)
    .padding(.horizontal, 5).padding(.vertical, 1)
    .background(color.opacity(0.12)).cornerRadius(8)
}

private struct PDCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}

#endif

#endif // canImport(TranscriptionCleanup)
