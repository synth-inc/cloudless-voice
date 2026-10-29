// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppHomeSectionHeader.swift
//  Onit
//
//  Created by Loyd Kim on 5/14/26.
//

import SwiftUI

struct AppHomeSectionHeader<Children: View>: View {
    // MARK: - Properties
    
    private let iconSystemName: String
    private let title: String
    private var isHidden: Bool
    @ViewBuilder private let children: () -> Children
    
    // MARK: - Initializer
    
    init(
        iconSystemName: String,
        title: String,
        isHidden: Bool = false,
        @ViewBuilder children: @escaping () -> Children = { EmptyView() }
    ) {
        self.iconSystemName = iconSystemName
        self.title = title
        self.isHidden = isHidden
        self.children = children
    }
    
    // MARK: - Body
    
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: isHidden ? "eye.slash" : iconSystemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.S_0.opacity(isHidden ? 0.4 : 1.0))

            Text(title)
                .styleText(
                    size: 14,
                    weight: .regular,
                    color: Color.S_0.opacity(isHidden ? 0.4 : 1.0)
                )

            Spacer()

            children()
        }
        .padding(.leading, 6)
        .frame(height: 28, alignment: .center)
    }
}
