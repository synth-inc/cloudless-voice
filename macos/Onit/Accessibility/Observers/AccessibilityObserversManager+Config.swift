// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AccessibilityObserversManager+Config.swift
//  Onit
//
//  Created by Kévin Naudin on 08/05/2025.
//

import ApplicationServices

extension AccessibilityObserversManager {

    struct Config {
        
        static let notifications: [String] = [
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXTitleChangedNotification

//            kAXSelectedColumnsChangedNotification,
//            kAXSelectedRowsChangedNotification,
//            kAXAnnouncementRequestedNotification,
//            kAXApplicationActivatedNotification,
//            kAXApplicationDeactivatedNotification,
//            kAXApplicationHiddenNotification,
//            kAXApplicationShownNotification,
//            kAXCreatedNotification,
//            kAXDrawerCreatedNotification,
//            kAXHelpTagCreatedNotification,
//            kAXLayoutChangedNotification,
//            kAXMenuClosedNotification,
//            kAXMenuItemSelectedNotification,
//            kAXMenuOpenedNotification,
//            kAXMovedNotification,
//            kAXResizedNotification,
//            kAXRowCollapsedNotification,
//            kAXRowCountChangedNotification,
//            kAXRowExpandedNotification,
//            kAXSelectedCellsChangedNotification,
//            kAXSelectedChildrenChangedNotification,
//            kAXSelectedChildrenMovedNotification,
//            kAXSheetCreatedNotification,
//            kAXUnitsChangedNotification,
//            kAXWindowDeminiaturizedNotification,
//            kAXWindowMiniaturizedNotification
        ]
    }
}
