// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsSmartFormatting.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-02-24.
//

import Defaults
import SwiftUI
#if canImport(TranscriptionCleanup)
import TranscriptionCleanup
#endif

struct SettingsSmartFormatting: View {
    // MARK: - Observations

    @ObservedObject private var transcriptionConfig = TranscriptionConfig.shared
    @ObservedObject private var triggersManager = SmartFormattingTriggersManager.shared
    @ObservedObject private var scoringProvider = ScoringWarmupProvider.shared
    @ObservedObject private var warmupCoordinator = WarmupCoordinator.shared

    /// The selected perplexity-scoring model (see `ScoringModel`). Changing it
    /// swaps the language-specialized model the cleanup pipeline scores with.
    @Default(.selectedScoringModelId) private var selectedScoringModelId
    /// PRO: user-added custom scoring models. Observed so the picker + list refresh.
    @Default(.customScoringModels) private var customScoringModels

    // MARK: - Custom-model add flow (PRO)
    @State private var newModelRepo: String = ""
    @State private var addModelError: String?
    @State private var isValidatingModel = false
    /// Advanced model controls (language-specialized picker + custom Pro models)
    /// are collapsed behind a caret so average users only see the model status.
    @State private var showAdvancedModelSettings = false
    
    // MARK: - Private Variables
    
    private let numberFormattingStyles: [(label: String, tag: String)] = [
        ("3,206", "with_comma"),
        // TODO: LOYD: - Update "without_comma" to "without_separator".
        ///     Previously, we only supported "with comma" and "without comma". The "with dot" option was added later on.
        ///     To make the transition smooth for now, we decided to keep "without comma", but it should eventually be updated to "without separator" for improved semantics.
        ("3206", "without_comma")
    ]

    // MARK: - Body

    var body: some View {
        Group {
            SettingsTitleView(
                text: String.localized("Smart Cleanup ensures your final transcript is clean and correctly formatted. Cloudless understands when you’re giving a formatting instruction and when you’re just speaking normally.", table: "Settings")
            )

            // The toggle can't be turned on in a fully open build (it snaps back to off).
            if SmartCleanupAvailability.isCompiledIn {
                masterToggleSection
            }

            // Fully open build only: Smart Cleanup is in the official app. The
            // categories below need it, and stay hidden since it can't be selected.
            SmartCleanupUnavailableSection()

            if transcriptionConfig.smartFormattingEnabled {
                engineModelSection
                backtrackingSection
                punctuationSection
                emojiSection
                formattingSection
                removeFillerWordsSection
                formatEmailsUrlsSection
                emailLayoutSection
                removeDuplicatesSection
                formatNumbersSection
            }
        }
        .task {
            await triggersManager.fetchDefaults()
        }
    }

    // MARK: - Child Components: Master Toggle Section

    /// Smart Cleanup on or off. The categories below are its. The user's own
    /// model is the Rewrite stage, on its own page (`SettingsRewrite`).
    private var masterToggleSection: some View {
        SmartCleanupToggleSection {
            instructionTextView
        }
    }
    
