// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AccessibilityParserCalendar.swift
//  Onit
//
//  Created by Kévin Naudin on 28/04/2025.
//

import ApplicationServices.HIServices

/// Implementation of `AccessibilityParserLogic` for Calendar app
class AccessibilityParserCalendar: AccessibilityParserBase {

    // MARK: - AccessibilityParserLogic

    /** See ``AccessibilityParserLogic`` parse function */
    override func parse(element: AXUIElement, includeBoundingBoxes: Bool ) async -> ([String: String], [TextBoundingBox]?) {

        var result: [String: String] = [:]
        var screen: String = ""
        // Tracked alongside `screen` - String.count is O(n) grapheme counting,
        // too expensive to evaluate once per visited element on the main actor.
        var screenLength = 0
        var highlightedTextFound = false
        var boundingBoxes : [TextBoundingBox] = []

        _ = await AccessibilityParserUtility.recursivelyParse(
            element: element,
            maxDepth: AccessibilityParserConfig.recursiveDepthMax
        ) { element, depth in
            
            if !highlightedTextFound {
                let (parentResult, parentBoundingBoxes) = await super.parse(element: element)
                
                if !parentResult.isEmpty {
                    highlightedTextFound = true
                    result.merge(parentResult) { _, new in new }
                }
            }
            
            guard screenLength < AccessibilityParserConfig.maxCapturedTextLength,
                  let role = element.role(), role == kAXStaticTextRole,
                  let description = element.description(),
                  !description.isEmpty,
                  !screen.contains(description) else {
                return .continueRecursing(nil)
            }
            
            if includeBoundingBoxes, let frame = element.getFrame() {
                let textBoundingBox = TextBoundingBox(text: description, boundingBox: frame, elementRole: role, elementDescription: description)
                boundingBoxes.append(textBoundingBox)
            }
            let truncated = AccessibilityParserConfig.truncatedValue(description)
            screen += "\(truncated)\n"
            screenLength += truncated.count + 1

            return .continueRecursing(nil)
        }
        
        result[AccessibilityParsedElements.screen] = screen
        
        return (result, includeBoundingBoxes ? boundingBoxes : nil)
    }
}
