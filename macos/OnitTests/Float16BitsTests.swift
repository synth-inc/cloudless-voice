// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Float16BitsTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-08-14.
//

// The whole point of `Float16Bits` is that `Float16` does not exist on
// x86_64 - so the comparison against it can only be compiled on arm64.
#if arch(arm64)

import XCTest

@testable import Onit

/// `Float16Bits` exists so the app can build for x86_64, where Swift's
/// `Float16` does not exist. These tests run on arm64 (where `Float16` does),
/// which is exactly what makes them useful: they pin the software decoder
/// against the hardware conversion it stands in for.
final class Float16BitsTests: XCTestCase {

    /// Every one of the 65 536 half bit patterns must decode to the same
    /// `Float` the hardware conversion produces.
    ///
    /// This caught a real trap: written as `exp - 15 + 127`, the rebias
    /// evaluates `exp - 15` first and overflows `UInt32` for every half below
    /// 1.0 - i.e. for most logits and audio samples.
    func testDecodeMatchesHardwareForEveryBitPattern() {
        var mismatches: [UInt16] = []
        for raw in 0...UInt16.max {
            let decoded = Float16Bits.toFloat(raw)
            let hardware = Float(Float16(bitPattern: raw))
            let equal = decoded.bitPattern == hardware.bitPattern
                || (decoded.isNaN && hardware.isNaN)
            if !equal, mismatches.count < 8 { mismatches.append(raw) }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "half decode diverges from hardware at: "
                + mismatches.map { String(format: "0x%04X", $0) }.joined(separator: ", ")
        )
    }

    /// The `UInt16` substitution is only safe because the two types share a
    /// memory layout - every `memcpy`, stride and vImage `rowBytes` in the
    /// engines depends on it.
    func testLayoutMatchesFloat16() {
        XCTAssertEqual(Float16Bits.stride, MemoryLayout<Float16>.size)
        XCTAssertEqual(MemoryLayout<UInt16>.stride, MemoryLayout<Float16>.stride)
        XCTAssertEqual(MemoryLayout<UInt16>.alignment, MemoryLayout<Float16>.alignment)
    }
}

#endif