    private var instructionTextView: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Toggle categories on or off, and customize trigger words for each.", table: "Settings")
            )
        )
    }

    // MARK: - Child Components: Engine Model Section

    /// Hidden entirely where MLX cannot run (Intel - see `MLXRuntime`): every
    /// control in here drives the scoring model, which never loads there. Left
    /// visible it would show a blank status row (`isWarmedUp`, `isScoringLoading`
    /// and `errorMessage` are all false/nil), a Retry button pointing at a
    /// provider that is no longer registered, and a picker whose `.onChange`
    /// downloads ~1.25 GB before `ensureLoaded()` throws. Smart Cleanup itself
    /// keeps working - its deterministic generators need no model, so there is
    /// simply no model status to report.
    @ViewBuilder
    private var engineModelSection: some View {
        if MLXRuntime.isSupported {
            SettingsPageSection {
                modelStatus

                DividerHorizontal()

                // Language-model picker + custom (Pro) models are power-user controls.
                // Keep them behind an "Advanced" caret so average users aren't shown
                // model selection / HuggingFace repo entry by default.
                DisclosureGroup(
                    isExpanded: $showAdvancedModelSettings,
                    content: {
                        VStack(alignment: .leading, spacing: 0) {
                            scoringModelPicker
                            addCustomModelSection
                        }
                    },
                    label: {
                        Button {
                            withAnimation { showAdvancedModelSettings.toggle() }
                        } label: {
                            Text(String.localized("Advanced", table: "Settings"))
                                .styleText(size: 12)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                )
            }
        }
    }

    /// PRO: add any MLX-format HuggingFace model as a scoring model. Validates the
    /// repo (rejects GGUF / LoRA adapters / non-MLX) before downloading.
    private var addCustomModelSection: some View {
        SettingsPageSubsection(
            horizontal: .init(spacing: 8),
            header: .init(
                title: String.localized("Add a custom model (Pro)", table: "Settings"),
                subtitle: String.localized(
                    "Paste any MLX-format HuggingFace model id. GGUF and LoRA adapters aren't supported.",
                    table: "Settings"
                )
            )
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField(
                        "e.g. mlx-community/Qwen2.5-1.5B-Instruct-8bit",
                        text: $newModelRepo
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .disabled(isValidatingModel)
                    .onSubmit { Task { await addCustomModel() } }

                    Button(isValidatingModel
                           ? String.localized("Checking…", table: "Settings")
                           : String.localized("Add", table: "Settings")) {
                        Task { await addCustomModel() }
                    }
                    .disabled(isValidatingModel
                              || newModelRepo.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let addModelError {
                    Text(addModelError)
                        .styleText(size: 11, weight: .regular, color: Color.red500)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Installed custom models, with a remove button each.
                ForEach(customScoringModels) { model in
                    HStack(spacing: 6) {
                        Image(systemName: "cube.box")
                            .font(.system(size: 10))
                            .foregroundColor(Color.T_2)
                        Text(model.hfRepo)
                            .styleText(size: 11, weight: .regular, color: Color.T_1)
                            .truncateText()
                        Spacer()
                        Button {
                            ScoringModel.removeCustom(id: model.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(Color.T_2)
                        }
                        .buttonStyle(.plain)
                        .help(String.localized("Remove", table: "Settings"))
                    }
                }
            }
        }
    }

    /// Validate the pasted repo id, then (if MLX) add it, select it, and kick the
    /// download + reload. Surfaces a clear inline error for non-MLX repos.
    private func addCustomModel() async {
        let repo = newModelRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return }
        isValidatingModel = true
        addModelError = nil
        defer { isValidatingModel = false }

        let check = await HuggingFaceModelDownloader.shared.inspectMLXModelRepo(repo)
        switch check {
        case .ok(let sizeMB):
            let model = ScoringModel.makeCustom(hfRepo: repo, sizeMB: sizeMB)
            ScoringModel.addCustom(model)
            newModelRepo = ""
            // Selecting the model fires the picker's onChange, which downloads +
            // warms the new weights. Do NOT also call switchToSelectedModel() here:
            // the second reset()+warmup() races the first (teardown mid-load, and a
            // redundant multi-GB re-download).
            selectedScoringModelId = model.id
        default:
            addModelError = check.errorMessage
        }
    }

    /// Language picker for the perplexity-scoring model. Switching downloads the
    /// selected model (if not cached) and reloads the engine. Defaults to the
    /// English Llama; language-specialized entries (e.g. Romanian) live in
    /// `ScoringModel.all`.
    private var scoringModelPicker: some View {
        SettingsPageSubsection(
            horizontal: .init(spacing: 8),
            header: .init(
                title: String.localized("Language model", table: "Settings"),
                subtitle: String.localized(
                    "Pick a model tuned for your language for better cleanup accuracy.",
                    table: "Settings"
                )
            )
        ) {
            Picker("", selection: $selectedScoringModelId) {
                ForEach(ScoringModel.all) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
            .onChange(of: selectedScoringModelId) { _, _ in
                Task { await scoringProvider.switchToSelectedModel() }
            }
        }
    }

    private var isScoringLoading: Bool {
        scoringProvider.isEnabled && !scoringProvider.isWarmedUp
    }

    private var modelStatus: some View {
        SettingsPageSubsection(
            horizontal: .init(
                spacing: 8
            ),
            header: .init(
                title: String.localized("Cleanup Model", table: "Settings"),
                subtitle: "Llama 3.2 1B"
            )
        ) {
            if scoringProvider.isWarmedUp {
                Text(String.localized("Ready", table: "Settings"))
                    .styleText(size: 12)
                    .foregroundStyle(.green)
            } else if isScoringLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let error = scoringProvider.errorMessage {
                HStack(spacing: 6) {
                    Text(error)
                        .styleText(size: 11)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    Button {
                        warmupCoordinator.retryWarmup(for: scoringProvider.identifier)
                    } label: {
                        Text(String.localized("Retry", table: "Settings"))
                            .styleText(size: 11)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Child Components: Backtracking Section

    /// Hidden where MLX cannot run, for the same reason as `engineModelSection`:
    /// backtracking consumes the improvement LLM, so on Intel the toggle can
    /// never do anything and `BacktrackingSection`'s status row falls through to
    /// its `else` branch and spins a `ProgressView` forever
    /// (`ImprovementLLMWarmupProvider.isEnabled` is false, so `isWarmedUp` never
    /// flips and `errorMessage` stays nil).
    @ViewBuilder
    private var backtrackingSection: some View {
        if MLXRuntime.isSupported {
            BacktrackingSection(isEnabled: $transcriptionConfig.sfBacktrackingEnabled)
        }
    }

    // MARK: - Child Components: Punctuation Section

    private var punctuationSection: some View {
        SmartFormattingCategorySection(
            title: String.localized("Insert Punctuation & Special Characters", table: "Settings"),
            subtitle: String.localized("Speak punctuation like \"comma\" or \"exclamation mark\" to insert symbols.", table: "Settings"),
            category: .punctuation,
            isEnabled: $transcriptionConfig.sfPunctuationEnabled
        )
    }

    // MARK: - Child Components: Emoji Section

    // Toggle + collapsible "Customize Triggers" disclosure showing the full
    // spoken name -> glyph dictionary, with add/override/revert. Backed by
    // `EmojiTriggersManager` (defaults from `EmojiTriggers` + user overrides).
    //
    // The subtitle names both word orders because the generator matches both:
    // describing only the suffix form would hide half the feature from a French
    // user, whose recognizer favours "smiley feu".
    private var emojiSection: some View {
        EmojiTriggersSection(
            title: String.localized("Insert Emoji", table: "Settings"),
            subtitle: String.localized("Say an emoji's name next to a trigger word, like \"fire emoji\" or \"smiley fire\", to insert the glyph.", table: "Settings"),
            isEnabled: $transcriptionConfig.sfEmojiEnabled
        )
    }

    // MARK: - Child Components: Formatting Section

    private var formattingSection: some View {
        SmartFormattingCategorySection(
            title: String.localized("Create List & Paragraph Formatting", table: "Settings"),
            subtitle: String.localized("Create bullet lists, new paragraphs, and numbered lists with voice.", table: "Settings"),
            category: .formatting,
            isEnabled: $transcriptionConfig.sfFormattingEnabled
        )
    }

    // MARK: - Child Components: Remove Filler Words Section

    private var removeFillerWordsSection: some View {
        SmartFormattingCategorySection(
            title: String.localized("Remove Filler Words", table: "Settings"),
            subtitle: String.localized("Exclude fillers like \"um\" and \"uh\".", table: "Settings"),
            category: .fillers,
            isEnabled: $transcriptionConfig.sfFillersEnabled
        )
    }

    // MARK: - Child Components: Format Emails & URLs Section

    private var formatEmailsUrlsSection: some View {
        SettingsPageSection {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Format Emails & URLs", table: "Settings"),
                    subtitle: String.localized("Correctly format email addresses and website links.", table: "Settings")
                ),
                isOn: $transcriptionConfig.sfEmailsUrlsEnabled
            )
        }
    }

    // MARK: - Child Components: Email Layout Section

    /// The layout generator only ships English greeting / sign-off patterns, so
    /// it is a no-op whenever the pipeline runs with the French locale.
    /// `cleanupLocale` is the exact value `buildSwiftPipelineConfig()` hands the
    /// pipeline, so the toggle greys out on precisely the states where flipping
    /// it would change nothing.
    private var isEmailLayoutAvailable: Bool {
        transcriptionConfig.cleanupLocale != .french
    }

    // Distinct from `formatEmailsUrlsSection` above: that one formats an email
    // ADDRESS, this one lays an email MESSAGE out over several lines.
    //
    // Greyed rather than hidden where the locale rules it out, with the subtitle
    // swapped to name the reason - same convention as "Streaming Transcription
    // (BETA)" in `SettingsTranscriptionBehavior`.
    private var emailLayoutSection: some View {
        SettingsPageSection {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Format Email Layout", table: "Settings"),
                    subtitle: isEmailLayoutAvailable
                        ? String.localized("Add line breaks around greetings and sign-offs in email apps like Mail, Outlook and Gmail. English only.", table: "Settings")
                        : String.localized("Email layout is English only, so it stays off while your dictation language is French.", table: "Settings")
                ),
                // Show it off where it cannot act: the stored value may well
                // be true, and a lit switch under a subtitle saying the layout
                // stays off is a contradiction the user has to resolve alone.
                isOn: isEmailLayoutAvailable
                    ? $transcriptionConfig.sfEmailLayoutEnabled
                    : .constant(false)
            )
            .settingsUnavailable(!isEmailLayoutAvailable)

            // Customization: which words open / close an email, and which apps
            // and sites count as an email composer. Shown only where the layout
            // can act and is on.
            if isEmailLayoutAvailable && transcriptionConfig.sfEmailLayoutEnabled {
                DividerHorizontal()
                EmailTermListSection(
                    title: String.localized("Customize greetings", table: "Settings"),
                    addPlaceholder: String.localized("Add a greeting (e.g. \"sup\")", table: "Settings"),
                    list: .greetings
                )
                DividerHorizontal()
                EmailTermListSection(
                    title: String.localized("Customize sign-offs", table: "Settings"),
                    addPlaceholder: String.localized("Add a sign-off (e.g. \"peace\")", table: "Settings"),
                    list: .signOffs
                )
                DividerHorizontal()
                EmailTermListSection(
                    title: String.localized("Email apps", table: "Settings"),
                    addPlaceholder: String.localized("Add an app bundle id", table: "Settings"),
                    list: .composerApps,
                    usesAppPicker: true,
                    help: String.localized("Email layout is only applied while you're dictating in one of these apps. Add the ones you write email in, or turn off any you don't.", table: "Settings")
                )
                DividerHorizontal()
                EmailTermListSection(
                    title: String.localized("Email sites", table: "Settings"),
                    addPlaceholder: String.localized("Add a site (e.g. \"mail.proton.me\")", table: "Settings"),
                    list: .composerHosts,
                    help: String.localized("Email layout is only applied while you're dictating on one of these sites. Add the webmail sites you use, or turn off any you don't.", table: "Settings")
                )
            }
        }
    }

    // MARK: - Child Components: Remove Duplicates Section

    private var removeDuplicatesSection: some View {
        SettingsPageSection {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Remove Duplicates", table: "Settings"),
                    subtitle: String.localized("Remove accidental word repetitions and stutters.", table: "Settings")
                ),
                isOn: $transcriptionConfig.sfDuplicatesEnabled
            )
        }
    }

    // MARK: - Child Components: Format Numbers Section

    private var formatNumbersSection: some View {
        SettingsPageSection {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Format Numbers & Digit Sequences", table: "Settings"),
                    subtitle: String.localized("Saying \"one five double two six\" becomes 15226, and \"three thousand two hundred six\" becomes 3,206.", table: "Settings")
                ),
                isOn: $transcriptionConfig.sfNumbersEnabled
            )

            if transcriptionConfig.sfNumbersEnabled {
                DividerHorizontal()

                // Number formatting style
                HStack {
                    Text(String.localized("Formatting Style", table: "Settings"))
                        .styleText(size: 12)

                    Spacer()

                    Picker("", selection: $transcriptionConfig.sfNumberStyle) {
                        ForEach(Array(numberFormattingStyles.enumerated()), id: \.offset) { _, formattingStyle in
                            Text(formattingStyle.label)
                                .tag(formattingStyle.tag)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                DividerHorizontal()

                // Abbreviate large numbers
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String.localized("Abbreviate Large Numbers", table: "Settings"))
                            .styleText(size: 12)
                        Text(String.localized("E.g. \"5 million\" becomes \"5M\".", table: "Settings"))
                            .styleText(size: 11)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $transcriptionConfig.sfAbbreviateLargeNumbers)
                        .toggleStyle(.switch)
                }
            }
        }
    }

}
