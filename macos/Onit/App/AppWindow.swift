// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppWindow.swift
//  Onit
//
//  Created by Loyd Kim on 4/28/26.
//

final class AppWindow: CenteredWindow<AppWindowView> {
    init() {
        super.init(
            rootView: AppWindowView(),
            canResize: true,
            canCloseWithEsc: false,
            windowSize: (
                width: 1130,
                height: 750
            ),
            titleBarButtonsOffset: (
                xOffset: 10,
                yOffset: 4
            )
        )
    }
}
