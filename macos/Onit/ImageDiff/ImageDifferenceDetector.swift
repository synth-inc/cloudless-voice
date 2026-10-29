// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  ImageDifferenceDetector.swift
//  Onit
//
//  Created by Timothy Lenardo on 9/10/25.
//

import CoreGraphics
import Foundation

/// Describes a changed region in pixel space with origin at the top-left of the image.
public struct ImageDifferenceRegion: Sendable, Hashable {
    public let rect: CGRect
    public let changedRatio: Double
}


public final class ImageDifferenceDetector {
    
    public static func computeChangedRegions(
        before: CGImage,
        after: CGImage,
        tileSize: Int = 96,
        tileOverlapX: Int = 6,
        tileOverlapY: Int = 32, // This ensures that any cursor less than 32 pixels tall will be fully contained in a single tile
        sampleStride: Int = 2,
        pixelDiffThreshold: UInt8 = 24,
        tileChangeRatioThreshold: Double = 0.00
    ) throws -> ([ImageDifferenceRegion], [Int: Double], Double) {
        let startTime = CFAbsoluteTimeGetCurrent()
        precondition(tileSize > 0, "tileSize must be > 0")
        precondition(tileOverlapX >= 0 && tileOverlapX < tileSize, "tileOverlapX must be >= 0 and < tileSize")
        precondition(tileOverlapY >= 0 && tileOverlapY < tileSize, "tileOverlapY must be >= 0 and < tileSize")
        precondition(sampleStride > 0, "sampleStride must be > 0")
        precondition(tileChangeRatioThreshold >= 0 && tileChangeRatioThreshold <= 1, "tileChangeRatioThreshold must be in [0,1]")
        let width = before.width
        let height = before.height

        let beforePixelBuffer = PixelBufferRenderer.createPixelBuffer(from: before, width: width, height: height)
        let afterPixelBuffer = PixelBufferRenderer.createPixelBuffer(from: after, width: after.width, height: after.height)
        guard let beforePixelBuffer = beforePixelBuffer, let afterPixelBuffer = afterPixelBuffer else {
            throw NSError(domain: "ImageDifferenceDetector", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create pixel buffer"])
        }

        // Calculate stride from overlap: stride = tileSize - overlap
       // For example: tileSize=64, overlap=20 -> stride=44
       // Tiles: [0,64), [44,108), [88,152), ...
       let tileStrideX = tileSize - tileOverlapX
       let tileStrideY = tileSize - tileOverlapY
       
       let tilesX = max(1, (width - tileSize + tileStrideX - 1) / tileStrideX + 1)
       let tilesY = max(1, (height - tileSize + tileStrideY - 1) / tileStrideY + 1)
        var changedTile = Array(repeating: Array(repeating: false, count: tilesX), count: tilesY)
        var tileChangeRatios: [Int: Double] = [:]

        let gpu = ImageDiffGPU.shared
        let gpuShift = try gpu.findBestShift(before: beforePixelBuffer, after: afterPixelBuffer, beforeWidth: width, beforeHeight: height, maxShift: 1)
        let finalShiftDX = gpuShift.0
        let finalShiftDY = gpuShift.1
        let finalScore = gpuShift.2

        let res = try gpu.computeTileChangeMask(
            before: beforePixelBuffer,
            after: afterPixelBuffer,
            width: width,
            height: height,
            tileSize: tileSize,
            tileStrideX: tileStrideX,
            tileStrideY: tileStrideY,
            sampleStride: sampleStride,
            threshold: pixelDiffThreshold,
            shiftDX: finalShiftDX,
            shiftDY: finalShiftDY
        )
        for ty in 0..<res.tilesY {
            for tx in 0..<res.tilesX {
                let i = ty * res.tilesX + tx
                let sampled = max(1, Int(res.sampledCounts[i]))
                let ratio = Double(res.changedCounts[i]) / Double(sampled)
                tileChangeRatios[i] = ratio
                if ratio >= tileChangeRatioThreshold {
                    changedTile[ty][tx] = true
                }
            }
        }

        var regions: [ImageDifferenceRegion] = []
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                if !changedTile[ty][tx] { continue }

                // Convert tile bounds to pixel rect (top-left origin).
                // Tiles start at (tx * strideX, ty * strideY) and have size tileSize
                // Example: tileSize=64, strideX=59 (overlap=5)
                // tx=0: x=[0, 64), tx=1: x=[59, 123), tx=2: x=[118, 182)
                let x0 = tx * tileStrideX
                let y0 = ty * tileStrideY
                let x1 = min(x0 + tileSize, width)
                let y1 = min(y0 + tileSize, height)
                let tileHeight = y1 - y0

                // Flip the y-coordinates because it seems to be needed.
                let rect = CGRect(x: x0, y: height - y0 - tileHeight, width: x1 - x0, height: tileHeight)

                // Use the actual tile change ratio for this tile.
                let i = ty * tilesX + tx
                let ratio = tileChangeRatios[i] ?? 0.0
                regions.append(ImageDifferenceRegion(rect: rect, changedRatio: ratio))
            }
        }

        let timeTaken = CFAbsoluteTimeGetCurrent() - startTime
        return (regions, tileChangeRatios, timeTaken)
    }
}
