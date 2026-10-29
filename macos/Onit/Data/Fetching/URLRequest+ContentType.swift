// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  URLRequest+ContentType.swift
//  Onit
//
//  Created by Benjamin Sage on 10/2/24.
//

import Foundation

extension URLRequest {
    mutating func addContentType(for method: HTTPMethod, defaultType: String) {
        guard method.requiresContentType else { return }
        setValue(defaultType, forHTTPHeaderField: "Content-Type")
    }
}
