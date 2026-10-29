// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  DictationPlanCopy.swift
//  Onit
//

import Foundation

/// "Why does this cost money" copy, shared by the Hint paywall popover and
/// Settings > Plan & Billing. Keep in sync with the marketing site.
///
/// Dictation is free and unlimited; the paid plan is Smart Cleanup.
@MainActor
enum DictationPlanCopy {
    static var whyTitle: String { String.localized("Why does this cost money", table: "Settings") }

    /// Sign-off shown under both versions. Two lines.
    static let signatureName = "- Tim L"
    static var signatureRole: String { String.localized("Founder, Cloudless", table: "Settings") }

    static var whyLongTitle: String { String.localized("Why does Cloudless cost money", table: "Settings") }

    static var whyLong: [String] { [
        "Dictation in Cloudless is free and unlimited. Smart Cleanup, which fixes punctuation, formatting, numbers and filler words on your Mac, is what we charge for. Keeping it at the frontier, with the latest models running entirely on your Mac, is continuous work by a small team. A free app can't fund that; an ongoing relationship can.",
        "We've set Pro at less than half of what the major cloud dictation products charge, and it's the only way we make money. We don't sell your data, because we never see it. Without paying users, there is no company and no next version.",
        "There's a bigger reason too. Ask why there are so few great privacy-first products and the honest answer is that privacy-conscious users often refuse to pay for them, so they quietly die, while the apps that don't respect your privacy keep growing. Paying for Cloudless is a vote for products that don't send your personal data to the cloud and train models on it."
    ].map { String.localized($0, table: "Settings") } }
}

/// Copy for the Smart Cleanup upgrade card, by refusal reason. The price comes from
/// `DictationPlan`, the free allowance from the TranscriptionCleanup library.
@MainActor
enum SmartCleanupPaywallCopy {
    static func title(for reason: SmartCleanupDenialReason) -> String {
        switch reason {
        case .freeAllowanceUsed:
            if let words = SmartCleanupEntitlement.freeWordsPerMonth {
                return String(
                    format: String.localized("You've used your %@ free Smart Cleanup words this month.", table: "Settings"),
                    words.formatted()
                )
            }
            return String.localized("You've used your free Smart Cleanup words this month.", table: "Settings")
        case .freeTierRequiresSignedBuild:
            return String.localized("Smart Cleanup needs a subscription in this build.", table: "Settings")
        }
    }

    static func body(for reason: SmartCleanupDenialReason) -> String {
        switch reason {
        case .freeAllowanceUsed:
            return String(
                format: String.localized("Your dictation was pasted without Smart Cleanup. Unlimited Smart Cleanup is %@. 100%% local, 100%% private.", table: "Settings"),
                DictationPlan.monthlyPriceWithPeriod
            )
        case .freeTierRequiresSignedBuild:
            return SmartCleanupSignedBuildCopy.explanation
        }
    }
}
