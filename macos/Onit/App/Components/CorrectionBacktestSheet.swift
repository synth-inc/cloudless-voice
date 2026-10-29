// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  CorrectionBacktestSheet.swift
//  Onit
//
//  The correction-backtest flow: pick candidate ASR models (downloading any
//  that aren't installed), choose how many corrections to replay, see a time
//  estimate, then compare models in a benchmark-viewer-style results screen.
//

import SwiftUI

struct CorrectionBacktestSheet: View {

    // MARK: - Types

    /// Corrections that can actually be replayed (correction text saved and
    /// audio still on disk), newest first.
    private struct ReplayableInfo {
        /// Audio durations (seconds), newest first.
        let durations: [Double]
        var count: Int { durations.count }
    }

    // MARK: - Environments

    @Environment(\.dismiss) private var dismiss

    // MARK: - Observations

    @ObservedObject private var historyManager = TranscriptionHistoryManager.shared
    @ObservedObject private var transcriptionConfig = TranscriptionConfig.shared
    @ObservedObject private var downloadManager = ASRModelDownloadManager.shared
    @ObservedObject private var localization = LocalizationManager.shared

    // MARK: - States

    @StateObject private var runner = CorrectionBacktestRunner()

    @State private var selectedModelIds: Set<String> = []
    @State private var showCancelConfirmation = false
    @State private var isHoveredRunTest = false
    @State private var isPressedRunTest = false
    @State private var replayable: ReplayableInfo? = nil
    /// 0 = not yet initialized (set when `replayable` loads).
    @State private var caseCount: Int = 0
    /// Free-form case count entry; non-empty only while the user types one.
    @State private var customCountText: String = ""

    // MARK: - Private Variables

    private var currentModelId: String {
        transcriptionConfig.selectedASRModelId
    }

    /// Includes the current model so its accuracy on these cases can be
    /// compared directly against the candidates. Excludes models the current
    /// OS can't run (mirrors the Settings picker's `isAvailableForCurrentOS`
    /// filter), so macOS 14 users aren't offered MLX models they can't load.
    /// Already-downloaded models sort first (catalog order preserved within
    /// each group) so the models you can test right away aren't buried below
    /// ones that need a download first.
    private var candidateModels: [ASRModel] {
        let available = ASRModel.catalog.filter { $0.isAvailableForCurrentOS }
        let installed = available.filter { downloadManager.installState(for: $0) == .installed }
        let notInstalled = available.filter { downloadManager.installState(for: $0) != .installed }
        return installed + notInstalled
    }

    private var selectedModels: [ASRModel] {
        candidateModels.filter { selectedModelIds.contains($0.id) }
    }

    private var showingResults: Bool {
        runner.phase == .finished && !runner.results.isEmpty
    }

    /// Everything the user can replay in one run (`maxCases` is a far-off
    /// safety ceiling, not a UX limit).
    private var allCasesValue: Int {
        min(replayable?.count ?? 0, CorrectionBacktestRunner.maxCases)
    }

    private var presetCaseCounts: [Int] {
        [25, 50, 100].filter { $0 < allCasesValue }
    }

    /// Enough replayable corrections (audio on disk) to run a meaningful test.
    private var hasEnoughCases: Bool {
        (replayable?.count ?? 0) >= CorrectionBacktestRunner.minCases
    }

