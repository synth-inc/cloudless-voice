// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppWindowSidebar.swift
//  Onit
//
//  Created by Loyd Kim on 4/28/26.
//

import SwiftUI

struct AppWindowSidebar: View {
    // MARK: - Environments

    @Environment(\.appState) private var appState

    // MARK: - Observables

    @ObservedObject private var appWindowManager = AppWindowManager.shared
    @ObservedObject private var lifetimeActivationManager = LifetimeActivationManager.shared
    @ObservedObject private var authManager = AuthManager.shared
    /// Observed so the Dictionary row's wrong-model badge tracks the selected
    /// ASR model live (selectedASRModelId is @Published).
    @ObservedObject private var transcriptionConfig = TranscriptionConfig.shared

    // MARK: - States

    @State private var showGetSupportPopover: Bool = false

    // MARK: - Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logoHeaderView
            pageNavigationView
            ReferralCTAView()
            Spacer()
            footerView
        }
        .padding(.top, 40)
        .frame(width: 230, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.surface2.opacity(0.9))
        .background(Backgrounds.BrushedGlass())
        .addBorder(
            sides: .right,
            stroke: Color.T_4,
            dotted: true,
            dottedDash: [1, 2]
        )
        .onAppear {
            Task {
                await lifetimeActivationManager.fetchActivation()
            }
        }
        .onChange(of: authManager.userLoggedIn) { _, _ in
            Task {
                await lifetimeActivationManager.fetchActivation()
            }
        }
    }
    
    // MARK: - Child Components: Logo Header View
    
    private var logoHeaderView: some View {
        Image(.logoWord)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 26)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 40, alignment: .center)
    }
    
    // MARK: - Child Components: Page Navigation View

    private let appPages = AppPages.allCases.filter { $0 != .support }

    private var pageNavigationView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(appPages, id: \.sidebarName) { page in
                ZStack(alignment: .trailing) {
                    textButton(
                        iconSystemName: page.sidebarIcon,
                        text: page.sidebarName,
                        selected: page == appWindowManager.currentPage
                    ) {
                        appWindowManager.setPage(page: page)
                    }
                    // Wrong-model badge: the dictionary needs an MLX model
                    // (Qwen/Granite); flag the row when e.g. Parakeet is active.
                    // Mirrors the settings sidebar's red setup-incomplete badge.
                    if page == .dictionary,
                       transcriptionConfig.selectedASRModel.backend != .mlx {
                        Text("!")
                            .frame(width: 18, height: 18)
                            .background(Color.sky)
                            .cornerRadius(999)
                            .styleText(
                                size: 11,
                                weight: .regular,
                                color: Color.black
                            )
                            .padding(.trailing, 12)
                            .allowsHitTesting(false)
                            .help(String.localized("Dictionary requires a Qwen or Granite model", table: "App"))
                    }
                }
            }
        }
        .padding(8)
    }
    
    // MARK: - Child Components: Referral CTA View
    
    private struct ReferralCTAView: View {
        @State private var isHovered: Bool = false
        @State private var isPressed: Bool = false
        
        private let cornerRadius: CGFloat = 14
        
        var body: some View {
            HStack(alignment: .center, spacing: 8) {
                heartIconView
                VStack(alignment: .leading, spacing: 4) {
                    titleTextView
                    footerTextView
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .addBorder(
                cornerRadius: cornerRadius,
                stroke: isHovered ? Color.T_3 : Color.T_4,
                dotted: true
            )
            .addButtonEffects(
                background: Color.special1,
                hoverBackground: Color.special2,
                cornerRadius: cornerRadius,
                shouldFadeOnClick: false,
                isHovered: $isHovered,
                isPressed: $isPressed
            ) {
                AppWindowManager.shared.setPage(page: .support)
            }
            .padding(8)
        }
        
        private var heartIconView: some View {
            Image(systemName: "heart.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Color.sky)
        }
        
        private var titleTextView: some View {
            Text(String.localized("Keep dictation local!", table: "App"))
                .styleText(
                    fontFamily: .libreBaskerville,
                    weight: .regular
                )
        }
        
        private var footerTextView: some View {
            HStack(alignment: .center, spacing: 0) {
                Text(String.localized("Invite friends", table: "App"))
                    .styleText(
                        size: 12,
                        weight: .regular,
                        color: Color.T_2
                    )
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color.T_3)
                    .offset(x: isHovered ? 4 : 0)
                    .addAnimation(dependency: isHovered)
            }
            .padding(.trailing, 4)
        }
    }

    // MARK: - Child Components: Footer View

    private var footerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ReferralRankPill()
            settingsButton
            getSupportButton
        }
        .padding(8)
        .padding(.bottom, 16)
    }
    
    private var settingsButton: some View {
        ZStack(alignment: .trailing) {
            textButton(
                iconSystemName: "gear",
                text: String.localized("Settings", table: "App"),
                selected: appWindowManager.showSettingsSheet
            ) {
                appWindowManager.showSettingsSheet.toggle()
            }

            // Red dot when the Setup page has outstanding required permissions.
            if appState.setupBadgeCount != nil {
                Circle()
                    .fill(Color.red500)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 12)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $appWindowManager.showSettingsSheet) {
            HStack(alignment: .top, spacing: 0) {
                SettingsWindowSidebar()
                SettingsWindowPages()
            }
            .frame(width: 750, height: 700)
        }
    }

    private var getSupportButton: some View {
        textButton(
            iconSystemName: "questionmark.circle",
            text: String.localized("Get Support", table: "App"),
            selected: showGetSupportPopover
        ) {
            showGetSupportPopover.toggle()
        }
        .popover(isPresented: $showGetSupportPopover, arrowEdge: .top) {
            getSupportPopoverContent
        }
    }

    // MARK: - Child Components: Get Support Popover Content

    private var getSupportPopoverContent: some View {
        PopoverButtonsView(
            items: [
                .init(
                    text: String.localized("Discord Community", table: "App"),
                    iconConfig: .init(
                        leftIconImage: .logoDiscord
                    ),
                    sizeConfig: PopoverButtonsView.buttonSizeConfig(
                        leftIcon: 22
                    ),
                    action: {
                        MenuBarDiscord.openDiscord()
                        showGetSupportPopover = false
                    }
                ),
                .init(
                    text: String.localized("Contact Us", table: "App"),
                    iconConfig: .init(
                        leftIconName: "envelope"
                    ),
                    action: {
                        if let url = URL(string: "mailto:contact@cloudless.so") {
                            NSWorkspace.shared.open(url)
                        }
                        showGetSupportPopover = false
                    }
                )
            ]
        )
    }

    // MARK: - Child Components: Text Button
    
    private func textButton(
        iconSystemName: String? = nil,
        iconImage: ImageResource? = nil,
        iconSize: CGFloat = 16,
        text: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        TextButton(
            type: .clear,
            text: text,
            iconConfig: .init(
                leftIconName: iconSystemName,
                leftIconImage: iconImage
            ),
            sizeConfig: .init(
                textWeight: .regular,
                leftIcon: iconSize,
                horizontalPadding: 8,
                height: 36
            ),
            alignmentConfig: .init(
                horizontalAlignment: .leading,
                gap: 8
            ),
            statusConfig: .init(
                selected: selected,
                fillContainer: true
            )
        ) {
            action()
        }
    }
    
    // MARK: - Child Components: Referral Rank Pill

    private struct ReferralRankPill: View {
        @ObservedObject private var lifetimeActivationManager = LifetimeActivationManager.shared

        @State private var isHovered: Bool = false
        @State private var cursorLocation: CGPoint? = nil

        private static let rankFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter
        }()

        private let glowDiameter: CGFloat = 160

        var body: some View {
            if let seatNumber = lifetimeActivationManager.activation?.seatNumber {
                HStack(alignment: .center, spacing: 8) {
                    cloudIconView
                    dictationSeatNumberView(seatNumber)
                }
                .padding(.leading, 10)
                .padding(.trailing, 16)
                .frame(height: 42, alignment: .center)
                .background(backgroundView)
                .addBorder(
                    cornerRadius: 11,
                    stroke: isHovered ? Color.clear : Color.T_8
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        isHovered = true
                        cursorLocation = location
                    case .ended:
                        isHovered = false
                        cursorLocation = nil
                    }
                }
                .addAnimation(dependency: isHovered)
                .animation(.easeOut(duration: 0.08), value: cursorLocation)
            }
        }

        private var cloudIconView: some View {
            Text("☁️")
                .styleText(
                    size: 22
                )
        }

        private func dictationSeatNumberView(_ seatNumber: Int) -> some View {
            let formatted = Self.rankFormatter.string(
                from: NSNumber(value: seatNumber)
            ) ?? "\(seatNumber)"

            return Text(String.localized("You are #%@", table: "App", formatted))
                .styleText(
                    fontFamily: .libreBaskerville,
                    weight: .regular,
                    color: isHovered ? Color.black : Color.S_0
                )
        }

        private var backgroundView: some View {
            GeometryReader { geometry in
                ZStack {
                    Color.special1

                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 159 / 255, green: 212 / 255, blue: 255 / 255),
                            Color(red: 211 / 255, green: 236 / 255, blue: 255 / 255)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .opacity(isHovered ? 1 : 0)

                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    Color.skyDark.opacity(0.6),
                                    Color.skyDark.opacity(0)
                                ]),
                                center: .center,
                                startRadius: 0,
                                endRadius: glowDiameter / 2
                            )
                        )
                        .frame(width: glowDiameter, height: glowDiameter)
                        .position(
                            x: cursorLocation?.x ?? geometry.size.width / 2,
                            y: cursorLocation?.y ?? geometry.size.height / 2
                        )
                        .opacity(cursorLocation != nil ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
