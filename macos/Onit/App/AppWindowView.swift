// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppWindowView.swift
//  Onit
//
//  Created by Loyd Kim on 4/28/26.
//

import SwiftUI

struct AppWindowView: View {
    // MARK: - Observations

    @ObservedObject private var localization = LocalizationManager.shared
    
    // MARK: - Body
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            AppWindowSidebar()
            AppWindowPages()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cornerRadius(22)
        .ignoresSafeArea(.container, edges: .top)
        .id(localization.currentLanguage)
    }
}
