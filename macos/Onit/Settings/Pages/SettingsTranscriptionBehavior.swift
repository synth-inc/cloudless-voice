// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SettingsTranscriptionBehavior.swift
//  Onit
//
//  Created by Kévin Naudin on 01/08/2026.
//

import Defaults
import KeyboardShortcuts
import SwiftUI

private typealias TranscriptionConfigKeys = Defaults.Keys.TranscriptionConfigKeys

struct SettingsTranscriptionBehavior: View {
    // MARK: - Defaults

    @Default(.transcriptionEnabled) private var transcriptionEnabled
    @Default(.transcriptionHistoryEnabled) private var historyEnabled
    @Default(TranscriptionConfigKeys.shortcutType) private var shortcutType
    @Default(TranscriptionConfigKeys.customShortcutCount) private var customShortcutCount
    @Default(TranscriptionConfigKeys.alternateSlotTypes) private var alternateSlotTypes
    @Default(TranscriptionConfigKeys.handsFreeOnly) private var handsFreeOnly
    @Default(.transcriptionInputDevice) private var currentInputDevice
    @Default(.transcriptionAutoSwitchMicrophone) private var autoSwitchMicrophone
    @Default(.transcriptionDuckAudio) private var duckAudio
    @Default(.transcriptionSoundEffectsEnabled) private var soundEffectsEnabled
    @Default(.transcriptionSoundEffectsVolume) private var soundEffectsVolume
    @Default(TranscriptionConfigKeys.backend) private var asrBackend
    @Default(TranscriptionConfigKeys.mlxCacheLimitMB) private var mlxCacheLimitMB
    @Default(TranscriptionConfigKeys.asrInactivityUnloadMinutes) private var asrInactivityUnloadMinutes
    @Default(TranscriptionConfigKeys.asrOnScreenTermsEnabled) private var asrOnScreenTermsEnabled
    @Default(TranscriptionConfigKeys.asrTrieBoostEnabled) private var asrTrieBoostEnabled
    @Default(TranscriptionConfigKeys.asrOnScreenTermsUseAccessibility) private var asrOnScreenTermsUseAccessibility
    @Default(TranscriptionConfigKeys.asrTermMemoryEnabled) private var asrTermMemoryEnabled
    @Default(TranscriptionConfigKeys.asrTermMemoryTier2Enabled) private var asrTermMemoryTier2Enabled
    @Default(TranscriptionConfigKeys.asrTermMemoryRetentionDays) private var asrTermMemoryRetentionDays
    @Default(TranscriptionConfigKeys.asrTermMemoryAmbientEnabled) private var asrTermMemoryAmbientEnabled
    @Default(TranscriptionConfigKeys.asrDictionaryFormatMatchEnabled) private var asrDictionaryFormatMatchEnabled

    // MARK: - Observables

    @ObservedObject private var transcriptionManager = TranscriptionManager.shared
    @ObservedObject private var transcriptionConfig = TranscriptionConfig.shared
    @ObservedObject private var warmupCoordinator = WarmupCoordinator.shared
    @ObservedObject private var transcriptionHistoryManager = TranscriptionHistoryManager.shared
    @ObservedObject private var microphoneInputManager = MicrophoneInputManager.shared
    @ObservedObject private var featureFlagManager = FeatureFlagManager.shared
    @ObservedObject private var localization = LocalizationManager.shared
    // Without this, the AI Model dropdown wouldn't re-render after a download
    // completes in the sheet - `aiModelSection` filters by install state and
    // SwiftUI needs to know when that state map changes.
    @ObservedObject private var asrDownloadManager = ASRModelDownloadManager.shared
    
    // MARK: - States

    @State private var isExporting = false
    @State private var exportError: String? = nil
    
    @State private var showClearAllHistoryConfirmation = false
    @State private var clearAllHistoryError: String? = nil
    
    @State private var showClearCorrectionHistoryConfirmation = false
    @State private var clearAllCorrectionHistoryError: String? = nil

    @State private var showASRModelsSheet = false

    #if DEBUG || ONIT_BETA
    @State private var showEraseTermMemoryConfirmation = false
    #endif

    // MARK: - Shortcut Variables
    
    private var shortcutCaption: String {
        if handsFreeOnly {
            if shortcutType == .commandDoubleTap || shortcutType == .controlDoubleTap {
                return String.localized("Double-tap to start recording, double-tap to stop.", table: "Transcription")
            }
            return String.localized("Press once to start recording, press again to stop.", table: "Transcription")
        }
        if shortcutType.supportsHold {
            return String.localized("Hold to record, release to insert. Double-tap for hands-free mode.", table: "Transcription")
        } else {
            return String.localized("Double-tap to start recording. Double-tap again to insert.", table: "Transcription")
        }
    }


    // MARK: - Advanced Settings Variables
    
    private var modelStatusCaption: String {
        if transcriptionManager.isInitialized {
            return String.localized("Speech recognition model is ready to use.", table: "Transcription")
        } else if transcriptionManager.isInitializing || isActiveBackendWarmingUp {
            return String.localized("Downloading and loading the speech recognition model...", table: "Transcription")
        } else if let error = transcriptionManager.errorMessage {
            return String.localized("Error: %@", table: "Transcription", error)
        } else if let warmupError = parakeetCoreMLWarmupError {
            return String.localized("Error: %@", table: "Transcription", warmupError.localizedDescription)
        } else {
            return String.localized("Model will be loaded when dictation is enabled.", table: "Transcription")
        }
    }

    /// Whether the currently selected ASR backend is mid-warmup. Used by the
    /// Model Status pill so it shows "Loading…" right after the user picks a
    /// different model instead of stale-reporting the previous backend's "Ready".
    private var isActiveBackendWarmingUp: Bool {
        if case .warmingUp = warmupCoordinator.warmupState {
            return !ASRBackendRegistry.descriptor(for: transcriptionConfig.backend).isWarmedUp
        }
        return false
    }

    /// Get warmup error for the active ASR backend (from per-provider tracking)
    private var parakeetCoreMLWarmupError: WarmupError? {
        let providerIdentifier = ASRBackendRegistry.descriptor(for: transcriptionConfig.backend).providerId
        return warmupCoordinator.failedProviders[providerIdentifier]
    }

    /// Whether the current ASR backend supports chunked-streaming transcription.
    /// Only Parakeet CoreML and the MLX/Qwen backend decode per-segment context;
    /// the other engines silently stay single-shot, so the toggle is disabled.
    /// Reads the registry descriptor so a future streaming backend that opts in
    /// via `supportsChunkedStreaming` is picked up here automatically.
    private var isChunkCapableBackend: Bool {
        ASRBackendRegistry.descriptor(for: transcriptionConfig.backend).supportsChunkedStreaming
    }
    
    // MARK: - Advanced Settings Variables: Language Section
    
    private static let autoDetectLanguageCode = "auto"
    
