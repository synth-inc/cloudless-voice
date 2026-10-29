// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BYOKLLMClient.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  Two small, non-streaming HTTP clients for "Your own model" cleanup: one for
//  the OpenAI-compatible chat-completions API (OpenAI, OpenRouter, Ollama,
//  LM Studio, llama.cpp server, ...) and one for Anthropic's Messages API.
//  One request per dictation; no SDKs.
//
//  Connection check: `GET <base>/models` with a bearer token, or
//  `x-api-key` + `anthropic-version` for Anthropic.
//

import Foundation

// MARK: - Protocol

/// One prompt in, one reply out.
protocol BYOKLLMClient: Sendable {
    /// Sends `prompt` as a single user message and returns the model's text.
    func complete(prompt: String, model: String, maxTokens: Int) async throws -> String
    /// Model ids the server offers, for the Settings picker.
    func listModels() async throws -> [String]
}

// MARK: - Errors

/// What went wrong talking to the user's server, in terms Settings can explain.
///
/// Messages never carry the API key or the transcript; a server's own error text
/// is redacted (`SecretRedactor`) and cut short before it's kept.
enum BYOKClientError: Error, Equatable, LocalizedError {
    /// No connection: server not running, wrong host or port, offline.
    case unreachable(String)
    /// 401 / 403: the key is missing, wrong or lacks access.
    case unauthorized(status: Int)
    /// The server doesn't know the model.
    case modelNotFound(String)
    /// No answer in time.
    case timeout
    /// The base URL isn't a usable http(s) URL.
    case invalidBaseURL
    /// The base URL is plain http to a host that isn't local: refused, since the
    /// transcript and key would travel unencrypted.
    case insecureBaseURL
    /// The model hit the reply's token limit, so the text is cut short.
    case truncated
    /// Any other non-2xx reply.
    case http(status: Int, message: String?)
    /// A 2xx reply we couldn't read.
    case badResponse(String)
    /// The reply (success or error body) passed `BYOKHTTP.maxResponseBytes`.
    case responseTooLarge
    /// The transcript is longer than any reply could hold, so it was not sent.
    case transcriptTooLong

    /// For logs and `CleanupError.providerFailed`.
    var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "BYOK server unreachable: \(detail)"
        case .unauthorized(let status): "BYOK server rejected the API key (HTTP \(status))"
        case .modelNotFound(let model): "BYOK model not found: \(model)"
        case .timeout: "BYOK request timed out"
        case .invalidBaseURL: "BYOK base URL is invalid"
        case .insecureBaseURL: "BYOK base URL uses plain http to a non-local host"
        case .truncated: "BYOK reply was cut off at the token limit"
        case .http(let status, let message): "BYOK server error HTTP \(status)\(message.map { ": \($0)" } ?? "")"
        case .badResponse(let detail): "BYOK reply unreadable: \(detail)"
        case .responseTooLarge: "BYOK reply exceeded the size limit"
        case .transcriptTooLong: "Transcript too long for a single cleanup request"
        }
    }

    /// Plain-language explanation for Settings.
    @MainActor
    var userMessage: String {
        switch self {
        case .unreachable:
            String.localized("Couldn't reach the server. Check that it's running and the URL is right.", table: "Settings")
        case .unauthorized:
            String.localized("The server rejected the API key. Check that it's correct and still active.", table: "Settings")
        case .modelNotFound(let model):
            String.localized("The server doesn't have a model called “%@”. Check the name, or download the model first.", table: "Settings", model)
        case .timeout:
            String.localized("The server took too long to answer.", table: "Settings")
        case .invalidBaseURL:
            String.localized("Enter a server URL starting with http:// or https://.", table: "Settings")
        case .insecureBaseURL:
            String.localized("Use https:// for a server that isn't on your Mac or local network.", table: "Settings")
        case .truncated:
            String.localized("The model's reply was cut off. Try a model that doesn't think at length, or a shorter prompt.", table: "Settings")
        case .http(404, _):
            String.localized("The server doesn't recognise this address. Check the URL: OpenAI-compatible servers usually end in /v1.", table: "Settings")
        case .http(let status, _):
            String.localized("The server returned an error (HTTP %d).", table: "Settings", status)
        case .badResponse, .responseTooLarge:
            String.localized("The server's reply couldn't be read. Is it an OpenAI-compatible API?", table: "Settings")
        case .transcriptTooLong:
            String.localized("The model's reply was cut off. Try a model that doesn't think at length, or a shorter prompt.", table: "Settings")
        }
    }
}

// MARK: - Shared HTTP

/// The bits both clients share: sending, status mapping, error-body reading.
struct BYOKHTTP: Sendable {
    /// Sent instead of URLSession's default, which names the app and its version.
    static let userAgent = "BYOK-Cleanup/1"

