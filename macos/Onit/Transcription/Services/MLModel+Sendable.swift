// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MLModel+Sendable.swift
//  Onit
//
//  Created by Kévin Naudin on 10/04/2026.
//
//  Retroactive `Sendable` conformance for `CoreML.MLModel`.
//
//  `MLModel` is documented by Apple as thread-safe - concurrent calls to
//  `prediction(from:)` are explicitly supported - but the framework still
//  hasn't shipped a `Sendable` annotation. Under Swift 6 strict concurrency,
//  every `await model.prediction(...)` from an actor-isolated context fails
//  with "sending 'model' risks causing data races".
//
//  Marking the type `@unchecked Sendable` here lifts the diagnostic without
//  changing runtime behaviour. The `@retroactive` attribute is required
//  because both `MLModel` and `Sendable` come from modules outside `Onit`.
//

import CoreML

extension MLModel: @retroactive @unchecked Sendable {}