    /// Supported languages for the Parakeet multilingual model (ISO 639-1 codes).
    /// Each entry has a stable UUID for SwiftUI identity tracking.
    private static let supportedLanguages: [(code: String, name: String, id: UUID)] = {
        let languages: [(String, String)] = [
            (Self.autoDetectLanguageCode, String.localized("Auto-detect", table: "Transcription")),
            ("bg", String.localized("Bulgarian", table: "Transcription")),
            ("hr", String.localized("Croatian", table: "Transcription")),
            ("cs", String.localized("Czech", table: "Transcription")),
            ("da", String.localized("Danish", table: "Transcription")),
            ("nl", String.localized("Dutch", table: "Transcription")),
            ("en", String.localized("English", table: "Transcription")),
            ("et", String.localized("Estonian", table: "Transcription")),
            ("fi", String.localized("Finnish", table: "Transcription")),
            ("fr", String.localized("French", table: "Transcription")),
            ("de", String.localized("German", table: "Transcription")),
            ("el", String.localized("Greek", table: "Transcription")),
            ("hu", String.localized("Hungarian", table: "Transcription")),
            ("it", String.localized("Italian", table: "Transcription")),
            ("lv", String.localized("Latvian", table: "Transcription")),
            ("lt", String.localized("Lithuanian", table: "Transcription")),
            ("mt", String.localized("Maltese", table: "Transcription")),
            ("pl", String.localized("Polish", table: "Transcription")),
            ("pt", String.localized("Portuguese", table: "Transcription")),
            ("ro", String.localized("Romanian", table: "Transcription")),
            ("ru", String.localized("Russian", table: "Transcription")),
            ("sk", String.localized("Slovak", table: "Transcription")),
            ("sl", String.localized("Slovenian", table: "Transcription")),
            ("es", String.localized("Spanish", table: "Transcription")),
            ("sv", String.localized("Swedish", table: "Transcription")),
            ("uk", String.localized("Ukrainian", table: "Transcription")),
        ]
        return languages.map { code, name in
            let hexCode = code.utf8.map { String(format: "%02x", $0) }.joined()
            let padded = String(repeating: "0", count: max(0, 12 - hexCode.count)) + hexCode
            let uuidString = "00000000-0000-0000-0000-\(padded)"
            return (code: code, name: name, id: UUID(uuidString: uuidString) ?? UUID())
        }
    }()

    private static let languageOptions: [LanguageOption] = supportedLanguages
        .filter { $0.code != Self.autoDetectLanguageCode }
        .map { LanguageOption(code: $0.code, name: $0.name, id: $0.id) }

    private var languageButtonLabel: String {
        let selected = transcriptionConfig.transcriptionLanguages
        switch selected.count {
        case 0:
            return String.localized("Auto-detect", table: "Transcription")
        case 1:
            return Self.supportedLanguages.first { $0.code == selected[0] }?.name ?? selected[0]
        default:
            let displayed = selected.prefix(3).map { $0.uppercased() }.joined(separator: ", ")
            let remaining = selected.count - 3
            return remaining > 0 ? "\(displayed) +\(remaining)" : displayed
        }
    }
    
    // MARK: - Body

    var body: some View {
        Group {
            enableDictationSection
            shortcutSection
            microphoneSelectionSection
            advancedSettingsSection
            historySection

            #if DEBUG || ONIT_BETA
            devSection
            #endif
        }
        .onAppear {
            AnalyticsManager.Transcription.settingsOpened()

            // Deep-link from the App Home setup card's gear: open the "Browse all models…" sheet.
            if Defaults[.pendingOpenASRModelsSheet] {
                Defaults[.pendingOpenASRModelsSheet] = false
                showASRModelsSheet = true
            }
        }
        .sheet(isPresented: $showASRModelsSheet) {
            SettingsASRModelsPickerSheet()
        }
        .onChange(of: showASRModelsSheet) { _, isPresented in
            if isPresented {
                AnalyticsManager.AsrModel.pickerOpened()
            }
        }
        /// Delete All History Alert
        .alert(
            String.localized("Delete All History", table: "Transcription"),
            isPresented: $showClearAllHistoryConfirmation
        ) {
            Button(String.localized("No, Cancel", table: "Transcription"), role: .cancel) {}
            Button(String.localized("Delete All", table: "Transcription"), role: .destructive) {
                deleteAllTranscriptionHistory()
            }
        } message: {
            Text(String.localized("This will permanently delete all locally saved transcription history and audio files. This action cannot be undone.", table: "Transcription"))
        }
        /// Delete All History Failed Alert
        .alert(
            String.localized("Delete All History Failed", table: "Transcription"),
            isPresented: .init(
                get: { clearAllHistoryError != nil },
                set: { if !$0 { clearAllHistoryError = nil } }
            )
        ) {
            Button(String.localized("Cancel", table: "Transcription"), role: .cancel) {}
            Button(String.localized("Try again", table: "Transcription"), role: .destructive) {
                deleteAllTranscriptionHistory()
            }
        } message: {
            if let error = clearAllHistoryError {
                Text(error)
            }
        }
        /// Delete All Correction History Alert
        .alert(
            String.localized("Delete All Correction History", table: "Transcription"),
            isPresented: $showClearCorrectionHistoryConfirmation
        ) {
            Button(String.localized("No, Cancel", table: "Transcription"), role: .cancel) {}
            Button(String.localized("Delete All", table: "Transcription"), role: .destructive) {
                deleteAllCorrectedTranscriptionHistory()
            }
        } message: {
            Text(String.localized("This will permanently delete all locally saved corrected transcription history and audio files. This action cannot be undone.", table: "Transcription"))
        }
        /// Delete All Correction History Failed Alert
        .alert(
            String.localized("Delete All Correction History Failed", table: "Transcription"),
            isPresented: .init(
                get: { clearAllCorrectionHistoryError != nil },
                set: { if !$0 { clearAllCorrectionHistoryError = nil } }
            )
        ) {
            Button(String.localized("Cancel", table: "Transcription"), role: .cancel) {}
            Button(String.localized("Try again", table: "Transcription"), role: .destructive) {
                deleteAllCorrectedTranscriptionHistory()
            }
        } message: {
            if let error = clearAllCorrectionHistoryError {
                Text(error)
            }
        }
        #if DEBUG || ONIT_BETA
        /// Erase Term Memory Alert
        .alert(
            "Erase term memory",
            isPresented: $showEraseTermMemoryConfirmation
        ) {
            Button("No, Cancel", role: .cancel) {}
            Button("Erase", role: .destructive) {
                TermMemoryService.shared.eraseAll()
            }
        } message: {
            Text("This will permanently delete every term Cloudless Voice remembered, along with the aliases generated for them. This action cannot be undone.")
        }
        #endif
        /// Corrections History Export Failed Alert
        .alert(
            String.localized("Corrections Export Failed", table: "Transcription"),
            isPresented: .init(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ))
        {
            Button(String.localized("OK", table: "Transcription"), role: .cancel) {}
        } message: {
            if let error = exportError {
                Text(error)
            }
        }
        .id(localization.currentLanguage)
    }
    