    /// Cap on any response body, error bodies included. Replies are a few KB; a
    /// server streaming more is broken or hostile.
    static let maxResponseBytes = 1_000_000

    /// Refuses every redirect. A redirect would replay the request, `Authorization`
    /// or `x-api-key` header and transcript included, to whatever host the server
    /// names. The 3xx response then surfaces as `BYOKClientError.http`.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        // @unchecked Sendable: stateless, no stored properties.
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// (host, model, parameter) triples a server has rejected this session, so the
    /// transcript isn't sent twice per dictation.
    private static let rejectedParameters = NSLock()
    nonisolated(unsafe) private static var rejected: Set<String> = []

    static func rejectedKey(_ baseURL: URL, model: String, parameter: String) -> String {
        "\(baseURL.host ?? "")|\(baseURL.port ?? 0)|\(model)|\(parameter)"
    }

    static func isRejected(_ key: String) -> Bool {
        rejectedParameters.lock()
        defer { rejectedParameters.unlock() }
        return rejected.contains(key)
    }

    static func markRejected(_ key: String) {
        rejectedParameters.lock()
        defer { rejectedParameters.unlock() }
        rejected.insert(key)
    }

    static func resetRejectedParameters() {
        rejectedParameters.lock()
        defer { rejectedParameters.unlock() }
        rejected = []
    }

    let session: URLSession
    /// Per-request timeout. `CleanupService` holds dictations to the provider's own
    /// (shorter) timeout; this bounds Settings' calls and offline jobs.
    let timeout: TimeInterval

    func send(_ request: URLRequest, model: String?) async throws -> Data {
        var request = request
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            let (bytes, urlResponse) = try await session.bytes(for: request, delegate: NoRedirect())
            response = urlResponse
            if urlResponse.expectedContentLength > Int64(Self.maxResponseBytes) {
                throw BYOKClientError.responseTooLarge
            }
            var buffer = Data()
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count > Self.maxResponseBytes { throw BYOKClientError.responseTooLarge }
            }
            data = buffer
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw BYOKClientError.timeout
            case .cancelled: throw CancellationError()
            default: throw BYOKClientError.unreachable("URLError \(error.code.rawValue)")
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw BYOKClientError.badResponse("not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, body: data, model: model)
        }
        return data
    }

    static func error(status: Int, body: Data, model: String?) -> BYOKClientError {
        let message = errorMessage(from: body)
        switch status {
        case 401, 403:
            return .unauthorized(status: status)
        case 400, 404, 422:
            if let model, let message, mentionsMissingModel(message) {
                return .modelNotFound(model)
            }
            return .http(status: status, message: message)
        case 408, 504:
            return .timeout
        default:
            return .http(status: status, message: message)
        }
    }

    /// The server's error text (`{"error": {"message": ...}}`, `{"error": "..."}`
    /// or `{"message": ...}`), redacted and capped.
    static func errorMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        let raw: String? = if let error = object["error"] as? [String: Any] {
            error["message"] as? String
        } else if let error = object["error"] as? String {
            error
        } else {
            object["message"] as? String
        }
        guard let raw, !raw.isEmpty else { return nil }
        return String(SecretRedactor.redact(raw).prefix(200))
    }

    static func mentionsMissingModel(_ message: String) -> Bool {
        let lower = message.lowercased()
        // Anthropic's not_found_error reads "model: <id>".
        if lower.hasPrefix("model:") { return true }
        guard lower.contains("model") else { return false }
        return lower.contains("not found") || lower.contains("does not exist")
            || lower.contains("not exist") || lower.contains("unknown model")
            || lower.contains("no such model") || lower.contains("not a valid model")
            || lower.contains("try pulling")
    }

    /// Whether a 400 is the server refusing an optional sampling parameter (newer
    /// models reject `temperature`, `max_tokens` or `effort`), worth one retry without.
    static func rejectsOptionalParameter(_ error: BYOKClientError) -> Bool {
        guard case .http(400, let message?) = error else { return false }
        let lower = message.lowercased()
        return ["temperature", "max_tokens", "effort", "output_config", "unsupported parameter", "unsupported value"]
            .contains { lower.contains($0) }
    }

    static func decodeModelIDs(_ data: Data) throws -> [String] {
        struct ModelList: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        do {
            return try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id).sorted()
        } catch {
            throw BYOKClientError.badResponse("model list")
        }
    }
}

// MARK: - OpenAI-compatible

/// `POST <base>/chat/completions`, `GET <base>/models`.
struct OpenAICompatibleClient: BYOKLLMClient {
    let baseURL: URL
    let apiKey: String?
    let http: BYOKHTTP

    init(baseURL: URL, apiKey: String?, session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.http = BYOKHTTP(session: session, timeout: timeout)
    }

