// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BYOKCleanupSettingsView.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  Settings for the Rewrite stage ("Your own model"): server preset, URL, model,
//  API key, connection test, what's sent, and the prompt. Layout: labelled
//  fields, a verify action, and an inline error.
//

import Defaults
import SwiftUI

struct BYOKCleanupSettingsView: View {
    private typealias Keys = Defaults.Keys.BYOKCleanupKeys

    // MARK: - Defaults

    @Default(Keys.preset) private var preset
    @Default(Keys.baseURL) private var baseURL
    @Default(Keys.model) private var model
    @Default(Keys.instructions) private var instructions
    @Default(Keys.customPrompt) private var customPrompt
    @Default(Keys.outputStart) private var outputStart
    @Default(Keys.outputEnd) private var outputEnd
    @Default(Keys.sendVocabulary) private var sendVocabulary
    @Default(Keys.sendAppName) private var sendAppName

    // MARK: - States

    /// What's typed in the key field. Saved to the Keychain on submit; never to Defaults.
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = false
    @State private var keySaveFailed = false

    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var modelsError: String?

    @State private var isTesting = false
    @State private var testResult: TestResult?

    @State private var showPrompt = true
    @State private var showFullScript = false

    private enum TestResult: Equatable {
        case success(message: String)
        /// Connected, but too slow for most dictations to be cleaned in time.
        case slow(message: String)
        case failure(message: String)
    }

    // MARK: - Private Variables

    private let keyStore: APIKeyStore = KeychainAPIKeyStore.shared

    private var configuration: BYOKCleanupConfiguration {
        BYOKCleanupConfiguration(
            preset: preset,
            baseURL: baseURL,
            model: model,
            instructions: instructions,
            customPrompt: customPrompt,
            sendVocabulary: sendVocabulary,
            sendAppName: sendAppName,
            outputStart: outputStart,
            outputEnd: outputEnd
        )
    }

    private var provider: BYOKCleanupProvider { BYOKCleanupProvider(keyStore: keyStore) }

