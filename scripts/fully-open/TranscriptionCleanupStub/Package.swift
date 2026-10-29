// swift-tools-version: 6.0
//
//  Package.swift
//  TranscriptionCleanup (stub for the fully open build)
//
// `scripts/build-fully-open.sh` copies this over libs/transcription-cleanup-swift/Package.swift
// and deletes the closed TranscriptionCleanup.xcframework.
//
// The Xcode project links a product named `TranscriptionCleanup` from that local package, so
// the stub keeps the product name. Its one target is empty and has a different module name,
// so the app still links but `canImport(TranscriptionCleanup)` is false and every Smart
// Cleanup code path compiles out.

import PackageDescription

let package = Package(
    name: "TranscriptionCleanup",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(
            name: "TranscriptionCleanup",
            targets: ["TranscriptionCleanupUnavailable"]
        ),
    ],
    targets: [
        .target(name: "TranscriptionCleanupUnavailable"),
    ]
)