    /// Models that will be downloaded before the run starts.
    private var modelsNeedingDownload: [ASRModel] {
        selectedModels.filter { downloadManager.installState(for: $0) != .installed }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerView
            content
        }
        .padding(20)
        .frame(
            width: showingResults ? 760 : 460,
            height: showingResults ? 620 : 540
        )
        .background(Color.special1)
        .id(localization.currentLanguage)
        .task {
            await loadReplayableInfo()
        }
        .alert(
            String.localized("Cancel test?", table: "App"),
            isPresented: $showCancelConfirmation
        ) {
            Button(String.localized("No, stay", table: "App"), role: .cancel) {}
            Button(String.localized("Yes, cancel", table: "App"), role: .destructive) {
                // Don't dismiss - `runner.cancel()` flips `phase` to `.finished`
                // once the in-flight step notices, which routes `content` to
                // `resultsStep` with whatever cases already scored.
                runner.cancel()
            }
        } message: {
            Text(String.localized(
                "Your current test will be cancelled and return any available results",
                table: "App"
            ))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch runner.phase {
        case .idle:
            selectionStep
        case .downloading, .running:
            runningStep
        case .finished:
            if runner.results.isEmpty {
                selectionStep
            } else {
                resultsStep
            }
        case .failed(let message):
            failedStep(message)
        }
    }

    // MARK: - Private Functions

    private func loadReplayableInfo() async {
        let rows = await historyManager.fetchPaginated(
            limit: CorrectionBacktestRunner.maxCases,
            offset: 0,
            sortOrder: .newest,
            reviewStatus: .corrected
        )
        let durations = rows
            .filter { CorrectionBacktestRunner.isReplayable($0, historyManager: historyManager) }
            .map(\.audioDuration)

        replayable = ReplayableInfo(durations: durations)
        if caseCount == 0 {
            caseCount = min(50, allCasesValue)
        }
    }

    /// Coarse wall-clock estimate: total audio seconds in the run, scaled by
    /// a realtime factor per model speed rating, plus fixed per-step overhead.
    private func estimatedSeconds() -> Double {
        guard let replayable, caseCount > 0, !selectedModels.isEmpty else { return 0 }
        let audioSeconds = replayable.durations.prefix(caseCount).reduce(0, +)
        let modelFactorSum = selectedModels
            .map { Self.realtimeFactor(speedRating: $0.speedRating) }
            .reduce(0, +)
        let overhead = Double(caseCount * selectedModels.count) * 0.4
        return audioSeconds * modelFactorSum + overhead
    }

    private static func realtimeFactor(speedRating: Int) -> Double {
        switch speedRating {
        case 4: return 0.3
        case 3: return 0.5
        case 2: return 0.8
        case 1: return 1.2
        default: return 1.6
        }
    }

    private var estimateText: String {
        let seconds = estimatedSeconds()
        if seconds <= 0 { return "" }
        if seconds < 60 {
            return String.localized("Estimated run: under a minute", table: "App")
        }
        let minutes = Int((seconds / 60).rounded(.up))
        return String.localized("Estimated run: ~%@ min", table: "App", String(minutes))
    }

    // MARK: - Child Components: Header

    private var headerView: some View {
        HStack {
            Text(String.localized("Test models on your corrections", table: "App"))
                .styleText(
                    fontFamily: .libreBaskerville,
                    size: 18,
                    weight: .regular
                )
            Spacer()
            closeButton
        }
    }

