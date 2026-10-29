// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AccessibilityPermissionStatus.swift
//  Onit
//
//  Created by Kévin Naudin on 22/01/2025.
//

/// Enumeration of the Accessibility permission's status
/// Default status is `.notDetermined`
enum AccessibilityPermissionStatus: String {
    case notDetermined
    case denied
    case granted
}
