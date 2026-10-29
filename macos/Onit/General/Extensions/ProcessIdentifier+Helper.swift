// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ProcessIdentifier+Helper.swift
//  Onit
//
//  Created by Kévin Naudin on 13/05/2025.
//

import AppKit

extension pid_t {
    var appName: String? {
        NSRunningApplication(processIdentifier: self)?.localizedName
    }
    
    var bundleIdentifier: String? {
        NSRunningApplication(processIdentifier: self)?.bundleIdentifier
    }
}