    func complete(prompt: String, model: String, maxTokens: Int) async throws -> String {
        let key = BYOKHTTP.rejectedKey(baseURL, model: model, parameter: "sampling")
        if BYOKHTTP.isRejected(key) {
            return try await complete(prompt: prompt, model: model, maxTokens: maxTokens, includeSampling: false)
        }
        do {
            return try await complete(prompt: prompt, model: model, maxTokens: maxTokens, includeSampling: true)
        } catch let error as BYOKClientError where BYOKHTTP.rejectsOptionalParameter(error) {
            BYOKHTTP.markRejected(key)
            // e.g. OpenAI reasoning models: no `temperature`, `max_completion_tokens`
            // instead of `max_tokens`. Defaults are fine for a one-off cleanup.
            return try await complete(prompt: prompt, model: model, maxTokens: maxTokens, includeSampling: false)
        }
    }

    func listModels() async throws -> [String] {
        let data = try await http.send(request(path: "models", method: "GET", body: nil), model: nil)
        return try BYOKHTTP.decodeModelIDs(data)
    }

    // MARK: Request / response

    func makeCompletionRequest(prompt: String, model: String, maxTokens: Int, includeSampling: Bool) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
        if includeSampling {
            body["temperature"] = 0
            body["max_tokens"] = maxTokens
        }
        return request(path: "chat/completions", method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    static func parseCompletion(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw BYOKClientError.badResponse("chat completion")
        }
        // A reply cut at the token limit is a fragment of the transcript, not a
        // cleaned copy: inserting it would drop the rest of what was dictated.
        if response.choices.first?.finish_reason == "length" {
            throw BYOKClientError.truncated
        }
        return response.choices.first?.message.content ?? ""
    }

    private func complete(prompt: String, model: String, maxTokens: Int, includeSampling: Bool) async throws -> String {
        let request = try makeCompletionRequest(prompt: prompt, model: model, maxTokens: maxTokens, includeSampling: includeSampling)
        return try Self.parseCompletion(try await http.send(request, model: model))
    }

    private func request(path: String, method: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(BYOKHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

// MARK: - Anthropic

/// `POST <base>/messages`, `GET <base>/models`, where base is `.../v1`.
struct AnthropicClient: BYOKLLMClient {
    static let apiVersion = "2023-06-01"

    let baseURL: URL
    let apiKey: String?
    let http: BYOKHTTP

    init(baseURL: URL, apiKey: String?, session: URLSession = .shared, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.http = BYOKHTTP(session: session, timeout: timeout)
    }

    func complete(prompt: String, model: String, maxTokens: Int) async throws -> String {
        let key = BYOKHTTP.rejectedKey(baseURL, model: model, parameter: "effort")
        if BYOKHTTP.isRejected(key) {
            return try await complete(prompt: prompt, model: model, maxTokens: maxTokens, lowEffort: false)
        }
        do {
            return try await complete(prompt: prompt, model: model, maxTokens: maxTokens, lowEffort: true)
        } catch let error as BYOKClientError where BYOKHTTP.rejectsOptionalParameter(error) {
            BYOKHTTP.markRejected(key)
            // Older models (e.g. Haiku 4.5) don't take `effort`.
            return try await complete(prompt: prompt, model: model, maxTokens: maxTokens, lowEffort: false)
        }
    }

    func listModels() async throws -> [String] {
        let data = try await http.send(request(path: "models?limit=100", method: "GET", body: nil), model: nil)
        return try BYOKHTTP.decodeModelIDs(data)
    }

    // MARK: Request / response

    /// No `temperature`: current Claude models reject sampling parameters. Low effort
    /// keeps any thinking short, since a dictation waits on the reply.
    func makeMessagesRequest(prompt: String, model: String, maxTokens: Int, lowEffort: Bool) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ]
        if lowEffort {
            body["output_config"] = ["effort": "low"]
        }
        return request(path: "messages", method: "POST", body: try JSONSerialization.data(withJSONObject: body))
    }

    /// The reply's text blocks, joined. Thinking blocks are skipped.
    static func parseMessage(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String?
            }
            let content: [Block]
            let stop_reason: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw BYOKClientError.badResponse("message")
        }
        if response.stop_reason == "max_tokens" {
            throw BYOKClientError.truncated
        }
        return response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
    }

    private func complete(prompt: String, model: String, maxTokens: Int, lowEffort: Bool) async throws -> String {
        let request = try makeMessagesRequest(prompt: prompt, model: model, maxTokens: maxTokens, lowEffort: lowEffort)
        return try Self.parseMessage(try await http.send(request, model: model))
    }

    private func request(path: String, method: String, body: Data?) -> URLRequest {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var url = baseURL.appending(path: parts[0])
        if parts.count > 1, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.query = parts[1]
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(BYOKHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        return request
    }
}
