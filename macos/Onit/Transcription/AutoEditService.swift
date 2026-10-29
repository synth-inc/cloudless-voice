// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AutoEditService.swift
//  Onit
//

#if DEBUG || ONIT_BETA
import Defaults
import Foundation

@MainActor
final class AutoEditService {

    static let shared = AutoEditService()

    private let streamingClient = StreamingClient()

    private static let systemPrompt = "Fix and improve text. Reply with corrected version only."

    /// Returns true if the response looks like a chatbot multi-option reply rather than plain improved text.
    private static func looksLikeChatbotResponse(_ text: String) -> Bool {
        let lower = text.lowercased()
        let bodySignals = ["option 1", "option 2", "**option", "let me know if you",
                           "i've focused on", "i have focused on", "feel free to"]
        return bodySignals.contains(where: { lower.contains($0) })
    }

    /// Strips common chatbot preamble phrases that leak through despite the system prompt.
    private static func stripChatPreamble(from text: String) -> String {
        let prefixes = [
            "here is the improved text:",
            "here's the improved text:",
            "here is the edited text:",
            "here's the edited text:",
            "here is the revised text:",
            "here's the revised text:",
            "here is the corrected text:",
            "here's the corrected text:",
            "here are a few options",
            "here are some options",
            "sure! here",
            "sure, here",
            "of course! here",
            "of course, here",
            "certainly! here",
            "certainly, here",
            "i've improved",
            "i have improved",
            "i've edited",
            "i have edited",
        ]
        let lower = text.lowercased()
        for prefix in prefixes {
            if lower.hasPrefix(prefix) {
                // Drop the preamble and any trailing colon/newline separator
                let rest = text.dropFirst(prefix.count)
                    .drop(while: { $0 == ":" || $0 == "\n" || $0 == " " })
                if !rest.isEmpty { return String(rest) }
            }
        }
        return text
    }

    func improve(_ text: String) async -> String {
        guard !text.isEmpty else { return text }
        guard let localModel = Defaults[.autoeditLocalModel] else { return text }

        let improvePrompt = Defaults[.autoeditPrompt]
        // INPUT:/OUTPUT: sentinel format: model fills in after OUTPUT: so preamble is structurally impossible.
        let instruction = "\(improvePrompt)\n\nINPUT: \(text)\nOUTPUT:"

        do {
            let stream = try await streamingClient.localChat(
                systemMessage: Self.systemPrompt,
                instructions: [instruction],
                inputs: [nil],
                files: [[]],
                images: [[]],
                autoContexts: [[:]],
                webSearchContexts: [[]],
                responses: [],
                model: localModel,
                tools: []
            )

            var result = ""
            for try await response in stream {
                if let content = response.content {
                    result += content
                }
            }

            // The model streams starting after "OUTPUT:" so the result is already the bare text.
            // Strip markdown and trim, then apply preamble fallback for safety.
            var cleaned = result.stripMarkdown().trimmingCharacters(in: .whitespacesAndNewlines)
            // If the model echoed "OUTPUT:" in its response, strip it.
            if cleaned.uppercased().hasPrefix("OUTPUT:") {
                cleaned = String(cleaned.dropFirst("OUTPUT:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let stripped = Self.stripChatPreamble(from: cleaned)
            let final = stripped.isEmpty ? text : stripped
            // If response still looks like a multi-option chatbot reply, discard it.
            if Self.looksLikeChatbotResponse(final) { return text }
            return final
        } catch {
            return text
        }
    }
}
#endif
