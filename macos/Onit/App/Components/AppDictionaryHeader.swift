// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AppDictionaryHeader.swift
//  Onit
//
//  Created by Loyd Kim on 5/14/26.
//

import SwiftUI

struct AppDictionaryHeader: View {
    // MARK: - Properties
    
    @Binding var searchQuery: String
    @Binding var showAddSheet: Bool
    
    // MARK: - Observations
    
    @ObservedObject private var service = CustomDictionaryService.shared
    
    // MARK: - Private Variables
    
    private var searchPlaceholder: String {
        String.localized(
            "Search %lld Terms",
            table: "App",
            service.terms.count
        )
    }
    
    // MARK: - Body
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                AppTitleViews.PageTitleView(
                    text: String.localized("Dictionary", table: "App")
                )
            }

            Spacer()
            
            HStack(alignment: .center, spacing: 12) {
                ExpandingSearchBar(
                    searchQuery: $searchQuery,
                    placeholder: searchPlaceholder,
                    tooltip: String.localized("Search Dictionary", table: "App")
                )
                
                AppDictionary.AddNewButton(
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
