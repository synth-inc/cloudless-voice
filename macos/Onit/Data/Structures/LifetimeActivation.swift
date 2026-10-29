// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  LifetimeActivation.swift
//  Onit
//
//  Created by Loyd Kim on 4/8/26.
//

import Foundation

struct LifetimeActivation: Codable {
    let seatNumber: Int
    let productName: ReferralProductName
    let isActive: Bool
    let cap: Int
}
