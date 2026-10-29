// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  StopMode.swift
//  Onit
//
//  Created by OpenAI on 2023-11-20.
//

import Defaults

enum StopMode: String, CaseIterable, Codable, Defaults.Serializable {
    case removePartial
    case leavePartial
}
