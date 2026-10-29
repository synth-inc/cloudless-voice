// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
import Defaults
import Foundation
import SwiftData

/// A custom OpenAI-compatible provider from the old Onit sidebar app. Its API token
/// is no longer stored (`LegacyProviderTokenWipe` deleted any saved ones).
class CustomProvider: Codable, Identifiable, Defaults.Serializable {
    var id: String { name }

    var name: String
    var baseURL: String
    var models: [AIModel]
    var isEnabled: Bool

    init(name: String, baseURL: String, models: [AIModel]) {
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.isEnabled = true
    }

    static func == (lhs: CustomProvider, rhs: CustomProvider) -> Bool {
        return lhs.name == rhs.name && lhs.baseURL == rhs.baseURL
            && lhs.models == rhs.models
            && lhs.isEnabled == rhs.isEnabled
    }
}
