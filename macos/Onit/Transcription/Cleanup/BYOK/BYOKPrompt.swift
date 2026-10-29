// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  BYOKPrompt.swift
//  Onit
//
//  Created by Tim Lenardo on 2026-10-19.
//
//  The prompt sent with each dictation. Two layers: the user's instructions
//  (the bundled `byok-cleanup-instructions.txt` or their edit of it) go into the
//  script (`byok-cleanup-prompt.txt`, or their edit of it), which adds the
//  transcript and asks for the result between the output markers.
//

import Foundation

enum BYOKPrompt {
    /// Placeholders a template may use.
    enum Placeholder {
        /// The user's instructions, inside the script.
        static let instructions = "{{instructions}}"
        static let transcript = "{{transcript}}"
        static let language = "{{language}}"
        /// Filled only when "Send my dictionary" is on.
        static let vocabulary = "{{vocabulary}}"
        /// Filled only when "Send the app name" is on.
        static let appName = "{{app_name}}"
    }

    /// Used if the bundled files are missing (they never should be).
    private static let fallbackInstructions = """
        Fix punctuation, capitalisation and obvious speech-recognition errors in this dictated \
        {{language}} text. Don't rephrase.
        """
    private static let fallbackTemplate = """
        {{instructions}}

        <transcript>
        {{transcript}}
        </transcript>

        Put the final text between <output> and </output>. Only what is between those tags is used.
        """

    /// The bundled default instructions: the rules the model cleans by.
    static let defaultInstructions: String = bundled("byok-cleanup-instructions") ?? fallbackInstructions

    /// The bundled default script: where the instructions, the transcript and the
    /// request for output markers go.
    static let defaultTemplate: String = bundled("byok-cleanup-prompt") ?? fallbackTemplate

    private static func bundled(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// What's filled into a template. Optional values are nil when their toggle is off.
    struct Values: Equatable {
        var instructions: String = BYOKPrompt.defaultInstructions
        var transcript: String
        var language: String
        var vocabulary: [String]?
        var appName: String?
    }

    /// Fills `template`.
    ///
    /// A line whose optional placeholder has no value (toggle off, empty dictionary,
    /// unknown app) is dropped whole, so the model never sees "Spell these terms: ".
    /// A template without `{{transcript}}` gets the transcript appended, so an edit
    /// can't silently stop sending it. One without `{{instructions}}` gets them in
    /// front, unless they're empty.
    static func render(_ template: String, _ values: Values) -> String {
        let instructions = values.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        var template = template
        if template.contains(Placeholder.instructions) {
            template = template.replacingOccurrences(of: Placeholder.instructions, with: instructions)
        } else if !instructions.isEmpty {
            template = instructions + "\n\n" + template
        }
        let vocabulary = values.vocabulary?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let vocabularyText = (vocabulary?.isEmpty ?? true)
            ? nil : vocabulary?.joined(separator: ", ")
        // The single pass below never re-expands a value, so a placeholder typed in the
        // vocabulary or app name stays literal and cannot inject the transcript twice.
        let appName = values.appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let optional: [(String, String?)] = [
            (Placeholder.vocabulary, vocabularyText),
            (Placeholder.appName, (appName?.isEmpty ?? true) ? nil : appName),
        ]

        // Drop the lines whose optional value is missing.
        var lines: [String] = []
        for line in template.components(separatedBy: "\n") {
            if optional.contains(where: { line.contains($0.0) && $0.1 == nil }) { continue }
            lines.append(line)
        }
        let body = lines.joined(separator: "\n")

        // The transcript can't close its own tag and smuggle text outside it.
        let transcript = values.transcript.replacingOccurrences(
            of: "</transcript>", with: "</ transcript>", options: .caseInsensitive
        )
        let hasTranscript = body.contains(Placeholder.transcript)

        // One pass over the template: a placeholder-like string inside a value
        // (a dictionary word, an app name, the transcript) is never expanded again.
        let replacements: [String: String] = [
            Placeholder.transcript: transcript,
            Placeholder.language: values.language,
            Placeholder.vocabulary: vocabularyText ?? "",
            Placeholder.appName: (appName?.isEmpty ?? true) ? "" : appName ?? "",
        ]
        var text = ""
        var cursor = body.startIndex
        for match in placeholderPattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let range = Range(match.range, in: body) else { continue }
            text += body[cursor..<range.lowerBound]
            text += replacements[String(body[range])] ?? ""
            cursor = range.upperBound
        }
        text += body[cursor...]

        if !hasTranscript {
            text += "\n\n<transcript>\n\(transcript)\n</transcript>"
        }
        return text
    }

    private static let placeholderPattern = try! NSRegularExpression(
        pattern: [Placeholder.transcript, Placeholder.language, Placeholder.vocabulary, Placeholder.appName]
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    ) // try!: the pattern is built from four constant literals, escaped.

    /// English name of the dictation language, for `{{language}}`.
    ///
    /// French when cleanup runs French rules; otherwise the single language the
    /// user locked dictation to, when there is one. Auto-detect gets a neutral
    /// phrase rather than "English", which could make a model translate.
    static func languageName(locale: CleanupLocale, dictationLanguages: [String]) -> String {
        if locale == .french { return "French" }
        if dictationLanguages.count == 1, let code = dictationLanguages.first,
           let name = Locale(identifier: "en").localizedString(forLanguageCode: code) {
            return name
        }
        return "the language it was dictated in"
    }
}
