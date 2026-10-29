// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ASRModelTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-05-18.
//

import Foundation
import Testing
@testable import Onit

struct ASRModelTests {

    // MARK: - Catalog Integrity

    @Test("Catalog contains exactly the five expected models")
    func catalogContainsAllExpectedModels() {
        let ids = ASRModel.catalog.map(\.id)
        #expect(ids.contains("parakeet-v3"))
        #expect(ids.contains("whisper-large-turbo-v3"))
        #expect(ids.contains("whisper-medium"))
        #expect(ids.contains("moonshine-base"))
        #expect(ids.contains("qwen3-asr-0.6b"))
        #expect(ids.count == 5)
    }

    @Test("All catalog IDs are unique")
    func catalogIdsAreUnique() {
        let ids = ASRModel.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Exactly one model is flagged as default")
    func exactlyOneDefaultModel() {
        let defaults = ASRModel.catalog.filter(\.isDefault)
        #expect(defaults.count == 1)
        #expect(defaults.first?.id == "parakeet-v3")
    }

    @Test("Default model id matches the static accessor")
    func defaultIdMatchesAccessor() {
        #expect(ASRModel.defaultModel.id == ASRModel.defaultModelId)
    }

    // MARK: - Lookup

    @Test("Lookup by id returns the matching model")
    func lookupById() {
        let parakeet = ASRModel.byId("parakeet-v3")
        #expect(parakeet?.displayName == "Parakeet v3")
    }

    @Test("Lookup by unknown id returns nil")
    func lookupByUnknownIdReturnsNil() {
        #expect(ASRModel.byId("does-not-exist") == nil)
    }

    // MARK: - Backend Mapping

    @Test("Parakeet v3 maps to .parakeetCoreML backend")
    func parakeetMapsToParakeetCoreMLBackend() {
        #expect(ASRModel.byId("parakeet-v3")?.backend == .parakeetCoreML)
    }

    @Test("Whisper models map to .whisperCoreML backend")
    func whisperModelsMapToWhisperBackend() {
        #expect(ASRModel.byId("whisper-large-turbo-v3")?.backend == .whisperCoreML)
        #expect(ASRModel.byId("whisper-medium")?.backend == .whisperCoreML)
    }

    @Test("Moonshine Base maps to .moonshineONNX backend")
    func moonshineBaseMapsToMoonshineBackend() {
        #expect(ASRModel.byId("moonshine-base")?.backend == .moonshineONNX)
    }

    @Test("Moonshine Base is English only")
    func moonshineBaseIsEnglishOnly() {
        #expect(ASRModel.byId("moonshine-base")?.isMultilingual == false)
    }

    // MARK: - Language Coverage

    @Test("Parakeet v3 is multilingual")
    func parakeetIsMultilingual() {
        #expect(ASRModel.byId("parakeet-v3")?.isMultilingual == true)
    }

    @Test("Whisper Large Turbo v3 is English only")
    func whisperLargeTurboV3IsEnglishOnly() {
        #expect(ASRModel.byId("whisper-large-turbo-v3")?.isMultilingual == false)
    }

    @Test("Whisper Medium is multilingual")
    func whisperMediumIsMultilingual() {
        #expect(ASRModel.byId("whisper-medium")?.isMultilingual == true)
    }

    // MARK: - Ratings

    @Test("Speed and accuracy ratings stay within 0...4 range")
    func ratingsAreClampedToValidRange() {
        for model in ASRModel.catalog {
            #expect((0...4).contains(model.speedRating), "speed out of range for \(model.id)")
            #expect((0...4).contains(model.accuracyRating), "accuracy out of range for \(model.id)")
        }
    }

    // MARK: - Display Metadata

    @Test("Every model carries a non-empty short description")
    func nonEmptyShortDescription() {
        for model in ASRModel.catalog {
            #expect(!model.shortDescription.isEmpty, "empty description for \(model.id)")
        }
    }

    @Test("Every model declares a positive on-disk size")
    func positiveSizeBytes() {
        for model in ASRModel.catalog {
            #expect(model.sizeBytes > 0, "non-positive size for \(model.id)")
        }
    }
}
