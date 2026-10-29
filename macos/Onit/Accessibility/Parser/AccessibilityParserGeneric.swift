// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AccessibilityParserGeneric.swift
//  Onit
//
//  Created by Kévin Naudin on 20/01/2025.
//

import ApplicationServices.HIServices.AXUIElement
import Foundation

/// Generic  implementation of the ``AccessibilityParserLogic``
class AccessibilityParserGeneric: AccessibilityParserBase {

    // MARK: - AccessibilityParserLogic

    /** See ``AccessibilityParserLogic`` parse function */
    override func parse(element: AXUIElement, includeBoundingBoxes: Bool) async -> ([String: String], [TextBoundingBox]?) {
        var result: [String: String] = [:]
        var screen: String = ""
        // Tracked alongside `screen` - String.count is O(n) grapheme counting,
        // too expensive to evaluate once per visited element on the main actor.
        var screenLength = 0
        var highlightedTextFound = false
        var boundingBoxes: [TextBoundingBox] = []
        
        _ = await AccessibilityParserUtility.recursivelyParse(
            element: element,
            maxDepth: AccessibilityParserConfig.recursiveDepthMax
        ) { element, depth in
            
            if !highlightedTextFound {
                let (parentResult, parentBoundingBoxes) = await super.parse(element: element, includeBoundingBoxes: includeBoundingBoxes)

                
                if !parentResult.isEmpty {
                    highlightedTextFound = true
                    result.merge(parentResult) { _, new in new }
                    
                    if includeBoundingBoxes, let boxes = parentBoundingBoxes {
                        boundingBoxes.append(contentsOf: boxes)
                    }
                }
            }

            if screenLength < AccessibilityParserConfig.maxCapturedTextLength,
               let value = element.value(), !value.isEmpty {
                let truncated = AccessibilityParserConfig.truncatedValue(value)
                screen += "\(truncated) "
                screenLength += truncated.count + 1

                if includeBoundingBoxes, let frame = element.getFrame() {
                    let textBoundingBox = TextBoundingBox(
                        text: value,
                        boundingBox: frame,
                        elementRole: element.role(),
                        elementDescription: element.description()
                    )
                    boundingBoxes.append(textBoundingBox)
                }
            }
            
            return .continueRecursing(nil)
        }

        result[AccessibilityParsedElements.screen] = screen

        return (result, includeBoundingBoxes ? boundingBoxes : nil)
    }
}