    /// Closing mid-run would silently drop progress, so it's gated behind a
    /// confirmation there; everywhere else (idle, finished, failed) there's
    /// nothing in flight to lose, so it dismisses immediately.
    private var closeButton: some View {
        Button {
            if runner.phase == .running || runner.phase == .downloading {
                showCancelConfirmation = true
            } else {
                dismiss()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color.T_1)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 1: Model Selection

    private var selectionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String.localized(
                    "Select models and run a test to compare their word accuracy using your correct transcripts as a source of truth (fully local). This can help you find which model works best for your unique voice.",
                    table: "App"
                ))
                .styleText(size: 13, weight: .regular, color: Color.T_1)
                .fixedSize(horizontal: false, vertical: true)

            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(candidateModels) { model in
                        modelRow(model)
                    }
                }
            }

            caseCountSection
            runSummarySection
            selectionFooter
        }
    }

    private func modelRow(_ model: ASRModel) -> some View {
        let isSelected = selectedModelIds.contains(model.id)
        let isInstalled = downloadManager.installState(for: model) == .installed

        return Button {
            if isSelected {
                selectedModelIds.remove(model.id)
            } else {
                selectedModelIds.insert(model.id)
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? Color.info500 : Color.T_4)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(model.displayName)
                            .styleText(size: 13, weight: .medium)
                        if model.id == currentModelId {
                            Text(String.localized("Current", table: "App"))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(Color.T_2)
                                .padding(.horizontal, 5)
                                .frame(height: 15)
                                .background(Color.T_9)
                                .cornerRadius(5)
                        }
                    }
                    Text(model.shortDescription)
                        .styleText(size: 11, weight: .regular, color: Color.T_2)
                        .truncateText()
                }

                Spacer()

                if isInstalled {
                    Text(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
                        .styleText(size: 11, weight: .regular, color: Color.T_2)
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 10))
                        Text(String.localized(
                            "Will download · %@",
                            table: "App",
                            ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)
                        ))
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Color.T_2)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.T_9 : Color.clear)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 1: Case Count + Estimate

    @ViewBuilder
    private var caseCountSection: some View {
        if let replayable {
            if hasEnoughCases {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String.localized(
                        "Test on your most recent corrections (%@ available)",
                        table: "App",
                        String(replayable.count)
                    ))
                    .styleText(size: 12, weight: .regular, color: Color.T_2)

                    HStack(spacing: 6) {
                        ForEach(presetCaseCounts, id: \.self) { option in
                            caseCountChip(option, isAll: false)
                        }
                        caseCountChip(allCasesValue, isAll: true)
                        customCountField
                    }
                }
            } else {
                // Below the minimum: explain the gate. WER over a handful of
                // clips is noise, so we require a floor before running.
                Text(String.localized(
                    "Model testing needs at least %@ corrections with audio still on disk - you have %@. Correct more transcripts and they'll become testable.",
                    table: "App",
                    String(CorrectionBacktestRunner.minCases),
                    String(replayable.count)
                ))
                .styleText(size: 12, weight: .regular, color: Color.orange500)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func caseCountChip(_ option: Int, isAll: Bool) -> some View {
        let isSelected = caseCount == option && customCountText.isEmpty
        let label = isAll
            ? String.localized("All (%@)", table: "App", String(option))
            : String(option)

        return Button {
            caseCount = option
            customCountText = ""
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? Color.S_0 : Color.T_2)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(isSelected ? Color.T_9 : Color.clear)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.T_8 : Color.T_9, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// Free-form count, clamped to what's replayable. While the field holds a
    /// valid number it is the active choice; clearing it falls back to the
    /// last chip.
    private var customCountField: some View {
        let isActive = !customCountText.isEmpty

        return TextField(
            String.localized("Custom", table: "App"),
            text: $customCountText
        )
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .multilineTextAlignment(.center)
        .foregroundColor(isActive ? Color.S_0 : Color.T_2)
        .frame(width: 56, height: 26)
        .background(isActive ? Color.T_9 : Color.clear)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isActive ? Color.T_8 : Color.T_9, lineWidth: 1)
        )
        .onChange(of: customCountText) { _, newValue in
            let digits = newValue.filter(\.isNumber)
            if digits != newValue {
                customCountText = digits
                return
            }
            guard let entered = Int(digits), entered >= 1 else { return }
            let clamped = min(entered, allCasesValue)
            if clamped != entered {
                customCountText = String(clamped)
                return
            }
            caseCount = clamped
        }
    }

    @ViewBuilder
    private var runSummarySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !modelsNeedingDownload.isEmpty {
                let totalBytes = modelsNeedingDownload.map(\.sizeBytes).reduce(0, +)
                Text(String.localized(
                    "%@ will download first (%@)",
                    table: "App",
                    modelsNeedingDownload.map(\.displayName).joined(separator: ", "),
                    ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                ))
                .styleText(size: 11, weight: .regular, color: Color.orange500)
                .fixedSize(horizontal: false, vertical: true)
            }

            if hasEnoughCases, caseCount < CorrectionBacktestRunner.minCases {
                Text(String.localized(
                    "Test at least %@ corrections for a meaningful comparison.",
                    table: "App",
                    String(CorrectionBacktestRunner.minCases)
                ))
                .styleText(size: 11, weight: .regular, color: Color.orange500)
            } else if !selectedModels.isEmpty, !estimateText.isEmpty {
                let longRun = estimatedSeconds() > 600
                Text(estimateText + (longRun
                    ? " - " + String.localized("this could take a while; you can cancel anytime", table: "App")
                    : ""))
                .styleText(
                    size: 11,
                    weight: .regular,
                    color: longRun ? Color.orange500 : Color.T_2
                )
            }
        }
    }

    private var selectionFooter: some View {
        HStack {
            Text(selectionCountText)
                .styleText(size: 12, weight: .regular, color: Color.T_2)

            Spacer()

            Text(String.localized("Run test", table: "App"))
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.S_0)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .addButtonEffects(
                    background: Color.T_9,
                    hoverBackground: Color.T_8,
                    cornerRadius: 9,
                    disabled: !canRun,
                    shouldFadeOnDisabled: false,
                    allowsHitTesting: canRun,
                    isHovered: $isHoveredRunTest,
                    isPressed: $isPressedRunTest
                ) {
                    let models = selectedModels
                    let limit = caseCount
                    Task { await runner.start(models: models, caseLimit: limit) }
                }
                .opacity(canRun ? 1 : 0.6)
        }
    }

    /// Need a model, enough replayable corrections overall, and a chosen count
    /// that itself meets the minimum (a small custom number can dip below it).
    private var canRun: Bool {
        !selectedModelIds.isEmpty
            && hasEnoughCases
            && caseCount >= CorrectionBacktestRunner.minCases
    }

    private var selectionCountText: String {
        if selectedModelIds.count == 1 {
            return String.localized("1 model selected", table: "App")
        } else {
            return String.localized("\(selectedModelIds.count) models selected", table: "App")
        }
    }

    // MARK: - Step 2: Downloading / Running

    private var runningStep: some View {
        VStack(alignment: .center, spacing: 14) {
            Spacer()

            if runner.phase == .downloading {
                ProgressView(value: runner.downloadFraction)
                    .progressViewStyle(.linear)
                    .frame(width: 260)

                Text(String.localized(
                    "Downloading %@ · %@%%",
                    table: "App",
                    runner.currentModelName,
                    String(Int((runner.downloadFraction * 100).rounded()))
                ))
                .styleText(size: 12, weight: .regular, color: Color.T_2)
            } else {
                ProgressView(
                    value: Double(runner.completedSteps),
                    total: Double(max(runner.totalSteps, 1))
                )
                .progressViewStyle(.linear)
                .frame(width: 260)

                Text(String.localized(
                    "Testing %@ · %@ of %@",
                    table: "App",
                    runner.currentModelName,
                    String(runner.completedSteps),
                    String(runner.totalSteps)
                ))
                .styleText(size: 13, weight: .regular, color: Color.T_2, align: .center)
            }

            Button(String.localized("Cancel", table: "App")) {
                runner.cancel()
            }
            .buttonStyle(.plain)
            .foregroundColor(Color.info500)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 3: Results

    private var resultsStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !runner.skippedModels.isEmpty {
                Text(String.localized(
                    "Couldn't download: %@",
                    table: "App",
                    runner.skippedModels.joined(separator: ", ")
                ))
                .styleText(size: 13, weight: .regular, color: Color.orange500)
            }

            CorrectionBacktestResultsView(
                runner: runner,
                models: runner.testedModels
            )
        }
    }

    // MARK: - Failure

    private func failedStep(_ message: String) -> some View {
        VStack(alignment: .center, spacing: 8) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18))
                .foregroundColor(Color.orange500)
            Text(message)
                .styleText(size: 13, weight: .regular, color: Color.T_2, align: .center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
