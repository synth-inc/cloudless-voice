// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  LoginResponse.swift
//  Onit
//
//  Created by Jason Swanson on 4/22/25.
//

struct LoginResponse: Codable {
    let token: String
    let account: Account
    let isNewAccount: Bool
}
