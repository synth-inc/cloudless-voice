// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TermHumanizer.swift
//  Onit
//
//  Renders a written term the way a person would SAY it: split camelCase and
//  separator-joined tokens, read digit groups as number words. The alias
//  predictor works in this spoken space - the ASR hears "luck wise", never
//  "Lukwise". Port of the humanizer that generated the v8 alias-prediction
//  eval's TTS ground truth, kept rule-for-rule identical so the eval numbers
//  transfer.
//

import Foundation

enum TermHumanizer {

    private static let ones = ["zero", "one", "two", "three", "four", "five",
                               "six", "seven", "eight", "nine"]
    private static let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen",
                                "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["zero", "ten", "twenty", "thirty", "forty", "fifty",
                               "sixty", "seventy", "eighty", "ninety"]

    /// English words for 0..<1000; larger numbers are read digit-by-digit.
    static func numberWords(_ n: Int) -> String {
        if n < 10 { return ones[n] }
        if n < 20 { return teens[n - 10] }
        if n < 100 {
            let s = tens[n / 10]
            return n % 10 == 0 ? s : s + " " + ones[n % 10]
        }
        if n < 1000 {
            let s = ones[n / 100] + " hundred"
            return n % 100 == 0 ? s : s + " " + numberWords(n % 100)
        }
        return String(n).map { ones[Int(String($0))!] }.joined(separator: " ")
    }

    private static func spellDigits(_ digits: String) -> String {
        digits.compactMap { Int(String($0)).map { ones[$0] } }.joined(separator: " ")
    }

    /// Digit part of a mixed alphanumeric token ("v4", "S3"): number words
    /// below 1000, otherwise kept as digits (matching the reference script).
    private static func numberToken(_ digits: String) -> String {
        guard let n = Int(digits), n < 1000 else { return digits }
        return numberWords(n)
    }

    private static let camelBoundary = try! NSRegularExpression(pattern: "([a-z0-9])([A-Z])")
    private static let acronymBoundary = try! NSRegularExpression(pattern: "([A-Z]+)([A-Z][a-z])")
    private static let separators = try! NSRegularExpression(pattern: "[-_./]+")
    private static let digitsThenAlpha = try! NSRegularExpression(pattern: "^([0-9]+)([a-zA-Z]+)$")
    private static let alphaThenDigits = try! NSRegularExpression(pattern: "^([a-zA-Z]+)([0-9]+)$")

    private static func replace(_ s: String, _ regex: NSRegularExpression, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// "Qwen3ASR" → "Qwen3 ASR" → tokens; "v4.2" → "v four two"… The result is
    /// a space-separated spoken rendering (original casing preserved for
    /// alphabetic tokens - callers lowercase as needed).
    static func humanize(_ term: String) -> String {
        var s = replace(term, camelBoundary, with: "$1 $2")
        s = replace(s, acronymBoundary, with: "$1 $2")
        s = replace(s, separators, with: " ")
        s = s.trimmingCharacters(in: .whitespaces)

        var out: [String] = []
        for tok in s.split(separator: " ").map(String.init) {
            if tok.allSatisfy(\.isNumber) {
                if let n = Int(tok), n < 1000 {
                    out.append(numberWords(n))
                } else {
                    out.append(spellDigits(tok))
                }
            } else if let m = digitsThenAlpha.firstMatch(
                in: tok, range: NSRange(tok.startIndex..., in: tok)),
                let dr = Range(m.range(at: 1), in: tok), let ar = Range(m.range(at: 2), in: tok) {
                out.append(numberToken(String(tok[dr])) + " " + tok[ar])
            } else if let m = alphaThenDigits.firstMatch(
                in: tok, range: NSRange(tok.startIndex..., in: tok)),
                let ar = Range(m.range(at: 1), in: tok), let dr = Range(m.range(at: 2), in: tok) {
                out.append(tok[ar] + " " + numberToken(String(tok[dr])))
            } else {
                out.append(tok)
            }
        }
        return out.isEmpty ? term : out.joined(separator: " ")
    }
}
