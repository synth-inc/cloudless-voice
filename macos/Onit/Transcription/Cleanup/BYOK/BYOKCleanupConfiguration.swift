// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BYOKCleanupConfiguration.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  "Your own model" cleanup: which server to call and what to send it. Everything
//  here lives in preferences except the API key, which only ever goes to the
//  Keychain (`APIKeyStore`).
//

import Defaults
import Foundation

// MARK: - Presets

/// A server the user can point cleanup at. Each preset fills in a base URL; Custom
/// takes any OpenAI-compatible one (llama.cpp server, vLLM, Groq, ...).
enum BYOKPreset: String, CaseIterable, Identifiable, Sendable, Defaults.Serializable {
    case ollama
    case lmStudio = "lmstudio"
    case openAI = "openai"
    case anthropic
    case openRouter = "openrouter"
    case custom

    var id: String { rawValue }

    /// Wire format the preset speaks.
    enum API: Sendable {
        case openAICompatible
        case anthropic
    }

    var api: API {
        self == .anthropic ? .anthropic : .openAICompatible
    }

    /// Filled into the base URL field when the preset is picked.
    var defaultBaseURL: String {
        switch self {
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .custom: ""
        }
    }

    /// Model name shown as a placeholder, as a hint of the expected format.
    var modelPlaceholder: String {
        switch self {
        case .ollama: "llama3.2"
        case .lmStudio: "qwen2.5-7b-instruct"
        case .openAI: "gpt-4.1-mini"
        case .anthropic: "claude-haiku-5-5"
        case .openRouter: "meta-llama/llama-3.3-70b-instruct"
        case .custom: "model-name"
        }
    }

    /// Hosted services that can't be used without an API key.
    var requiresAPIKey: Bool {
        switch self {
        case .openAI, .anthropic, .openRouter: true
        case .ollama, .lmStudio, .custom: false
        }
    }

    /// Whether Settings offers an API key field. Custom may front a hosted service.
    var acceptsAPIKey: Bool { requiresAPIKey || self == .custom }

    /// Name shown in the picker and in the cloud notice.
    @MainActor
    var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .openRouter: "OpenRouter"
        case .custom: String.localized("Custom", table: "Settings")
        }
    }

    /// Keychain account the preset's key is stored under: one item per provider.
    var keychainAccount: String { rawValue }
}

// MARK: - Configuration

/// A snapshot of the BYOK settings, taken once per cleanup.
struct BYOKCleanupConfiguration: Equatable, Sendable {
    var preset: BYOKPreset
    var baseURL: String
    var model: String
    /// The user's instructions (the rules), or nil for the bundled default.
    var instructions: String?
    /// The user's script (where instructions, transcript and the request for
    /// output markers go), or nil for the bundled default.
    var customPrompt: String?
    /// Send the user's dictionary terms with the transcript.
    var sendVocabulary: Bool
    /// Send the frontmost app's name with the transcript.
    var sendAppName: Bool
    /// Only what the model writes between these two markers is inserted
    /// (`BYOKReplyExtractor`). Both blank: the whole reply.
    var outputStart: String = BYOKReplyExtractor.defaultStart
    var outputEnd: String = BYOKReplyExtractor.defaultEnd

