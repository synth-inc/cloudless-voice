// swift-tools-version: 6.0
//
//  Package.swift
//  TranscriptionCleanup (vendored binary)
//
//  Created by Kévin Naudin on 2026-06-05.
//
// The app consumes TranscriptionCleanup as a precompiled binary XCFramework so the open-
// source app builds without the proprietary cleanup sources. The binary is rebuilt from those
// sources by the maintainers' `scripts/build_xcframework.sh` and redeployed here.

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
            targets: ["TranscriptionCleanup"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "TranscriptionCleanup",
            path: "XCFramework/TranscriptionCleanup.xcframework"
        ),
    ]
)
