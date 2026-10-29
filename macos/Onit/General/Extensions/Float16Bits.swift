// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  Float16Bits.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-08-14.
//

import Foundation

/// Half-precision helpers that never name Swift's `Float16`.
///
/// `Float16` is unavailable on x86_64 macOS, so any engine that reads a
/// CoreML `.float16` `MLMultiArray` through a typed pointer stops the whole
/// app from building universal. Treating the storage as raw `UInt16` keeps
/// every stride/`memcpy`/vImage path byte-identical on both architectures -
/// only the scalar reads need this decode.
enum Float16Bits {

    /// Decode an IEEE-754 half-precision bit pattern to `Float`.
    @inline(__always)
    static func toFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h & 0x8000) << 16
        let exp = UInt32(h & 0x7C00) >> 10
        let mant = UInt32(h & 0x03FF)
        if exp == 0 {
            if mant == 0 { return Float(bitPattern: sign) }
            var e: UInt32 = 127 - 15 + 1
            var m = mant
            while (m & 0x0400) == 0 { m <<= 1; e -= 1 }
            m &= 0x03FF
            return Float(bitPattern: sign | (e << 23) | (m << 13))
        }
        if exp == 0x1F { return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13)) }
        // Rebias 15 -> 127 in ONE addition. Writing it as `exp - 15 + 127`
        // evaluates `exp - 15` first and traps on UInt32 underflow for every
        // half whose magnitude is below 1.0 (exponent field < 15) - i.e. for
        // most real logits and audio samples.
        let e = exp + 112
        return Float(bitPattern: sign | (e << 23) | (mant << 13))
    }

    /// Byte width of one half-precision element. Stands in for
    /// `MemoryLayout<Float16>.size` in stride / `rowBytes` arithmetic.
    static let stride = MemoryLayout<UInt16>.size
}