    var trimmedModel: String { model.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The base URL, if it's a usable http(s) URL. A trailing slash is dropped so
    /// endpoint paths can be appended.
    ///
    /// Plain http is only accepted for a host on this Mac or the local network
    /// (`allowsPlainHTTP`): anywhere else the transcript and the API key would cross
    /// the internet unencrypted, so such a URL resolves to nil (`isInsecureRemoteURL`).
    var resolvedBaseURL: URL? {
        guard let url = parsedBaseURL else { return nil }
        if url.scheme?.lowercased() == "http", let host = url.host, !Self.allowsPlainHTTP(host: host) {
            return nil
        }
        return url
    }

    /// An http:// URL to a host that isn't local: refused by `resolvedBaseURL`.
    var isInsecureRemoteURL: Bool {
        guard let url = parsedBaseURL, url.scheme?.lowercased() == "http", let host = url.host else { return false }
        return !Self.allowsPlainHTTP(host: host)
    }

    private var parsedBaseURL: URL? {
        var string = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while string.hasSuffix("/") { string.removeLast() }
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// Whether the transcript leaves the Mac. Ollama and LM Studio are local unless
    /// pointed elsewhere; Custom is judged by its host.
    var isCloud: Bool {
        guard let host = parsedBaseURL?.host?.lowercased() else {
            return preset.requiresAPIKey
        }
        return !Self.isLocalHost(host)
    }

    /// Who the transcript is sent to, for the cloud notice.
    @MainActor
    var recipientName: String {
        if preset == .custom, let host = parsedBaseURL?.host { return host }
        return preset.displayName
    }

    /// This Mac or a private network: loopback, `.local` (mDNS), and the private
    /// IPv4 ranges. Address prefixes only count for a literal IPv4 address, so a
    /// name like `127.example.com` or `10.attacker.net` is not local.
    static func isLocalHost(_ host: String) -> Bool {
        var host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".localhost") {
            return true
        }
        guard let octets = ipv4Octets(host) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (0, _): return true // 0.0.0.0 reaches this Mac
        case (172, 16...31): return true
        case (169, 254): return true // link-local
        default: return false
        }
    }

    /// Hosts plain http may be used with: `isLocalHost`, plus the other names and
    /// ranges that never route over the public internet - unqualified names
    /// (`gpu-box`, as App Transport Security also allows), carrier-grade NAT
    /// addresses (Tailscale's 100.64.0.0/10, already encrypted) and IPv6 unique-local
    /// or link-local addresses. They still count as "cloud" for the notice.
    static func allowsPlainHTTP(host: String) -> Bool {
        if isLocalHost(host) { return true }
        var host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        if let octets = ipv4Octets(host) {
            return octets[0] == 100 && (64...127).contains(octets[1])
        }
        if host.contains(":") {
            return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
        }
        return !host.contains(".")
    }

    /// The four octets of a dotted IPv4 literal, or nil for anything else.
    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part).flatMap { (0...255).contains($0) ? $0 : nil }
        }
        return octets.count == 4 ? octets : nil
    }
}

// MARK: - Persistence

extension Defaults.Keys {
    /// BYOK cleanup settings. The API key is deliberately not here: it lives in the
    /// Keychain only (`KeychainAPIKeyStore`).
    enum BYOKCleanupKeys {
        static let preset = Key<BYOKPreset>("byokCleanupPreset", default: .ollama)
        static let baseURL = Key<String>("byokCleanupBaseURL", default: BYOKPreset.ollama.defaultBaseURL)
        static let model = Key<String>("byokCleanupModel", default: "")
        /// Nil means the bundled default instructions.
        static let instructions = Key<String?>("byokCleanupInstructions", default: nil)
        /// Nil means the bundled default script.
        static let customPrompt = Key<String?>("byokCleanupCustomPrompt", default: nil)
        /// Markers the model's result is read from between (`BYOKReplyExtractor`).
        static let outputStart = Key<String>("byokCleanupOutputStart", default: BYOKReplyExtractor.defaultStart)
        static let outputEnd = Key<String>("byokCleanupOutputEnd", default: BYOKReplyExtractor.defaultEnd)
        static let sendVocabulary = Key<Bool>("byokCleanupSendVocabulary", default: false)
        static let sendAppName = Key<Bool>("byokCleanupSendAppName", default: false)
    }
}

extension BYOKCleanupConfiguration {
    private typealias Keys = Defaults.Keys.BYOKCleanupKeys

    /// The current settings.
    static func load() -> BYOKCleanupConfiguration {
        BYOKCleanupConfiguration(
            preset: Defaults[Keys.preset],
            baseURL: Defaults[Keys.baseURL],
            model: Defaults[Keys.model],
            instructions: Defaults[Keys.instructions],
            customPrompt: Defaults[Keys.customPrompt],
            sendVocabulary: Defaults[Keys.sendVocabulary],
            sendAppName: Defaults[Keys.sendAppName],
            outputStart: Defaults[Keys.outputStart],
            outputEnd: Defaults[Keys.outputEnd]
        )
    }
}
