// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppSnippetsHeader.swift
//  Onit
//
//  Created by Kévin Naudin on 17/06/2026.
//

import SwiftUI

struct AppSnippetsHeader: View {
    // MARK: - Properties

    @Binding var searchQuery: String
    @Binding var showAddSheet: Bool

    // MARK: - Observations

    @ObservedObject private var service = SnippetsService.shared

    // MARK: - Private Variables

    private var searchPlaceholder: String {
        String.localized(
            "Search %lld Snippets",
            table: "App",
            service.snippets.count
        )
    }

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            AppTitleViews.PageTitleView(
                text: String.localized("Snippets", table: "App")
            )

            Spacer()

            HStack(alignment: .center, spacing: 12) {
                ExpandingSearchBar(
                    searchQuery: $searchQuery,
                    placeholder: searchPlaceholder,
                    tooltip: String.localized("Search Snippets", table: "App")
                )

                AppSnippets.AddNewButton(
                    showAddSheet: $showAddSheet,
                    type: .primary
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 32)
        .padding(.bottom, 16)
    }
}
