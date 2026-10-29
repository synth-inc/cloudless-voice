// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppEmptyResultsView.swift
//  Onit
//
//  Created by Loyd Kim on 5/14/26.
//

import SwiftUI

struct AppEmptyResultsView<Children: View>: View {
    // MARK: - Properties
    
    private let iconSystemName: String
    private let title: String
    private let subtitle: String?
    @ViewBuilder private let children: () -> Children
    
    // MARK: - Initializer
    
    init(
        iconSystemName: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder children: @escaping () -> Children = { EmptyView() }
    ) {
        self.iconSystemName = iconSystemName
        self.title = title
        self.subtitle = subtitle
        self.children = children
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: iconSystemName)
                .styleText(
                    size: 16
                )
                .frame(width: 32, alignment: .center)
                .frame(height: 32, alignment: .center)
                .background(Color.special2)
                .cornerRadius(9)
            
            Text(title)
                .styleText()
            
            if let subtitle {
                Text(subtitle)
                    .styleText(
                        size: 13,
                        weight: .regular,
                        color: Color.T_1
                    )
            }
            
            children()
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: 200, alignment: .center)
    }
}