    // MARK: - Child Components: Enable Dictation Section

    private var enableDictationSection: some View {
        SettingsPageSection {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Voice Dictation", table: "Settings"),
                    subtitle: String.localized("Real-time speech-to-text that types what you say, anywhere.", table: "Settings")
                ),
                isOn: $transcriptionEnabled
            )
        }
    }

    // MARK: - Child Components: Microphone Selection Section

    private var microphoneSelectionSection: some View {
        SettingsPageSection(title: .init(text: String.localized("Microphone Selection", table: "Transcription"))) {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Current Microphone", table: "Transcription"),
                    subtitle: String.localized("Select your preferred microphone.", table: "Transcription")
                ),
                dropdown: .init(
                    placeholder: microphoneInputManager.availableDevices.isEmpty
                        ? String.localized("No microphones found", table: "Transcription")
                        : String.localized("Select a microphone", table: "Transcription"),
                    options: microphoneInputManager.availableDevices.map { inputDevice in
                            .init(
                                id: UUID(),
                                name: inputDevice.name,
                                isSelected: inputDevice.id == currentInputDevice?.id,
                                action: {
                                    Task {
                                        await microphoneInputManager.setInputDevice(inputDevice.id)
                                    }
                                }
                            )
                    }
                )
            )

            DividerHorizontal()

            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Auto-switch to New Microphone", table: "Transcription"),
                    subtitle: String.localized("Automatically switch to a newly connected audio device (e.g. headphones).", table: "Transcription")
                ),
                isOn: $autoSwitchMicrophone
            )
        }
        .onAppear {
            microphoneInputManager.refreshAvailableDevicesAndAutoSelectIfNeeded(
                autoSelectInputDevice: currentInputDevice == nil
            )
        }
    }

    // MARK: - Child Components: Shortcut Section

    private var shortcutSection: some View {
        SettingsPageSection(title: .init(text: String.localized("Shortcuts", table: "Transcription"))) {
            SettingsPageSubsection(
                horizontal: .init(spacing: 8),
                header: .init(
                    title: String.localized("Shortcut", table: "Transcription"),
                    subtitle: shortcutCaption
                ),
                dropdown: .init(
                    placeholder: String.localized("Select a shortcut", table: "Transcription"),
                    options: TranscriptionShortcutType.allCases.map { type in
                            .init(
                                id: UUID(),
                                name: type == .custom ? String.localized("Custom", table: "Transcription") : type.displayName,
                                isSelected: type == shortcutType,
                                action: { selectShortcutOption(type) }
                            )
                    }
                )
            )

            customShortcutList
        }
    }

    /// Slot 0 is shown as an editable row only in `.custom` mode. For CapsLock/Fn the main trigger
    /// is fixed by the type, so the list only exposes alternate slots (1..count-1).
    private var firstVisibleSlotIndex: Int {
        shortcutType == .custom ? 0 : 1
    }

    /// Clamped slot count - guards against out-of-range values in Defaults (manual plist edits, stale state).
    private var clampedCustomShortcutCount: Int {
        min(max(customShortcutCount, 1), TranscriptionShortcutType.customShortcutMaxCount)
    }

    /// Type string for the alternate at the given slot index (1-based slot → 0-based alternateSlotTypes).
    private func alternateType(at slotIndex: Int) -> TranscriptionShortcutType {
        let altIndex = slotIndex - 1
        guard altIndex >= 0, altIndex < alternateSlotTypes.count,
              let type = TranscriptionShortcutType(rawValue: alternateSlotTypes[altIndex])
        else { return .custom }
        return type
    }

    /// Types already used across the main slot and all alternate slots.
    private var usedSpecialTypes: Set<TranscriptionShortcutType> {
        var used: Set<TranscriptionShortcutType> = [shortcutType]
        for i in 1..<clampedCustomShortcutCount {
            let t = alternateType(at: i)
            if t != .custom { used.insert(t) }
        }
        return used
    }

    /// Types that can still be added as alternates (special types only; custom can always be added).
    private var availableSpecialTypes: [TranscriptionShortcutType] {
        [.capsLock, .fn, .rightCommand, .commandDoubleTap, .controlDoubleTap].filter { !usedSpecialTypes.contains($0) }
    }

    private var customShortcutList: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // Special-type alternates (CapsLock, Fn) first.
            ForEach(firstVisibleSlotIndex..<clampedCustomShortcutCount, id: \.self) { index in
                let slotType = alternateType(at: index)
                if index > 0 && slotType != .custom {
                    HStack(spacing: 6) {
                        Text(slotType.displayName)
                            .styleText(size: 13, weight: .regular)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.T_8)
                            .cornerRadius(6)

                        Button(action: { removeCustomShortcut(at: index) }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(String.localized("Remove this shortcut", table: "Transcription"))
                    }
                }
            }

            // Custom keyboard shortcut rows (FunctionKeyRecorder) second.
            ForEach(firstVisibleSlotIndex..<clampedCustomShortcutCount, id: \.self) { index in
                let slotType = alternateType(at: index)
                if index == 0 || slotType == .custom {
                    HStack(spacing: 6) {
                        let canRemove = shortcutType == .custom ? clampedCustomShortcutCount > 1 : true
                        FunctionKeyRecorder(
                            shortcutName: TranscriptionShortcutType.customShortcutNames[index],
                            showClearButton: !canRemove  // show clear when remove button is hidden
                        )
                        .frame(minWidth: 80)

                        if canRemove {
                            Button(action: { removeCustomShortcut(at: index) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(String.localized("Remove this shortcut", table: "Transcription"))
                        }
                    }
                }
            }

            HStack {
                if shortcutType != .commandDoubleTap && shortcutType != .controlDoubleTap {
                    Toggle(isOn: Binding(
                        get: { handsFreeOnly },
                        set: { newValue in
                            handsFreeOnly = newValue
                            // Keep the vestigial hold-to-record key in sync so the
                            // single "Hands-free" switch stays authoritative:
                            // OFF → hold-to-talk, ON → press-to-toggle/hands-free.
                            Defaults[.transcriptionHoldToRecord] = !newValue
                            KeyboardShortcutsManager.cancelIfActive()
                            KeystrokeNotificationManager.shared.resetDoubleTapState()
                        }
                    )) {
                        Text(String.localized("Hands-free", table: "Transcription"))
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)
                    .fixedSize()
                }

                Spacer()

                if clampedCustomShortcutCount < TranscriptionShortcutType.customShortcutMaxCount {
                    Menu {
                        Button(String.localized("Custom shortcut", table: "Transcription")) {
                            addAlternate(type: .custom)
                        }
                        ForEach(availableSpecialTypes, id: \.self) { type in
                            Button(type.displayName) {
                                addAlternate(type: type)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text(String.localized("Add", table: "Transcription"))
                        }
                        .font(.system(size: 12))
                        .foregroundColor(Color.accentsBlue)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .id(clampedCustomShortcutCount)
    }

    // MARK: - Child Components: History Section
    
    private var historySection: some View {
        SettingsPageSection(title: .init(text: String.localized("History", table: "Transcription"))) {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Save Transcripts to History", table: "Transcription"),
                    subtitle: String.localized("Locally save your transcripts to history.", table: "Transcription")
                ),
                isOn: $historyEnabled
            )

            DividerHorizontal()

            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Delete Transcript History", table: "Transcription"),
                    subtitle: String.localized("Permanently delete all local transcripts and audio files.", table: "Transcription")
                )
            ) {
                SimpleButton(
                    disabled: transcriptionHistoryManager.historyCount == 0,
                    text: String.localized("Delete All", table: "Transcription"),
                    textColor: Color.redDelete,
                    cornerRadius: 6,
                    action: {
                        showClearAllHistoryConfirmation = true
                    },
                    background: Color.redDelete.opacity(0.25),
                    paddingHorizontal: 12
                )
            }

            DividerHorizontal()

            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Delete Corrected Transcript History", table: "Transcription"),
                    subtitle: String.localized("Permanently delete all local corrected transcripts and audio files.", table: "Transcription")
                )
            ) {
                SimpleButton(
                    disabled: transcriptionHistoryManager.correctedCount == 0,
                    text: String.localized("Delete All", table: "Transcription"),
                    textColor: Color.redDelete,
                    cornerRadius: 6,
                    action: {
                        showClearCorrectionHistoryConfirmation = true
                    },
                    background: Color.redDelete.opacity(0.25),
                    paddingHorizontal: 12
                )
            }

            DividerHorizontal()

            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Export Correction Data", table: "Transcription"),
                    subtitle: String.localized("Create a zip file with all local corrections and audio files.", table: "Transcription")
                )
            ) {
                if isExporting {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    SimpleButton(
                        disabled: transcriptionHistoryManager.correctedCount == 0,
                        text: String.localized("Export", table: "Transcription"),
                        textColor: Color.white,
                        cornerRadius: 6,
                        action: {
                            exportData()
                        },
                        background: Color.blue,
                        paddingHorizontal: 12
                    )
                }
            }
        }
    }
    
    // MARK: - Child Components: Advanced Settings Section

    private var advancedSettingsSection: some View {
        SettingsPageSection(title: .init(text: String.localized("Advanced Settings", table: "Transcription"))) {
            // AI Model first per Figma - it's the most surfaced control.
            aiModelSection
            DividerHorizontal()
            modelStatusSection
            DividerHorizontal()
            chunkedStreamingSection
            DividerHorizontal()
            if asrBackend == .mlx {
                autoDictionarySection
                DividerHorizontal()
                // Qwen3-only: the Granite adapter doesn't read trie staging, so
                // showing the toggle there would be a silent no-op (review
                // finding).
                if transcriptionConfig.selectedASRModelId.hasPrefix("qwen3-asr") {
                    trieBoostSection
                    DividerHorizontal()
                }
                #if DEBUG || ONIT_BETA
                // Source switch is dev-only for now: exposing the screenshot
                // path to external users needs a screen-recording permission
                // request flow we haven't built.
                if asrOnScreenTermsEnabled {
                    onScreenTermsSourceSection
                    DividerHorizontal()
                }
                // Persistent term memory: dev-flagged Phase 1 - no UI copy
                // pass yet.
                termMemorySection
                DividerHorizontal()
                // Outside the enabled branch on purpose: switching the feature
                // off leaves the store on disk, so erase has to stay reachable.
                termMemoryEraseSection
                DividerHorizontal()
                if asrTermMemoryEnabled {
                    termMemoryAmbientSection
                    DividerHorizontal()
                    termMemoryRetentionSection
                    DividerHorizontal()
                    termMemoryTier2Section
                    DividerHorizontal()
                }
                #endif
                gpuMemorySection
                DividerHorizontal()
            }
            modelUnloadSection
            DividerHorizontal()
            capitalizationSection
            DividerHorizontal()
            correctionModeSection
            DividerHorizontal()
            #if DEBUG || ONIT_BETA
            // Core pipeline (default on); dev-only kill switch.
            formatMatchSection
            DividerHorizontal()
            #endif
            languageSection
            DividerHorizontal()
            vadFilterSection
            DividerHorizontal()
            duckAudioSection
            DividerHorizontal()
            soundEffectsSection
            DividerHorizontal()
            onsetSilencePrependSection
        }
    }

    // MARK: - Child Components: Trie Boost Section

    /// EXPERIMENTAL decode-time dictionary boosting (Qwen3 only): dictionary
    /// terms bias token selection inside the decoder, fixing mishearings like
    /// "Calender" → "Kalender" before they happen. Opt-in for 4.4.
    private var trieBoostSection: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text(String.localized("Deep dictionary boost", table: "Transcription"))
                        .styleText(size: 13, weight: .regular, color: Color.S_0)
                    BetaTag()
                }
                Text(String.localized(
                    "Steers the speech model toward your dictionary words while it transcribes, so rare names and terms come out spelled right. Experimental; adds a small delay per dictation.",
                    table: "Transcription"
                ))
                .styleText(size: 12, weight: .regular, color: Color.T_1)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $asrTrieBoostEnabled)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Child Components: Term Memory (dev)

    /// EXPERIMENTAL persistent term memory (Phase 1, dev flag): remember
    /// screen-sighted and dictated terms across apps and days in a local
    /// ACT-R activation store, and bias every dictation with the top-K.
    /// DEBUG/BETA-only until the eval + promotion UI phases land.
    private var termMemorySection: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Persistent term memory")
                        .styleText(size: 13, weight: .regular, color: Color.S_0)
                    BetaTag()
                }
                Text("Remembers names and technical terms seen on screen or dictated, across apps and days, and uses them to spell your words correctly. Stored on-device as terms and counts only - never sentences.")
                    .styleText(size: 12, weight: .regular, color: Color.T_1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $asrTermMemoryEnabled)
                .toggleStyle(.switch)
        }
    }

    /// Always-on ambient capture - the standing-capture posture, so it gets
    /// its own opt-in switch and honest copy. Event-driven (focus changes
    /// only) with dwell + throttles; skips Low Power Mode and secure input.
    private var termMemoryAmbientSection: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Learn terms from every app")
                        .styleText(size: 13, weight: .regular, color: Color.S_0)
                    BetaTag()
                }
                Text("Pick up names and terms from the app you're using, even when you're not dictating. Checks the screen when you switch apps and periodically while you work, but only processes it when the content actually changed. Pauses when idle, in Low Power Mode, and in password fields. Text is reduced to terms on-device and discarded.")
                    .styleText(size: 12, weight: .regular, color: Color.T_1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $asrTermMemoryAmbientEnabled)
                .toggleStyle(.switch)
        }
    }

    /// Retention window: forget a remembered term once it hasn't been seen
    /// (on screen, dictated, or corrected) for the chosen period. "Never" is
    /// the default - ranking already demotes stale terms - so this is the
    /// user's privacy/hygiene control over the store's lifetime.
    private var termMemoryRetentionSection: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Forget unused terms")
                    .styleText(size: 13, weight: .regular, color: Color.S_0)
                Text("Remove a remembered term after it hasn't appeared on screen or in a dictation for this long.")
                    .styleText(size: 12, weight: .regular, color: Color.T_1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Picker("", selection: $asrTermMemoryRetentionDays) {
                Text("Never").tag(0)
                Text("After 6 months").tag(180)
                Text("After 1 year").tag(365)
                Text("After 2 years").tag(730)
                Text("After 5 years").tag(1825)
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
    }

    #if DEBUG || ONIT_BETA
    /// The only way, today, to see the store gone: the inspection UI is a
    /// later phase and retention defaults to "Never", so without this the
    /// captured terms have no user-facing exit.
    private var termMemoryEraseSection: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Erase term memory")
                    .styleText(size: 13, weight: .regular, color: Color.S_0)
                Text("Delete every remembered term and its generated aliases from this Mac. Dictation keeps working; it just starts learning again from scratch.")
                    .styleText(size: 12, weight: .regular, color: Color.T_1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            SimpleButton(
                text: "Erase",
                textColor: Color.redDelete,
                cornerRadius: 6,
                action: {
                    showEraseTermMemoryConfirmation = true
                },
                background: Color.redDelete.opacity(0.25),
                paddingHorizontal: 12
            )
        }
    }
    #endif

    /// Tier-2 gated fuzzy restore - separate switch because it rewrites final
    /// text (its own precision risk class).
    private var termMemoryTier2Section: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Term memory: fuzzy restore (tier 2)")
                        .styleText(size: 13, weight: .regular, color: Color.S_0)
                    BetaTag()
                }
                Text("After transcription, restore remembered terms the decoder still missed by sound-alike matching. Experimental.")
                    .styleText(size: 12, weight: .regular, color: Color.T_1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $asrTermMemoryTier2Enabled)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Child Components: Dictionary Prompt-Biasing Section

    /// Layer B of the dictionary: inject the user's custom-dictionary terms into
    /// the ASR model's prompt so it spells them correctly. Only Qwen3/Granite
    /// (the MLX backend) read the prompt; the toggle is hidden otherwise.
    /// Single user-facing switch for on-screen term mining. Prompt biasing of
    /// saved dictionary terms is core pipeline (asrDictionaryPromptEnabled
    /// default ON, no toggle) - this only controls reading the screen.
    private var autoDictionarySection: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text(String.localized("Auto-dictionary", table: "Transcription"))
                        .styleText(size: 13, weight: .regular, color: Color.S_0)
                    BetaTag()
                }
                Text(String.localized(
                    "Cloudless spots names and technical terms on your screen and automatically uses them to spell your words correctly. Processed on-device and never saved.",
                    table: "Transcription"
                ))
                .styleText(size: 12, weight: .regular, color: Color.T_1)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $asrOnScreenTermsEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Child Components: On-Screen Terms (Layer C)

    /// Layer C: at dictation start, OCR the on-screen window and mine likely
    /// proper nouns / jargon, merging them into the prompt glossary for that
    /// utterance only (never saved). Builds on the dictionary prompt-biasing path.


    /// Layer C source switch: screenshot OCR (default, more on-screen coverage)
    /// vs the accessibility preceding text around the cursor (no screen-recording
    /// permission, no capture latency).
    private var onScreenTermsSourceSection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Use accessibility text instead of screenshot", table: "Transcription"),
                subtitle: String.localized(
                    "Read the text around your cursor instead of taking a screenshot. No screen-recording permission needed, but screenshot OCR usually finds more on-screen terms.",
                    table: "Transcription"
                )
            ),
            isOn: $asrOnScreenTermsUseAccessibility
        )
    }

    // MARK: - Child Components: GPU Memory Section

    /// Advanced control over the MLX recycle-pool cap for on-device AI models
    /// (Qwen3-ASR, Granite). Stored in MB; 0 = Auto (per-model default). The
    /// slider works in GB. Capping the cache lowers RAM at a marginal latency
    /// cost and never breaks a model (it only bounds reusable buffers, not the
    /// live weights). See `MLXASREngine.resolvedCacheLimit`.
    private var gpuMemorySection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("GPU memory limit", table: "Transcription"),
                subtitle: String.localized(
                    "Cap how much GPU memory the on-device AI model keeps cached between dictations. Lower uses less RAM; higher is marginally faster. Auto picks a safe per-model default.",
                    table: "Transcription"
                )
            )
        ) {
            Spacer()
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { Double(mlxCacheLimitMB) / 1000.0 },
                        set: { mlxCacheLimitMB = Int(($0 * 1000).rounded()) }
                    ),
                    in: 0...6,
                    step: 0.5
                ) { editing in
                    // Apply live on release so the user sees RAM drop immediately.
                    if !editing { Task { await MLXASREngine.shared.applyUserCacheLimitLive() } }
                }
                .frame(width: 120)
                .tint(Color.S_0.opacity(0.6))

                Text(mlxCacheLimitMB == 0
                     ? String.localized("Auto", table: "Transcription")
                     : String(format: "%.1f GB", Double(mlxCacheLimitMB) / 1000.0))
                    .styleText(size: 11, color: Color.T_2)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    // MARK: - Child Components: Model Unload (inactivity) Section

    /// After this many minutes of dictation inactivity the resident ASR model is
    /// unloaded to reclaim RAM (Granite ~8-10 GB, Qwen ~5.5 GB). It reloads
    /// automatically on the next dictation. The slider snaps to a small set of
    /// stops including a "Never" position.
    private var modelUnloadSection: some View {
        // Discrete stops in minutes; 0 = Never (placed last on the track).
        let stops = [5, 10, 15, 30, 60, 0]
        let currentIndex = stops.firstIndex(of: asrInactivityUnloadMinutes) ?? stops.firstIndex(of: 30)!
        return SettingsPageSubsection(
            header: .init(
                title: String.localized("Unload models when idle", table: "Transcription"),
                subtitle: String.localized(
                    "Free the memory Onit's on-device models use after a period without dictation. They reload automatically the next time you dictate. Never keeps them loaded for faster first use.",
                    table: "Transcription"
                )
            )
        ) {
            Spacer()
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { Double(currentIndex) },
                        set: { asrInactivityUnloadMinutes = stops[Int($0.rounded())] }
                    ),
                    in: 0...Double(stops.count - 1),
                    step: 1
                )
                .frame(width: 120)
                .tint(Color.S_0.opacity(0.6))

                Text(asrInactivityUnloadMinutes == 0
                     ? String.localized("Never", table: "Transcription")
                     : String(format: String.localized("%d min", table: "Transcription"), asrInactivityUnloadMinutes))
                    .styleText(size: 11, color: Color.T_2)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    // MARK: - Child Components: Sound Effects Section

    private var soundEffectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Dictation sounds", table: "Transcription"),
                    subtitle: String.localized(
                        "Play a short sound when dictation starts and stops.",
                        table: "Transcription"
                    )
                ),
                isOn: $soundEffectsEnabled
            )

            if soundEffectsEnabled {
                SettingsPageSubsection(
                    header: .init(title: String.localized("Volume", table: "Transcription"))
                ) {
                    Spacer()
                    HStack(spacing: 8) {
                        // Release-to-preview: play the start chime at the chosen
                        // volume when the user finishes dragging.
                        Slider(value: $soundEffectsVolume, in: 0.0...1.0) { editing in
                            if !editing { SoundEffectsService.shared.preview(.dictationStart) }
                        }
                        .frame(width: 120)
                        .tint(Color.S_0.opacity(0.6))

                        Text("\(Int((soundEffectsVolume * 100).rounded()))%")
                            .styleText(size: 11, color: Color.T_2)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }
        }
        // Prewarm on enable: AppDelegate only prewarms at launch when the feature
        // is already on, so without this the first dictation after toggling pays
        // the cold decode and its start chime arrives late (or seems missing).
        .onChange(of: soundEffectsEnabled) { _, enabled in
            if enabled { SoundEffectsService.shared.prewarm() }
        }
    }

    /// Deterministic post-process: restore a dictionary term's exact written form
    /// (camelCase, paths, etc.) when the model heard it as separate words. Works on
    /// any model; protected against everyday phrases like "on it".
    private var formatMatchSection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Fix dictionary term formatting", table: "Transcription"),
                subtitle: String.localized(
                    "After transcribing, re-join your dictionary terms into their exact spelling (e.g. \"caps term selector\" → \"CapsTermSelector\"). Skips everyday phrases like \"on it\".",
                    table: "Transcription"
                )
            ),
            isOn: $asrDictionaryFormatMatchEnabled
        )
    }

    // MARK: - Child Components: Chunked Streaming Section

    /// Chunked-streaming transcription (BETA). Transcribes speech in the
    /// background during pauses to cut latency at key release. Only Parakeet and
    /// the MLX/Qwen backend decode per-segment context, so the toggle is disabled
    /// (greyed) on other models with the explanatory subtitle spelling out why.
    private var chunkedStreamingSection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Streaming Transcription (BETA)", table: "Transcription"),
                subtitle: String.localized(
                    "Available with Parakeet and MLX models (Qwen, Granite) only. Transcribes speech in the background during pauses to cut latency at release.",
                    table: "Transcription"
                )
            ),
            isOn: $transcriptionConfig.chunkedStreamingEnabled
        )
        .settingsUnavailable(!isChunkCapableBackend)
    }

    private var capitalizationSection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Smart Capitalization", table: "Settings"),
                subtitle: String.localized("Use context from surrounding text to decide whether the first word should be capitalized or continue a sentence in lowercase.", table: "Settings")
            ),
            isOn: $transcriptionConfig.sfCapitalizationEnabled
        )
    }

    // MARK: - Child Components: Correction Mode Section

    private var correctionModeSection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Correction Mode", table: "Transcription"),
                subtitle: String.localized("Review and edit each transcription before it's inserted.", table: "Transcription")
            ),
            isOn: $transcriptionConfig.forceCorrectionUI
        )
    }

    // MARK: - Child Components: AI Model Section

    /// Entry point for the "Local AI Models" picker sheet. The Pop-Up button shows
    /// the currently selected model and a "Browse all models…" action that opens
    /// the full sheet (download, switch, delete).
    /// Pop-Up uses the project's `SettingsPageSubsection(header:, dropdown:)` pattern
    /// (same layout as "Current Microphone") so the dropdown is right-aligned and
    /// styled consistently with the rest of the Settings page. Only installed models
    /// appear in the list - per Figma. The "Browse all models…" entry opens the
    /// sheet where un-installed models can be downloaded.
    private var aiModelSection: some View {
        let downloads = ASRModelDownloadManager.shared
        let downloadedModels = ASRModel.catalog.filter { $0.isAvailableForCurrentOS && downloads.installState(for: $0) == .installed }

        let modelOptions: [SettingsPageSubsection<EmptyView>.DropdownConfigsOption] = downloadedModels.map { model in
            // Append "(default)" to the catalog default - matches the Figma comp.
            let displayName = model.isDefault ? "\(model.displayName) (default)" : model.displayName
            return .init(
                id: UUID(),
                name: displayName,
                isSelected: model.id == transcriptionConfig.selectedASRModelId,
                action: { transcriptionConfig.selectedASRModelId = model.id }
            )
        }

        let browseOption: SettingsPageSubsection<EmptyView>.DropdownConfigsOption = .init(
            id: UUID(),
            name: String.localized("Browse all models…", table: "Transcription"),
            isSelected: false,
            action: { showASRModelsSheet = true }
        )

        return SettingsPageSubsection(
            header: .init(
                title: String.localized("AI Model", table: "Transcription"),
                subtitle: String.localized("Local speech recognition model.", table: "Transcription")
            ),
            dropdown: .init(
                placeholder: transcriptionConfig.selectedASRModel.displayName,
                options: modelOptions + [browseOption]
            )
        )
    }

    // MARK: - Child Components: VAD Filter Section

    private var vadFilterSection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Silence Filter", table: "Transcription"),
                subtitle: String.localized(
                    "Automatically ignores accidental trigger presses. Uses on-device AI to detect whether short recordings contain speech before transcribing.",
                    table: "Transcription"
                )
            ),
            isOn: Binding(
                get: { featureFlagManager.sileroVadEnabled },
                set: { FeatureFlagManager.shared.setSileroVadByUser($0) }
            )
        )
        .onChange(of: featureFlagManager.sileroVadEnabled, initial: false) { _, new in
            AnalyticsManager.Transcription.silenceFilterToggled(enabled: new)
        }
    }

    // MARK: - Child Components: Duck Audio Section

    private var duckAudioSection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Mute playing audio", table: "Transcription"),
                subtitle: String.localized(
                    "Mute other apps while dictating. Useful when listening to music or audio on speakers. Not needed with headphones.",
                    table: "Transcription"
                )
            ),
            isOn: $duckAudio
        )
    }

    // MARK: - Child Components: Onset Silence Prepend Section

    private var onsetSilencePrependSection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Improve First-Word Accuracy (BETA)", table: "Transcription"),
                subtitle: String.localized(
                    "Prepends a short silence before transcribing to give the model warm-up time. Can help recover words spoken at the very beginning of a recording.",
                    table: "Transcription"
                )
            ),
            isOn: Binding(
                get: { Defaults[.TranscriptionConfigKeys.onsetSilencePrependEnabled] },
                set: { Defaults[.TranscriptionConfigKeys.onsetSilencePrependEnabled] = $0 }
            )
        )
    }

    // MARK: - Child Components: Model Status Section

    private var modelStatusSection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Model Status", table: "Transcription"),
                subtitle: modelStatusCaption
            )
        ) {
            if transcriptionManager.isInitialized {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(String.localized("Ready", table: "Transcription"))
                        .font(.system(size: 13))
                        .foregroundColor(.green)
                }
            } else if transcriptionManager.isInitializing || isActiveBackendWarmingUp {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(String.localized("Loading...", table: "Transcription"))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            } else if transcriptionManager.errorMessage != nil || parakeetCoreMLWarmupError != nil {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Button(String.localized("Retry", table: "Transcription")) {
                        retryParakeetCoreMLWarmup()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                    Text(String.localized("Not loaded", table: "Transcription"))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var languageSection: some View {
        SettingsPageSubsection(
            header: .init(
                title: String.localized("Language (BETA)", table: "Transcription"),
                subtitle: String.localized(
                    "Select one or more languages. Choosing multiple lets Cloudless auto-detect between them.",
                    table: "Transcription"
                )
            ),
            multiSelectDropdown: .init(
                label: languageButtonLabel,
                dividerIndexes: [0],
                options: [
                    .init(
                        id: Self.supportedLanguages.first { $0.code == Self.autoDetectLanguageCode }!.id,
                        name: String.localized("Auto-detect", table: "Transcription"),
                        isSelected: transcriptionConfig.transcriptionLanguages.isEmpty,
                        action: {
                            transcriptionConfig.transcriptionLanguages = []
                        }
                    )
                ] + Self.languageOptions.map { language in
                    .init(
                        id: language.id,
                        name: language.name,
                        isSelected: transcriptionConfig.transcriptionLanguages.contains(language.code),
                        action: {
                            if transcriptionConfig.transcriptionLanguages.contains(language.code) {
                                transcriptionConfig.transcriptionLanguages.removeAll { $0 == language.code }
                            } else {
                                transcriptionConfig.transcriptionLanguages.append(language.code)
                            }
                        }
                    )
                }
            )
        )
    }

    #if DEBUG || ONIT_BETA
    // MARK: - Auto-Edit Section

    @Environment(\.appState) private var appState
    @Default(.availableLocalModels) private var availableLocalModels
    @Default(.autoeditLocalModel) private var autoeditLocalModel
    @Default(.autoeditPrompt) private var autoeditPrompt
    @State private var autoeditModelPickerOpen = false
    @State private var autoeditReloading = false

    private var autoEditSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPageSubsection(
                header: .init(
                    title: "Auto-Edit (BETA)",
                    subtitle: "Automatically improve dictated text using a local AI model before inserting."
                ),
                isOn: Binding(
                    get: { Defaults[.autoeditEnabled] },
                    set: { Defaults[.autoeditEnabled] = $0 }
                )
            )

            DividerHorizontal()

            SettingsPageSubsection(
                header: .init(
                    title: "Model",
                    subtitle: "Run Ollama and select a model to use."
                )
            ) {
                if availableLocalModels.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        (Text(.init("[Download Ollama](https://ollama.com/download/mac)"))
                            + Text(" to get started with local models."))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.S_0.opacity(0.65))
                        Text("Then run in Terminal:")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.S_0.opacity(0.65))
                        Text("ollama pull gemma3:1b")
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.T_8)
                            .cornerRadius(4)
                        Button("Reload") {
                            autoeditReloading = true
                            Task {
                                await appState.fetchLocalModels()
                                autoeditReloading = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(autoeditReloading)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button(action: { autoeditModelPickerOpen = true }) {
                            HStack(spacing: 4) {
                                Text(autoeditLocalModel ?? "Select model")
                                    .styleText(size: 13)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Color.S_2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.T_8)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $autoeditModelPickerOpen) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(availableLocalModels, id: \.self) { model in
                                    Button(action: {
                                        autoeditLocalModel = model
                                        autoeditModelPickerOpen = false
                                    }) {
                                        HStack {
                                            Text(model)
                                                .font(.system(size: 13))
                                            Spacer()
                                            if autoeditLocalModel == model {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 11, weight: .medium))
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                            .frame(minWidth: 180)
                        }

                        Button("Reload") {
                            autoeditReloading = true
                            Task {
                                await appState.fetchLocalModels()
                                autoeditReloading = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(autoeditReloading)
                    }
                }
            }

            DividerHorizontal()

            SettingsPageSubsection(
                header: .init(
                    title: "Prompt",
                    subtitle: "Instructions sent to the model with your text."
                )
            ) {
                TextEditor(text: $autoeditPrompt)
                    .font(.system(size: 12))
                    .frame(height: 72)
                    .padding(4)
                    .background(Color.T_8)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.genericBorder, lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Dev Section

    private var devSection: some View {
        SettingsPageSection(title: .init(text: String.localized("Developer Settings", table: "Transcription"))) {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("N-best Selection", table: "Transcription"),
                    subtitle: String.localized("Use LLM to select best hypothesis from multiple candidates.", table: "Transcription")
                ),
                isOn: $transcriptionConfig.nbestSelectionEnabled
            )

            #if DEBUG && canImport(TranscriptionCleanup) // the scoring debug window shows Smart Cleanup decisions
            DividerHorizontal()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scoring Debug Window")
                        .styleText(size: 13, weight: .regular, color: .S_0)
                    Text("Inspect recent cleanup decisions (input, output, diff, cap).")
                        .styleText(size: 12, weight: .regular, color: .T_1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    ScoringDebugWindowController.shared.show()
                } label: {
                    Text("Open")
                        .styleText(size: 13, weight: .regular, color: .white)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Color.accentsBlue.opacity(0.5))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            #endif

            DividerHorizontal()

            autoEditSection

            DividerHorizontal()

            SettingsPageSubsection(
                header: .init(
                    title: "Always Show Correction Prompt",
                    subtitle: "Show the \"Not quite right?\" UI after every transcription, ignoring the 3-transcription limit."
                ),
                isOn: Binding(
                    get: { Defaults[.transcriptionAlwaysShowCorrectionPrompt] },
                    set: { Defaults[.transcriptionAlwaysShowCorrectionPrompt] = $0 }
                )
            )

            DividerHorizontal()

            SettingsPageSubsection(
                horizontal: .init(spacing: 8),
                header: .init(
                    title: "Overlay Positioning Mode",
                    subtitle: "AX: Accessibility bounds only (default). Screen Recording: OCR diff. Mouse: cursor position only. Hint: anchor to the Hint window."
                )
            ) {
                Picker("Positioning Mode", selection: Binding(
                    get: { Defaults[.transcriptionOverlayPositioningMode] },
                    set: { Defaults[.transcriptionOverlayPositioningMode] = $0 }
                )) {
                    Text("Screen Recording").tag(OverlayPositioningMode.screenRecording)
                    Text("AX").tag(OverlayPositioningMode.ax)
                    Text("Mouse").tag(OverlayPositioningMode.mouse)
                    Text("Hint").tag(OverlayPositioningMode.hint)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
            }

            DividerHorizontal()

            SettingsPageSubsection(
                header: .init(
                    title: "AX Window Context Scrape",
                    subtitle: "Capture full accessibility tree after each dictation (debug builds only). Disable to rule out AX traversal as a performance bottleneck."
                ),
                isOn: $transcriptionConfig.windowContextScrapeEnabled
            )



            DividerHorizontal()

            SettingsPageSubsection(
                header: .init(
                    title: "Dictation Gap Repair",
                    subtitle: "Re-run TDT on blank gaps ≥960ms where VAD detects speech. Recovers suppressed dictation commands (\"period\", \"end quote\", etc.). Adds ~6ms overhead per transcription."
                ),
                isOn: Binding(
                    get: { Defaults[.transcriptionDictationRepairEnabled] },
                    set: { Defaults[.transcriptionDictationRepairEnabled] = $0 }
                )
            )

            DividerHorizontal()

            SettingsPageSubsection(
                header: .init(
                    title: "Dictation Gap Repair",
                    subtitle: "Re-run TDT on blank gaps ≥960ms where VAD detects speech. Recovers suppressed dictation commands (\"period\", \"end quote\", etc.). Adds ~6ms overhead per transcription."
                ),
                isOn: Binding(
                    get: { Defaults[.transcriptionDictationRepairEnabled] },
                    set: { Defaults[.transcriptionDictationRepairEnabled] = $0 }
                )
            )

        }
    }
    #endif
    
    // MARK: - Private Functions: Shortcuts
    
    private func selectShortcutOption(_ type: TranscriptionShortcutType) {
        guard type != shortcutType else { return }

        // Stop any active recording before switching - the key-up for the old type
        // won't be handled after the type changes, which would orphan the state machine.
        KeyboardShortcutsManager.cancelIfActive()
        KeystrokeNotificationManager.shared.resetDoubleTapState()

        let previousType = shortcutType
        shortcutType = type
        type.apply(previousType: previousType, forceDefaultOnSwitch: true)
    }

    private func addAlternate(type: TranscriptionShortcutType) {
        let maxCount = TranscriptionShortcutType.customShortcutMaxCount
        guard customShortcutCount < maxCount else { return }

        let newSlotName = TranscriptionShortcutType.customShortcutNames[customShortcutCount]

        switch type {
        case .capsLock:
            // Bind the CapsLock shortcut into this slot so the HID path can detect it.
            KeyboardShortcuts.setShortcut(TranscriptionShortcutType.capsLock.defaultShortcut, for: newSlotName)
        case .fn, .rightCommand, .commandDoubleTap, .controlDoubleTap:
            // These types are handled via direct event monitoring - no library binding needed.
            KeyboardShortcuts.setShortcut(nil, for: newSlotName)
        case .custom:
            // Start empty; user binds via the recorder.
            KeyboardShortcuts.setShortcut(nil, for: newSlotName)
        }

        // Track the alternate slot type (alternateSlotTypes is indexed by alternate index, i.e., slot - 1).
        alternateSlotTypes.append(type.rawValue)
        customShortcutCount += 1
        KeyboardShortcutsManager.refreshCustomTranscriptionShortcutPool()

        // CapsLock alternates require HID remapping - apply it now if not already active.
        if type == .capsLock {
            KeystrokeNotificationManager.shared.applyHIDRemapping(context: "CapsLockAlternateAdded")
        }
    }

    private func removeCustomShortcut(at index: Int) {
        guard customShortcutCount > 1, index >= 0, index < customShortcutCount else { return }

        let pool = TranscriptionShortcutType.customShortcutNames
        // Shift subsequent bindings and type entries down by one.
        for i in index..<(customShortcutCount - 1) {
            let next = KeyboardShortcuts.getShortcut(for: pool[i + 1])
            KeyboardShortcuts.setShortcut(next, for: pool[i])
        }
        KeyboardShortcuts.setShortcut(nil, for: pool[customShortcutCount - 1])

        // Shift alternateSlotTypes. For alternates (index >= 1) remove their entry directly.
        // For slot 0 in .custom mode, the old slot 1 shifts down and its type entry is no longer needed.
        let altIndex = index - 1
        if altIndex >= 0, altIndex < alternateSlotTypes.count {
            alternateSlotTypes.remove(at: altIndex)
        } else if index == 0, !alternateSlotTypes.isEmpty {
            alternateSlotTypes.remove(at: 0)
        }

        customShortcutCount -= 1

        if Defaults[TranscriptionConfigKeys.lastUsedCustomShortcutIndex] >= customShortcutCount {
            Defaults[TranscriptionConfigKeys.lastUsedCustomShortcutIndex] = 0
        }

        KeyboardShortcutsManager.refreshCustomTranscriptionShortcutPool()
        // Remove HID remapping if no feature needs it anymore (e.g., last CapsLock alternate was removed).
        KeystrokeNotificationManager.shared.removeHIDRemappingIfNotNeeded()
    }
    
    // MARK: - Private Functions: History
    
    private func deleteAllTranscriptionHistory() {
        clearAllHistoryError = nil
        
        Task {
            do {
                try await transcriptionHistoryManager.deleteAll()
            } catch {
                clearAllHistoryError = String.localized(error.localizedDescription, table: "Transcription")
            }
        }
    }
    
    private func deleteAllCorrectedTranscriptionHistory() {
        clearAllCorrectionHistoryError = nil
        
        Task {
            do {
                try await transcriptionHistoryManager.deleteAllCorrected()
            } catch {
                clearAllCorrectionHistoryError = String.localized(error.localizedDescription, table: "Transcription")
            }
        }
    }
    
    private func exportData() {
        isExporting = true

        Task {
            do {
                let zipURL = try await transcriptionHistoryManager.exportCorrectedToZip()

                await MainActor.run {
                    isExporting = false

                    // Show save panel
                    let savePanel = NSSavePanel()
                    savePanel.allowedContentTypes = [.zip]
                    savePanel.canCreateDirectories = true
                    savePanel.nameFieldStringValue = zipURL.lastPathComponent

                    savePanel.begin { response in
                        if response == .OK, let destinationURL = savePanel.url {
                            do {
                                // Remove existing file if it exists
                                if FileManager.default.fileExists(atPath: destinationURL.path) {
                                    try FileManager.default.removeItem(at: destinationURL)
                                }
                                try FileManager.default.moveItem(at: zipURL, to: destinationURL)
                            } catch {
                                self.exportError = String.localized(error.localizedDescription, table: "Transcription")
                            }
                        } else {
                            // User cancelled, clean up temp file
                            try? FileManager.default.removeItem(at: zipURL)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportError = String.localized(error.localizedDescription, table: "Transcription")
                }
            }
        }
    }
    
    // MARK: - Private Functions: Advanced Settings
    
    /// Retry ASR warmup using both coordinator and transcription manager
    private func retryParakeetCoreMLWarmup() {
        // Retry the active backend's provider
        let providerIdentifier = ASRBackendRegistry.descriptor(for: transcriptionConfig.backend).providerId
        warmupCoordinator.retryWarmup(for: providerIdentifier)
        // Also retry via transcription manager for compatibility
        transcriptionManager.initializeModelsInBackground()
    }
}

private struct LanguageOption: Identifiable {
    let code: String
    let name: String
    let id: UUID
}