    /// What the user still has to do, in plain words, or nil when ready.
    private var setupHint: String? {
        if configuration.isInsecureRemoteURL {
            return BYOKClientError.insecureBaseURL.userMessage
        }
        if configuration.resolvedBaseURL == nil {
            return String.localized("Enter the server's URL.", table: "Settings")
        }
        if configuration.trimmedModel.isEmpty {
            return String.localized("Choose a model.", table: "Settings")
        }
        if preset.requiresAPIKey && !hasStoredKey {
            return String.localized("Add your API key.", table: "Settings")
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        Group {
            serverSection
            whatsSentSection
            promptSection
        }
        .onAppear {
            refreshStoredKey()
            fetchModelsIfPossible()
        }
        .onChange(of: preset) { _, _ in
            refreshStoredKey()
            fetchModelsIfPossible()
        }
    }

    // MARK: - Child Components: Server

    private var serverSection: some View {
        SettingsPageSection {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Server", table: "Settings"),
                    subtitle: String.localized("Ollama and LM Studio run on your Mac. Any OpenAI-compatible server works with Custom.", table: "Settings")
                )
            ) {
                Picker("", selection: presetBinding) {
                    ForEach(BYOKPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            DividerHorizontal()

            labeledRow(String.localized("URL", table: "Settings")) {
                TextField(preset == .custom ? "http://localhost:8080/v1" : preset.defaultBaseURL, text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { fetchModelsIfPossible() }
            }

            labeledRow(String.localized("Model", table: "Settings")) {
                HStack(spacing: 6) {
                    TextField(preset.modelPlaceholder, text: $model)
                        .textFieldStyle(.roundedBorder)
                    modelMenu
                }
            }

            Text(String.localized("Thinking or reasoning models (such as qwen3, deepseek-r1 or OpenAI's o-series) are slow for this and may return nothing. A small instruct model works best.", table: "Settings"))
                .styleText(size: 11, weight: .regular, color: Color.T_2)
                .fixedSize(horizontal: false, vertical: true)

            if let modelsError {
                Text(modelsError)
                    .styleText(size: 11, weight: .regular, color: Color.T_2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if preset.acceptsAPIKey {
                labeledRow(String.localized("API key", table: "Settings")) {
                    apiKeyField
                }
            }

            if configuration.isCloud {
                cloudNotice
            }

            DividerHorizontal()

            testConnectionRow
        }
    }

    private var modelMenu: some View {
        Menu {
            if availableModels.isEmpty {
                Text(isFetchingModels
                     ? String.localized("Loading models…", table: "Settings")
                     : String.localized("No models found", table: "Settings"))
            }
            ForEach(availableModels, id: \.self) { id in
                Button(id) { model = id }
            }
            Divider()
            Button(String.localized("Refresh list", table: "Settings")) { fetchModels() }
        } label: {
            Image(systemName: "list.bullet")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String.localized("Models on this server", table: "Settings"))
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField(
                    hasStoredKey
                        ? String.localized("Saved in your Keychain", table: "Settings")
                        : (preset.requiresAPIKey
                            ? String.localized("Paste your API key", table: "Settings")
                            : String.localized("Optional", table: "Settings")),
                    text: $apiKeyDraft
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveKey() }

                Button(String.localized("Save", table: "Settings")) { saveKey() }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasStoredKey {
                    Button(String.localized("Remove", table: "Settings")) { removeKey() }
                }
            }
            if keySaveFailed {
                Text(String.localized("Couldn't save the key to your Keychain. Unlock it and try again.", table: "Settings"))
                    .styleText(size: 11, weight: .regular, color: Color.red500)
            }
        }
    }

    private var cloudNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "icloud")
                .font(.system(size: 11))
                .foregroundColor(Color.T_2)
            Text(String.localized("Transcript text is sent to %@. Audio stays on your Mac.", table: "Settings", configuration.recipientName))
                .styleText(size: 11, weight: .regular, color: Color.T_1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var testConnectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(isTesting
                       ? String.localized("Testing…", table: "Settings")
                       : String.localized("Test connection", table: "Settings")) {
                    testConnection()
                }
                .disabled(isTesting || configuration.resolvedBaseURL == nil || configuration.trimmedModel.isEmpty)

                if let setupHint {
                    Text(setupHint)
                        .styleText(size: 11, weight: .regular, color: Color.T_2)
                }
            }

            switch testResult {
            case .success(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .styleText(size: 11, weight: .regular, color: Color.T_1)
                    .fixedSize(horizontal: false, vertical: true)
            case .slow(let message):
                Label(message, systemImage: "tortoise.fill")
                    .styleText(size: 11, weight: .regular, color: Color.orange500)
                    .fixedSize(horizontal: false, vertical: true)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .styleText(size: 11, weight: .regular, color: Color.red500)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
    }

    // MARK: - Child Components: What's sent

    private var whatsSentSection: some View {
        SettingsPageSection(
            title: .init(text: String.localized("What's sent", table: "Settings")),
            subtitle: .init(text: String.localized("Only the transcript and the prompt, unless you turn these on.", table: "Settings"))
        ) {
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Send my dictionary", table: "Settings"),
                    subtitle: String.localized("Helps the model spell names and terms you've added.", table: "Settings")
                ),
                isOn: $sendVocabulary
            )
            DividerHorizontal()
            SettingsPageSubsection(
                header: .init(
                    title: String.localized("Send the app name", table: "Settings"),
                    subtitle: String.localized("Tells the model which app you're dictating into, such as Mail or Slack.", table: "Settings")
                ),
                isOn: $sendAppName
            )
        }
    }

    // MARK: - Child Components: Prompt

    private var promptSection: some View {
        SettingsPageSection {
            DisclosureGroup(isExpanded: $showPrompt) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String.localized("Cloudless sends your instructions and your words, asks the model to put the result between <output> and </output>, and pastes only what's between them. Anything else the model says is ignored.", table: "Settings"))
                        .styleText(size: 11, weight: .regular, color: Color.T_2)
                        .fixedSize(horizontal: false, vertical: true)

                    editor(instructionsBinding, height: 220)

                    HStack {
                        Spacer()
                        Button(String.localized("Reset to default", table: "Settings")) {
                            instructions = nil
                        }
                        .disabled(instructions == nil)
                    }

                    DividerHorizontal()

                    SettingsPageSubsection(
                        header: .init(
                            title: String.localized("Show full script", table: "Settings"),
                            subtitle: String.localized("Everything sent to the model, and the markers the result is read from.", table: "Settings")
                        ),
                        isOn: $showFullScript
                    )

                    if showFullScript {
                        fullScript
                    }
                }
                .padding(.top, 8)
            } label: {
                Button {
                    withAnimation { showPrompt.toggle() }
                } label: {
                    Text(String.localized("Instructions", table: "Settings"))
                        .styleText(size: 13, weight: .regular)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The script around the instructions, and the output markers. For people who
    /// want their own format: change what the script asks for and the markers
    /// together, and Cloudless pastes what's between the markers.
    private var fullScript: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String.localized("{{instructions}} is the box above. {{transcript}} is your words. {{language}}, {{vocabulary}} and {{app_name}} are filled in, or their line is left out when that option is off.", table: "Settings"))
                .styleText(size: 11, weight: .regular, color: Color.T_2)
                .fixedSize(horizontal: false, vertical: true)

            editor(promptBinding, height: 200)

            HStack {
                Spacer()
                Button(String.localized("Reset to default", table: "Settings")) {
                    customPrompt = nil
                }
                .disabled(customPrompt == nil)
            }

            Text(String.localized("Only the text between these markers is pasted. The last start marker in the reply counts. Leave both blank to paste the whole reply.", table: "Settings"))
                .styleText(size: 11, weight: .regular, color: Color.T_2)
                .fixedSize(horizontal: false, vertical: true)

            labeledRow(String.localized("Starts after", table: "Settings")) {
                TextField(BYOKReplyExtractor.defaultStart, text: $outputStart)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            labeledRow(String.localized("Ends before", table: "Settings")) {
                TextField(BYOKReplyExtractor.defaultEnd, text: $outputEnd)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        .padding(.top, 4)
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 11, design: .monospaced))
            .frame(height: height)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color.T_9)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    /// Why the test reply couldn't be used, and what to do about it.
    private static func message(for rejection: BYOKReplyExtractor.Rejection) -> String {
        switch rejection {
        case .missingMarker(let marker):
            String.localized("The model's reply didn't contain %@. Check that the script asks for it, or change the markers under Show full script.", table: "Settings", marker)
        case .empty:
            String.localized("The model answered, but there was nothing between the output markers. Try a different model or prompt.", table: "Settings")
        case .tooLong:
            String.localized("The model's reply was much longer than the test sentence. It may have answered instead of rewriting. Try a different model or prompt.", table: "Settings")
        case .tooShort:
            String.localized("The model's reply was much shorter than the test sentence. Try a different model or prompt.", table: "Settings")
        }
    }

