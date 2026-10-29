// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  FlowLayout.swift
//  Onit
//
//  Created by Kévin Naudin on 12/02/2025.
//

import SwiftUI

struct FlowLayout: Layout {
    enum RowAlignment {
        case leading
        case center
    }

    var spacing: CGFloat
    /// How each wrapped row is aligned within the available width. Defaults to
    /// `.leading` so existing call sites keep their behavior.
    var rowAlignment: RowAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        
        var width: CGFloat = 0
        var height: CGFloat = 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var maxHeight: CGFloat = 0
        
        for size in sizes {
            if x + size.width > (proposal.width ?? .infinity) {
                x = 0
                y += maxHeight + spacing
                maxHeight = 0
            }
            
            maxHeight = max(maxHeight, size.height)
            width = max(width, x + size.width)
            height = max(height, y + size.height)
            
            x += size.width + spacing
        }
        
        return CGSize(width: width, height: height)
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        // Group subview indices into rows using the same wrapping rule as before.
        var rows: [[Int]] = []
        var current: [Int] = []
        var x = bounds.minX
        for (index, size) in sizes.enumerated() {
            if !current.isEmpty, x + size.width > bounds.maxX {
                rows.append(current)
                current = []
                x = bounds.minX
            }
            current.append(index)
            x += size.width + spacing
        }
        if !current.isEmpty { rows.append(current) }

        // Place each row, offsetting its start when centered.
        var y = bounds.minY
        for row in rows {
            let rowWidth = row.reduce(0) { $0 + sizes[$1].width }
                + spacing * CGFloat(max(0, row.count - 1))
            var rowX = bounds.minX
            if rowAlignment == .center {
                rowX += max(0, (bounds.width - rowWidth) / 2)
            }

            var maxHeight: CGFloat = 0
            for index in row {
                subviews[index].place(at: CGPoint(x: rowX, y: y), proposal: .unspecified)
                rowX += sizes[index].width + spacing
                maxHeight = max(maxHeight, sizes[index].height)
            }
            y += maxHeight + spacing
        }
    }
}
