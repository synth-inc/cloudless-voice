// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Hint+Permissions.swift
//  Onit
//
//  Created by Loyd Kim on 1/29/26.
//

/*
 * Public Variables
 */

extension Hint {
    // MARK: - Public Variables
    
    var accessibilityPermissionLost: Bool {
        return accessibilityPermissionManager.accessibilityPermissionStatus == .denied
    }
  
    /// Commented out for now until non-AX becomes the default state.
//    private var screenRecordingPermissionLost: Bool {
//        return
//            Defaults[.quickEditConfig].isEnabled &&
//            !screenRecordingPermissionManager.isScreenRecordingEnabled
//    }

    var microphonePermissionLost: Bool {
        return transcriptionEnabled && !microphoneInputManager.hasPermission
    }
}
