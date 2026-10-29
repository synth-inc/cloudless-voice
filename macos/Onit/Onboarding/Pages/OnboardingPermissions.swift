// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  OnboardingPermissions.swift
//  Onit
//
//  Created by Kévin Naudin on 28/11/2025.
//

import Defaults
import SwiftUI

struct OnboardingPermissions: View {
    // MARK: - Defaults

    @Default(.currentOnboardingStep) var currentStep

    // MARK: - States

    @ObservedObject private var accessibilityPermissionManager = AccessibilityPermissionManager.shared

    // MARK: - Private Variables: Constants

    private var requiredCaptionText: String { String.localized("Required", table: "Onboarding") }

    // MARK: - Private Variables: Permissions

    private var grantedAccessibility: Bool {
        return accessibilityPermissionManager.accessibilityPermissionStatus == .granted
    }

    private var allAccessGranted: Bool {
        return grantedAccessibility
    }

    // MARK: - Body

    var body: some View {
        OnboardingPage(
            footerConfig: .init(
                nextButtonDisabled: Binding(
                    get: { !allAccessGranted },
                    set: { _ in }
                )
            ),
            bodyContent: {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        accessibilityPermissionRow
                    }
                    .padding(.top, 47)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 26)
                    .frame(width: 629)
                }
            },
            footerContent: {
                Spacer()
            }
        )
    }

    // MARK: - Child Components: Sections

    private var accessibilityPermissionRow: some View {
        PermissionRow(
            icon: .settingsAccessibility,
            title: String.localized("Accessibility", table: "Onboarding"),
            caption: requiredCaptionText,
            isGranted: grantedAccessibility,
            buttonText: grantedAccessibility ? String.localized("Granted", table: "Onboarding") : String.localized("Grant access", table: "Onboarding"),
        ) {
            bulletPointTextView(String.localized("This allows Cloudless to paste your dictations into any text field.", table: "Onboarding"))
        } buttonAction: {
            if !grantedAccessibility {
                accessibilityPermissionManager.requestPermission()
            }
        }
    }

    // MARK: - Child Components: Bullet Point Text View

    private func bulletPointTextView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "circle.fill")
                .padding(.top, 7)
                .styleText(
                    size: 3,
                    weight: .regular,
                    color: Color.T_1
                )

            Text(text)
                .styleText(
                    weight: .regular,
                    color: Color.T_1
                )
        }
    }

    // MARK: - Child Components: Permission Row

    private struct PermissionRow<BulletPoints: View>: View {
        let icon: ImageResource
        let title: String
        var caption: String? = nil
        let isGranted: Bool
        let buttonText: String
        @ViewBuilder let bulletPoints: BulletPoints
        let buttonAction: () -> Void

        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Image(icon)
                            .resizable()
                            .frame(width: 20)
                            .frame(height: 20)

                        Text(title)
                            .styleText(
                                size: 15,
                                weight: .regular
                            )
                            .fixedSize(horizontal: false, vertical: true)

                        if let caption = caption {
                            Text(caption)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 5)
                                .styleText(
                                    size: 13,
                                    weight: .regular,
                                    color: Color.T_1
                                )
                                .background(Color.T_8)
                                .cornerRadius(6)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        bulletPoints
                    }
                    .styleText(
                        size: 14,
                        weight: .regular,
                        color: Color.T_1
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                PulsingPermissionButton(
                    text: buttonText,
                    isGranted: isGranted,
                    action: buttonAction
                )
            }
        }
    }

    // MARK: - Child Components: Pulsing Permission Button

    private struct PulsingPermissionButton: View {
        let text: String
        let isGranted: Bool
        let action: () -> Void

        var body: some View {
            TextButton(
                text: text,
                iconConfig: .init(
                    rightIconName: isGranted ? "checkmark" : nil
                ),
                colorConfig: .init(
                    text: Color.S_0,
                    background: isGranted ? Color.clear : Color.T_9,
                    border: isGranted ? Color.T_4 : Color.clear
                ),
                sizeConfig: .init(
                    horizontalPadding: 12,
                    height: 37,
                    cornerRadius: 8
                ),
                statusConfig: .init(
                    disabled: isGranted,
                    shouldFadeOnDisabled: false,
                    borderDotted: isGranted
                )
            ) {
                action()
            }
        }
    }
}
