// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  WhyItCostsMoneyPopover.swift
//  Onit
//

import SwiftUI

/// Shared "Why does this cost money" explanation, presented as a popover from the paywall
/// card and from Settings > Plan & Billing. Copy lives in `DictationPlanCopy`.
struct WhyItCostsMoneyPopover: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(title)
                    .styleText(size: 14, weight: .bold)
                Spacer(minLength: 12)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.T_3)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }

            ForEach(Array(DictationPlanCopy.whyLong.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .styleText(size: 12, weight: .regular, color: Color.T_1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(DictationPlanCopy.signatureName)
                    .styleText(size: 12, weight: .medium, color: Color.T_1)
                    .italic()
                Text(DictationPlanCopy.signatureRole)
                    .styleText(size: 11, weight: .regular, color: Color.T_2)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// The subtle "… →" link that opens the popover.
struct WhyItCostsMoneyLink: View {
    let title: String
    var fontSize: CGFloat = 11
    var onOpen: () -> Void = {}

    @State private var isPresented: Bool = false

    var body: some View {
        Button {
            onOpen()
            isPresented = true
        } label: {
            Text("\(title) →")
                .styleText(size: fontSize, weight: .regular, color: Color.T_3)
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            WhyItCostsMoneyPopover(title: title) { isPresented = false }
        }
    }
}
