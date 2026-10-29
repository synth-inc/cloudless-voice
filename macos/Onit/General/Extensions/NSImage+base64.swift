// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  NSImage+base64.swift
//  Onit
//
//  Created by Timothy Lenardo on 11/16/24.
//

import Foundation
import PhotosUI

extension NSImage {

    func base64String() -> String? {
        guard
            let bits = self.representations.first as? NSBitmapImageRep,
            let data = bits.representation(
                using: .jpeg, properties: [NSBitmapImageRep.PropertyKey.compressionFactor: 1.0])
        else {
            return nil
        }

        return "\(data.base64EncodedString())"
    }
}
