// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSupportSocialContributionView.swift
//  Onit
//
//  Created by Loyd Kim on 5/8/26.
//

import SwiftUI

struct AppSupportSocialContributionView<Children: View>: View {
    // MARK: - Types
    
    struct FooterButton {
        let text: String
        let action: () -> Void
    }
    
    // MARK: - Properties
    
    private let icon: ImageResource
    private let iconColor: Color?
    private let title: String
    private let description: String?
    private let footerButton: FooterButton?
    @ViewBuilder private let children: () -> Children
    private let action: () -> Void
    
    // MARK: - Initializers
    
    init(
        icon: ImageResource,
        iconColor: Color? = nil,
        title: String,
        description: String? = nil,
        footerButton: FooterButton? = nil,
        
        @ViewBuilder children: @escaping () -> Children = {
            EmptyView()
        },
        
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.description = description
        self.footerButton = footerButton
        
        self.children = children
        self.action = action
    }
    
    init(
        icon: ImageResource,
        iconColor: Color? = nil,
        title: String,
        description: String? = nil,
        footerButton: FooterButton? = nil,
        action: @escaping () -> Void
    ) where Children == EmptyView {
        self.init(
            icon: icon,
            iconColor: iconColor,
            title: title,
            description: description,
            footerButton: footerButton,
            children: { EmptyView() },
            action: action
        )
    }
    
    // MARK: - States
    
    @State private var isHovered: Bool = false
    @State private var isPressed: Bool = false
    
    // MARK: - Private Variables
    
    private let cornerRadius: CGFloat = 22
    private let headerIconWidth: CGFloat = 20
    private let footerHeight: CGFloat = 28
    
    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView
            descriptionView
            children()
            footerView
        }
        .padding(16)
        .frame(width: 250, alignment: .leading)
        .frame(height: 132, alignment: .top)
        .addButtonEffects(
            background: Color.special1,
            hoverBackground: Color.S_0.opacity(0.05),
            cornerRadius: cornerRadius,
            isHovered: $isHovered,
            isPressed: $isPressed
        ) {
            action()
        }
        .addBorder(
            cornerRadius: cornerRadius,
            stroke: Color.T_8
        )
    }
    
    // MARK: - Child Components: Header View
    
    private var headerView: some View {
        HStack(alignment: .center, spacing: 8) {
            headerViewIcon

            Text(title)
                .styleText(
                    weight: .regular
                )
                .truncateText()
        }
    }
    
    @ViewBuilder
    private var headerViewIcon: some View {
        if let iconColor {
            Image(icon)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(iconColor)
                .frame(width: headerIconWidth, alignment: .leading)
        } else {
            Image(icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: headerIconWidth, alignment: .leading)
        }
    }
    
    // MARK: - Child Components: Description View
    
    @ViewBuilder
    private var descriptionView: some View {
        if let description {
            Text(description)
                .styleText(
                    weight: .regular,
                    color: Color.T_1
                )
                .truncateText(lineLimit: 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    // MARK: - Child Components: Footer View
    
    private var footerView: some View {
        HStack(alignment: .center, spacing: 0) {
            if let footerButton {
                TextButton(
                    text: footerButton.text,
                    colorConfig: .init(
                        background: Color.T_9,
                        hoverBackground: Color.T_8
                    ),
                    sizeConfig: .init(
                        horizontalPadding: 6,
                        height: footerHeight
                    )
                ) {
                    footerButton.action()
                }
            }
            
            Spacer()
            
            Image(systemName: "arrow.right")
                .styleText(
                    color: Color.T_3
                )
                .offset(x: isHovered ? 4 : 0)
                .addAnimation(dependency: isHovered)
        }
        .frame(height: footerHeight, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}
