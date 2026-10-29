// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  NSScreen+Helper.swift
//  Onit
//
//  Created by Kévin Naudin on 16/04/2025.
//

import SwiftUI

extension NSScreen {
    
    static var primary: NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.origin.x == 0 && screen.frame.origin.y == 0
        }
    }
    
    static var mouse: NSScreen? {
        NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 1))
            .findScreen()
    }
    
    static var rightmostScreen: NSScreen? {
        NSScreen.screens.max(by: { $0.frame.origin.x + $0.frame.width < $1.frame.origin.x + $1.frame.width})
    }
}
