// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HuggingFaceRepoPathTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-10-27.
//
//  A custom MLX repo is user supplied and the Hugging Face API controls every file
//  `path`; these cases lock the validation that keeps a download inside its folder.
//

import Foundation
import Testing
@testable import Onit

@Suite
struct HuggingFaceRepoPathTests {

    private static let root = URL(fileURLWithPath: "/tmp/onit-models/repo", isDirectory: true)

    @Test("Ordinary nested and dotted names are accepted", arguments: [
        "config.json", "model.safetensors", "onnx/model_q4.onnx", "a/b/c.bin", "..hidden", "file..name", ".gitattributes",
    ])
    func accepts(path: String) {
        #expect(HuggingFaceModelDownloader.isSafeRepoPath(path))
        #expect(HuggingFaceModelDownloader.isSafeRepoPath(path, within: Self.root))
    }

    @Test("Traversal, absolute, backslash, NUL and empty paths are rejected", arguments: [
        "", "..", "../x", "a/../../x", "a/..", "/etc/passwd", "a\\b", "..\\x", "a\0b", "a//../../x",
    ])
    func rejects(path: String) {
        #expect(!HuggingFaceModelDownloader.isSafeRepoPath(path))
        #expect(!HuggingFaceModelDownloader.isSafeRepoPath(path, within: Self.root))
    }

    @Test("A path that resolves outside the destination is rejected")
    func resolvedEscape() {
        #expect(!HuggingFaceModelDownloader.isSafeRepoPath("a/./../../b", within: Self.root))
        #expect(HuggingFaceModelDownloader.isSafeRepoPath("a/./b", within: Self.root))
    }
}
