// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  UploadBody.swift
//  Onit
//
//  Created by Benjamin Sage on 10/29/24.
//

import Foundation

enum UploadBody {
    case data(Data)
    case url(URL)
    case empty
}
