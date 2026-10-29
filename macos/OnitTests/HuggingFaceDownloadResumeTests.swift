// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  HuggingFaceDownloadResumeTests.swift
//  OnitTests
//
//  Regression coverage for the HTTP Range resume added to `HuggingFaceModelDownloader`.
//  Large HF models are served via the Xet CDN behind a 302 redirect; on a flaky link a
//  transfer can stall (30s no-data timeout) repeatedly. Before resume, each retry restarted
//  from byte 0 and could loop forever ("the model never downloads"). These tests lock the two
//  pure decisions that make resume correct: which offset to resume from, and whether a
//  finished transfer is actually complete enough to commit.
//

import Foundation
import Testing
@testable import Onit

@Suite
struct HuggingFaceDownloadResumeTests {

    // MARK: - resumePlan: where a retry picks up

    @Test("No partial on disk → fresh download from byte 0")
    func noPartialIsFresh() {
        #expect(HuggingFaceModelDownloader.resumePlan(partialSize: 0, expectedSize: 1000) == .fresh)
    }

    @Test("A half-written partial RESUMES from its byte offset (does not restart)")
    func halfPartialResumesFromOffset() {
        #expect(HuggingFaceModelDownloader.resumePlan(partialSize: 40, expectedSize: 1000) == .resume(offset: 40))
    }

    @Test("A partial at/over the expected size is stale → fresh restart, not a bogus resume")
    func stalePartialRestarts() {
        #expect(HuggingFaceModelDownloader.resumePlan(partialSize: 1000, expectedSize: 1000) == .fresh)
        #expect(HuggingFaceModelDownloader.resumePlan(partialSize: 1200, expectedSize: 1000) == .fresh)
    }

    @Test("Unknown expected size still resumes from a positive partial")
    func unknownExpectedResumes() {
        #expect(HuggingFaceModelDownloader.resumePlan(partialSize: 40, expectedSize: 0) == .resume(offset: 40))
    }

    /// End-to-end of the disk read: plant a real `.partial`, then assert the plan resumes from
    /// its actual on-disk length - the exact "interrupted, then resume" scenario, not a restart.
    @Test("A planted .partial is resumed from its on-disk length")
    func plantedPartialResumesFromDiskLength() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resume-test-\(UUID().uuidString).partial")
        try Data(repeating: 0xAB, count: 40).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let size = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int64) ?? -1
        #expect(size == 40)
        #expect(HuggingFaceModelDownloader.resumePlan(partialSize: size, expectedSize: 1000) == .resume(offset: 40))
    }

    // MARK: - commitDecision: only complete files land at the destination

    @Test("Exact size commits")
    func exactSizeCommits() {
        #expect(HuggingFaceModelDownloader.commitDecision(downloadedSize: 1000, expectedSize: 1000) == .commit)
    }

    @Test("A short body is kept for resume, never committed as complete (truncation guard)")
    func shortBodyKeptForResume() {
        #expect(HuggingFaceModelDownloader.commitDecision(downloadedSize: 900, expectedSize: 1000) == .keepAndFail)
    }

    @Test("An oversized body is discarded as corrupt")
    func oversizedBodyDiscarded() {
        #expect(HuggingFaceModelDownloader.commitDecision(downloadedSize: 1100, expectedSize: 1000) == .discardAndFail)
    }

    @Test("Unknown expected size commits (nothing to verify against)")
    func unknownExpectedCommits() {
        #expect(HuggingFaceModelDownloader.commitDecision(downloadedSize: 500, expectedSize: 0) == .commit)
    }

    // MARK: - contentRangeStart: a 206 must resume at the exact requested offset

    @Test("Parses the start byte from a well-formed Content-Range")
    func contentRangeStartParses() {
        #expect(HuggingFaceModelDownloader.contentRangeStart("bytes 311519284-2463307540/2463307541") == 311519284)
        #expect(HuggingFaceModelDownloader.contentRangeStart("bytes 0-99/100") == 0)
    }

    @Test("Returns nil for absent or unsatisfiable/garbage Content-Range")
    func contentRangeStartRejectsBadInput() {
        #expect(HuggingFaceModelDownloader.contentRangeStart(nil) == nil)
        #expect(HuggingFaceModelDownloader.contentRangeStart("bytes */2463307541") == nil)
        #expect(HuggingFaceModelDownloader.contentRangeStart("garbage") == nil)
    }
}
