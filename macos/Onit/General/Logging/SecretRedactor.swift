// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SecretRedactor.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  Masks anything shaped like an API key before it reaches a log. Applied by the
//  app's log destinations (`RedactingConsoleDestination`, `RedactingFileDestination`)
//  and to server error text the BYOK clients keep.
//

import Foundation
import SwiftyBeaver

enum SecretRedactor {
    static let mask = "[REDACTED]"

    /// Key-shaped substrings: provider key prefixes (OpenAI / Anthropic / OpenRouter
    /// `sk-…`, Groq `gsk_…`, Google `AIza…`, Hugging Face `hf_…`), and the value
    /// after `Bearer`, `x-api-key`, an `api_key=` style assignment or a credential URL query item.
    private static let patterns: [NSRegularExpression] = [
        #"\b(?:sk|gsk|hf|xai|pk)[-_][A-Za-z0-9_\-]{16,}"#,
        #"\bAIza[0-9A-Za-z_\-]{30,}"#,
        #"(?i)(?<=\bbearer\s)[A-Za-z0-9._~+/=\-]{12,}"#,
        #"(?i)(?<=x-api-key[\"']?\s?[:=]\s?[\"']?)[A-Za-z0-9._\-]{12,}"#,
        #"(?i)(?<=api[_-]?key[\"']?\s?[:=]\s?[\"']?)[A-Za-z0-9._\-]{12,}"#,
        // URL query items carrying a credential, e.g. `?key=...` or `&access_token=...`.
        #"(?i)(?<=[?&](?:key|token|access_token|id_token|auth)=)[^&\s\"'<>]{8,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func redact(_ text: String) -> String {
        // Cheap gate: nearly every log line has none of these.
        let lower = text.lowercased()
        guard lower.contains("sk-") || lower.contains("sk_") || lower.contains("gsk_") || lower.contains("hf_")
                || lower.contains("xai-") || lower.contains("pk-") || lower.contains("pk_") || text.contains("AIza")
                || lower.contains("bearer") || lower.contains("api-key") || lower.contains("api_key")
                || lower.contains("apikey") || lower.contains("key=") || lower.contains("token=")
                || lower.contains("auth=")
        else { return text }

        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: mask)
        }
        return result
    }
}

// MARK: - Log destinations

/// Console output with key-shaped strings masked.
final class RedactingConsoleDestination: ConsoleDestination {
    override func send(
        _ level: SwiftyBeaver.Level, msg: String, thread: String,
        file: String, function: String, line: Int, context: Any? = nil
    ) -> String? {
        super.send(level, msg: SecretRedactor.redact(msg), thread: thread, file: file, function: function, line: line, context: context)
    }
}

/// File output with key-shaped strings masked.
final class RedactingFileDestination: FileDestination {
    override func send(
        _ level: SwiftyBeaver.Level, msg: String, thread: String,
        file: String, function: String, line: Int, context: Any? = nil
    ) -> String? {
        super.send(level, msg: SecretRedactor.redact(msg), thread: thread, file: file, function: function, line: line, context: context)
    }
}
