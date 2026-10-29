// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AmbientCaptureDedupeTests.swift
//  OnitTests
//
//  The ambient capture's cost gate is change detection, not time throttling:
//  OCR runs only when the tile diff says the screen actually changed. These
//  cover the pure decision layer + the downscale the diff runs on.
//

import CoreGraphics
import XCTest
@testable import Onit

final class AmbientCaptureDedupeTests: XCTestCase {

    private func region(_ ratio: Double, x: CGFloat = 0) -> ImageDifferenceRegion {
        ImageDifferenceRegion(rect: CGRect(x: x, y: 0, width: 64, height: 64),
                              changedRatio: ratio)
    }

    func testStaticScreenIsNotAChange() {
        XCTAssertFalse(AmbientCaptureDedupe.isMeaningfulChange([]))
    }

    func testSingleRepainterToleranceHolds() {
        // A lone changed tile (menu-bar clock, blinking caret, spinner) must
        // not trigger OCR.
        XCTAssertFalse(AmbientCaptureDedupe.isMeaningfulChange([region(0.5)]))
    }

    func testLowRatioShimmerIgnored() {
        // Many tiles barely above zero (anti-aliasing, video noise at the
        // sampled stride) stay below the per-tile floor.
        let shimmer = (0..<10).map { region(0.01, x: CGFloat($0) * 64) }
        XCTAssertFalse(AmbientCaptureDedupe.isMeaningfulChange(shimmer))
    }

    func testRealContentChangeTriggers() {
        let scrolled = [region(0.4), region(0.6, x: 64), region(0.3, x: 128)]
        XCTAssertTrue(AmbientCaptureDedupe.isMeaningfulChange(scrolled))
    }

    func testMixedNoiseAndContent() {
        // One real tile + shimmer everywhere else: still below the 2-tile bar.
        let mixed = [region(0.5)] + (0..<5).map { region(0.01, x: CGFloat($0 + 1) * 64) }
        XCTAssertFalse(AmbientCaptureDedupe.isMeaningfulChange(mixed))
        // Two real tiles: fires.
        XCTAssertTrue(AmbientCaptureDedupe.isMeaningfulChange(
            [region(0.5), region(0.04, x: 64)]))
    }

    func testTextFingerprintStableAndDiscriminating() {
        let a = AmbientCaptureDedupe.textFingerprint("Kalender quarterly sync\nAbbie")
        XCTAssertEqual(a, AmbientCaptureDedupe.textFingerprint("Kalender quarterly sync\nAbbie"))
        XCTAssertNotEqual(a, AmbientCaptureDedupe.textFingerprint("Kalender quarterly sync\nAbbey"))
        XCTAssertNotEqual(AmbientCaptureDedupe.textFingerprint(""), 0)
    }

    func testDownscaleBoundsWidthAndKeepsAspect() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2048, height: 1280, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let big = try XCTUnwrap(context.makeImage())
        let small = try XCTUnwrap(AmbientTermCaptureService.downscaled(big))
        XCTAssertEqual(small.width, 512)
        XCTAssertEqual(small.height, 320)
        // Already-small images pass through untouched.
        let same = try XCTUnwrap(AmbientTermCaptureService.downscaled(small))
        XCTAssertEqual(same.width, 512)
    }
}