    private func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .styleText(size: 13, weight: .regular)
                .frame(width: 70, alignment: .leading)
            content()
        }
    }

    /// Picking a preset fills in its URL and clears a model that belonged to the
    /// previous server. Custom keeps whatever URL is there.
    private var presetBinding: Binding<BYOKPreset> {
        Binding(
            get: { preset },
            set: { newValue in
                guard newValue != preset else { return }
                preset = newValue
                if newValue != .custom { baseURL = newValue.defaultBaseURL }
                model = ""
                availableModels = []
                apiKeyDraft = ""
                testResult = nil
            }
        )
    }

    /// Editing the default stores a custom copy; matching the default again clears it.
    private var instructionsBinding: Binding<String> {
        Binding(
            get: { instructions ?? BYOKPrompt.defaultInstructions },
            set: { newValue in
                instructions = newValue == BYOKPrompt.defaultInstructions ? nil : newValue
            }
        )
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { customPrompt ?? BYOKPrompt.defaultTemplate },
            set: { newValue in
                customPrompt = newValue == BYOKPrompt.defaultTemplate ? nil : newValue
            }
        )
    }

    // MARK: - Actions

    private func refreshStoredKey() {
        hasStoredKey = preset.acceptsAPIKey && keyStore.apiKey(for: preset.keychainAccount) != nil
        keySaveFailed = false
    }

    private func saveKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keySaveFailed = !keyStore.setAPIKey(key, for: preset.keychainAccount)
        if !keySaveFailed {
            apiKeyDraft = ""
            hasStoredKey = true
            fetchModels()
        }
    }

    private func removeKey() {
        keyStore.setAPIKey(nil, for: preset.keychainAccount)
        apiKeyDraft = ""
        refreshStoredKey()
    }

    /// Lists models without bothering the user: local servers always, hosted ones
    /// once there's a key.
    private func fetchModelsIfPossible() {
        guard configuration.resolvedBaseURL != nil else { return }
        if preset.requiresAPIKey && !hasStoredKey { return }
        fetchModels()
    }

    private func fetchModels() {
        let configuration = configuration
        let draft = apiKeyDraft
        isFetchingModels = true
        modelsError = nil
        Task {
            defer { isFetchingModels = false }
            do {
                availableModels = try await provider.listModels(configuration: configuration, apiKey: draft)
            } catch let error as BYOKClientError {
                availableModels = []
                modelsError = String.localized("Couldn't list models: %@", table: "Settings", error.userMessage)
            } catch {
                availableModels = []
            }
        }
    }

    private func testConnection() {
        let configuration = configuration
        let draft = apiKeyDraft
        let budget = BYOKCleanupProvider(configuration: { configuration }, keyStore: keyStore).timeout
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            do {
                let test = try await provider.testConnection(configuration: configuration, apiKey: draft)
                let seconds = String(format: "%.1f", test.elapsed)
                if test.elapsed > Double(budget.components.seconds) {
                    var message = String.localized(
                        "Connected, but the reply took %@ s. A dictation waits at most %d s for the rewrite, then pastes the text without it, so with this model most dictations won't be rewritten. Try a smaller or faster model.",
                        table: "Settings", seconds, Int(budget.components.seconds)
                    )
                    if !configuration.isCloud {
                        message += " " + String.localized(
                            "The first reply after the server loads a model is slower: test again to see its usual speed.",
                            table: "Settings"
                        )
                    }
                    testResult = .slow(message: message)
                } else {
                    testResult = .success(message: String.localized("Connected. Reply in %@ s: “%@”", table: "Settings", seconds, test.sample))
                }
            } catch let error as BYOKClientError {
                testResult = .failure(message: error.userMessage)
            } catch let rejection as BYOKReplyExtractor.Rejection {
                testResult = .failure(message: Self.message(for: rejection))
            } catch {
                testResult = .failure(message: String.localized("The model answered, but not with usable text. Try a different model or prompt.", table: "Settings"))
            }
        }
    }
}
