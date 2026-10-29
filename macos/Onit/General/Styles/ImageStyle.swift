// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ImageStyle.swift
//  Onit
//
//  Created by Loyd Kim on 4/15/25.
//

import SwiftUI

extension Image {
    func addIconStyles(
        foregroundColor: Color = Color.S_0,
        iconSize: CGFloat = 20
    ) -> some View {
        self
            .resizable()
            .renderingMode(.template)
            .foregroundColor(foregroundColor)
            .frame(width: iconSize, height: iconSize)
    }
}
