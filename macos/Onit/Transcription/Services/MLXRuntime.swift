// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  MLXRuntime.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-08-14.
//

import Foundation
import MLX

/// Whether MLX can be touched at all on this machine, and the single funnel for
/// the MLX calls that are made outside an engine.
///
/// **MLX is fatal on Intel Macs.** Its first Metal call initialises
/// `mlx::core::metal::device_info()`, which does:
///
/// ```cpp
/// auto arch = std::string(raw_device->architecture()->name()->utf8String());
/// ```
///
/// `MTLDevice.architecture` returns `nil` on the Intel Metal drivers, MLX
/// dereferences it unchecked, and `std::string(nullptr)` calls `strlen(NULL)` →
/// `EXC_BAD_ACCESS`. Observed on a MacBookAir8,1 / Intel UHD 617 / macOS 14.8.9,
/// crashing in `_platform_strlen` with `-[MTLIGAccelDevice architecture]` as the
/// caller. It is a null dereference in a `static` initialiser, so it is
/// unconditional: not a memory ceiling, not a slow path, no way to recover.
///
/// The guard is therefore compile-time, not a runtime probe - there is no safe
/// way to ask MLX anything first.
enum MLXRuntime {

    /// `false` on x86_64. Every MLX entry point must check this first.
    static let isSupported: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()

    /// Release MLX's Metal buffer pool, or do nothing where MLX cannot run.
    ///
    /// Wrapped because the unload / idle-tick paths call it without any model
    /// being loaded - `CleanupModelLifecycleService`'s periodic tick alone would
    /// otherwise crash an Intel Mac that never selected an MLX model.
    static func clearCache() {
        guard isSupported else { return }
        MLX.Memory.clearCache()
    }

    /// Thrown by the MLX-backed engines when something reaches them anyway.
    struct UnsupportedError: LocalizedError {
        var errorDescription: String? {
            "MLX models require an Apple Silicon Mac."
        }
    }
}
