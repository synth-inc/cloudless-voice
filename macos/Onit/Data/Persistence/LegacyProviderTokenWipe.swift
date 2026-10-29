// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  LegacyProviderTokenWipe.swift
//  Onit
//
//  One-time launch step that deletes the remote-provider API tokens the old Onit
//  sidebar app kept in UserDefaults (plus their validation flags and "use" switches),
//  and strips the token from every saved custom provider. Nothing reads these values
//  any more, so they should not stay on disk. Runs once, then marks itself done.
//

import Foundation

enum LegacyProviderTokenWipe {

    /// Set once the wipe has run, so later launches skip it.
    static let doneKey = "legacyProviderTokensWiped"

    /// Storage key of `Defaults.Keys.availableCustomProviders`.
    static let customProvidersKey = "availableCustomProvider"

    /// UserDefaults names of the retired provider keys. Never reuse them.
    static let retiredKeys: [String] = [
        // API tokens
        "openAIToken", "anthropicToken", "xAIToken", "googleAIToken",
        "deepSeekToken", "perplexityToken", "cerebrasToken",
        // Token validation flags
        "openAITokenValidated", "anthropicTokenValidated", "xAITokenValidated",
        "googleAITokenValidated", "deepSeekTokenValidated", "perplexityTokenValidated",
        "cerebrasTokenValidated",
        // Per-provider "use" switches
        "useOpenAI", "useAnthropic", "useXAI", "useGoogleAI",
        "useDeepSeek", "usePerplexity", "useCerebras",
    ]

    /// Fields removed from each stored custom provider.
    static let customProviderTokenFields = ["token", "isTokenValidated"]

    static func runIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }

        for key in retiredKeys {
            defaults.removeObject(forKey: key)
        }
        scrubCustomProviders(in: defaults)

        defaults.set(true, forKey: doneKey)
    }

    /// `Defaults` stores `[CustomProvider]` as an array of JSON strings, one per
    /// provider. Rewrite each without its token fields. Anything in an unexpected
    /// shape can't be shown to be token-free, so the whole list is removed instead.
    private static func scrubCustomProviders(in defaults: UserDefaults) {
        guard let stored = defaults.object(forKey: customProvidersKey) else { return }
        guard let entries = stored as? [Any] else {
            defaults.removeObject(forKey: customProvidersKey)
            return
        }

        var cleaned: [String] = []
        for entry in entries {
            guard let json = entry as? String,
                  let data = json.data(using: .utf8),
                  var provider = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                defaults.removeObject(forKey: customProvidersKey)
                return
            }
            for field in customProviderTokenFields {
                provider.removeValue(forKey: field)
            }
            guard let out = try? JSONSerialization.data(withJSONObject: provider),
                  let outJSON = String(data: out, encoding: .utf8)
            else {
                defaults.removeObject(forKey: customProvidersKey)
                return
            }
            cleaned.append(outJSON)
        }
        defaults.set(cleaned, forKey: customProvidersKey)
    }
}
