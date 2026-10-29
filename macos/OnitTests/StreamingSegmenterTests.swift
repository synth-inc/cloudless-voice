// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  StreamingSegmenterTests.swift
//  OnitTests
//
//  Created by Kévin Naudin on 2026-07-20.
//

import Foundation
import Testing
@testable import Onit

/// Pure-logic tests for `StreamingSegmenter`: silence-boundary cuts,
/// max-length fallback, lead-in math, tail behaviour, and segmentation
/// determinism. Uses a deterministic amplitude-based classifier (speech = 0.5,
/// silence = 0.0) so no real VAD/energy heuristics are in play.
///
/// Defaults under test: minSegment 4.0 s, maxSegment 12 s, minSilence 0.6 s
/// (cut fires when a silence run crosses 0.6 s, landing 0.3 s into the pause),
/// overlap cap 0.5 s, frame 0.1 s.
struct StreamingSegmenterTests {

    private static let rate = 16_000

    private static func newSegmenter(options: StreamingSegmenterOptions? = nil) -> StreamingSegmenter {
        StreamingSegmenter(options: options ?? .default) { frame in
            for s in frame where abs(s) > 0.01 {
                return false
            }
            return true
        }
    }

    private static func speech(_ seconds: Double) -> [Float] {
        Array(repeating: 0.5, count: Int(seconds * Double(rate)))
    }

    private static func silence(_ seconds: Double) -> [Float] {
        Array(repeating: 0.0, count: Int(seconds * Double(rate)))
    }

    // MARK: - Silence-boundary cuts

    @Test("Cut fires when a silence run crosses the threshold")
    func cutFiresWhenSilenceRunCrossesThreshold() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(4.0))
        seg.append(Self.silence(0.7)) // run crosses 0.6 s at t=4.6 → cut at 4.0+0.3
        seg.append(Self.speech(1.0))

        let s = seg.tryTakeSegment()
        #expect(s != nil)
        #expect(s?.endSample == Int(4.3 * Double(Self.rate)))
        #expect(s?.startSample == 0) // first segment: no lead-in below zero
        #expect(s?.samples.count == s?.endSample)
        #expect(s?.containsSpeech == true)
        #expect(s?.hasSpeechOverlap == false) // first segment re-sends no speech
        #expect(seg.tryTakeSegment() == nil) // one pause, one cut
    }

    @Test("No cut when the pause is too close to the previous cut")
    func noCutWhenPauseIsTooCloseToPreviousCut() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(2.0))
        seg.append(Self.silence(0.7)) // strong pause, but cut would land at 2.2 s < minSegment (4 s)
        seg.append(Self.speech(1.0))

        #expect(seg.tryTakeSegment() == nil)
    }

    @Test("A short gap does not fire a cut")
    func shortGapDoesNotFireACut() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(4.0))
        seg.append(Self.silence(0.3)) // hesitation dip < minSilence (0.6 s)
        seg.append(Self.speech(1.0))

        #expect(seg.tryTakeSegment() == nil)
    }

    @Test("A long silence run fires exactly one cut")
    func longSilenceRunFiresExactlyOneCut() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(4.0))
        seg.append(Self.silence(3.0)) // one long pause, not several

        let s = seg.tryTakeSegment()
        #expect(s != nil)
        #expect(s?.endSample == Int(4.3 * Double(Self.rate)))
        #expect(seg.tryTakeSegment() == nil)
    }

    // MARK: - Max-length fallback

    @Test("A fixed cut lands at max length when no pause appears")
    func fixedCutAtMaxLengthWhenNoPauseAppears() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(12.5)) // continuous - no pause for the whole cap

        let s = seg.tryTakeSegment()
        #expect(s != nil)
        #expect(s?.endSample == 12 * Self.rate) // fixed cut at exactly maxSegment
        #expect(seg.cursor == 12 * Self.rate)
        #expect(seg.tryTakeSegment() == nil)
    }

    // MARK: - Lead-in math

    @Test("After a pause cut the lead-in is silence only")
    func afterPauseCutLeadInIsSilenceOnly() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(4.0))
        seg.append(Self.silence(0.7)) // cut at 4.3 s; pause starts at 4.0 s
        seg.append(Self.speech(4.0))
        seg.append(Self.silence(0.7)) // second cut at 9.0 s

        let first = seg.tryTakeSegment()
        let second = seg.tryTakeSegment()
        #expect(first != nil)
        #expect(second != nil)

        #expect(first?.endSample == Int(4.3 * Double(Self.rate)))
        // The second segment's lead-in reaches back to the pause START (4.0 s)
        // - pure silence, never a clipped word onset - so it must not dedupe.
        #expect(second?.startSample == 4 * Self.rate)
        #expect(second?.hasSpeechOverlap == false)
        #expect(second?.endSample == Int(9.0 * Double(Self.rate)))
        #expect(second?.samples.count == (second.map { $0.endSample - $0.startSample }))
    }

    @Test("After a fixed cut the next segment carries full speech overlap")
    func afterFixedCutNextSegmentCarriesFullSpeechOverlap() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(12.5))
        let first = seg.tryTakeSegment()
        #expect(first != nil)
        #expect(first?.endSample == 12 * Self.rate) // fixed, mid-speech

        seg.append(Self.silence(0.7))
        let tail = seg.takeTail()
        #expect(tail != nil)

        // Safety net: 0.5 s of re-sent speech before the fixed cut - the stitcher
        // must dedupe here, so the segment is flagged.
        #expect(tail?.startSample == 12 * Self.rate - Self.rate / 2)
        #expect(tail?.hasSpeechOverlap == true)
        #expect(tail?.containsSpeech == true)
    }

    // MARK: - Tail

    @Test("takeTail returns the remainder with lead-in, then nothing")
    func takeTailReturnsRemainderWithLeadInThenNothing() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(4.0))
        seg.append(Self.silence(0.7)) // cut at 4.3 s, pause start 4.0 s
        #expect(seg.tryTakeSegment() != nil)

        seg.append(Self.speech(1.0))
        let tail = seg.takeTail()
        #expect(tail != nil)
        #expect(tail?.startSample == 4 * Self.rate) // silence-only lead-in
        #expect(tail?.endSample == seg.totalSamples)
        #expect(tail?.containsSpeech == true)

        #expect(seg.takeTail() == nil) // nothing left past the last cut
    }

    @Test("takeTail flags a silent tail")
    func takeTailFlagsSilentTail() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(4.0))
        seg.append(Self.silence(0.7))
        #expect(seg.tryTakeSegment() != nil)

        seg.append(Self.silence(1.0)) // user held the key without speaking again
        let tail = seg.takeTail()
        #expect(tail != nil)
        #expect(tail?.containsSpeech == false) // caller can skip the ASR call
    }

    @Test("takeTail counts partial-frame speech as speech")
    func takeTailPartialFrameSpeechCountsAsSpeech() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(4.0))
        seg.append(Self.silence(0.7))
        #expect(seg.tryTakeSegment() != nil)

        seg.append(Self.silence(0.7))
        seg.append(Self.speech(0.05)) // last word fragment, shorter than one frame
        let tail = seg.takeTail()
        #expect(tail != nil)
        #expect(tail?.containsSpeech == true)
    }

    @Test("takeTail with no cuts fired returns the whole recording")
    func takeTailWithNoCutsFiredReturnsWholeRecording() {
        let seg = Self.newSegmenter()
        seg.append(Self.speech(1.2))

        let tail = seg.takeTail()
        #expect(tail != nil)
        #expect(tail?.startSample == 0)
        #expect(tail?.endSample == Int(1.2 * Double(Self.rate)))
    }

    // MARK: - Determinism

    @Test("Segmentation is independent of append chunking")
    func segmentationIsIndependentOfAppendChunking() {
        // Cut points must be a pure function of the audio: feeding the same
        // stream in 100 ms chunks or in one big append yields identical
        // segments (this is what makes replay runs reproducible).
        var audio: [Float] = []
        audio.append(contentsOf: Self.speech(4.3))
        audio.append(contentsOf: Self.silence(0.8))
        audio.append(contentsOf: Self.speech(5.1))
        audio.append(contentsOf: Self.silence(0.7))
        audio.append(contentsOf: Self.speech(13.0)) // forces a fixed cut too

        let a = Self.newSegmenter()
        a.append(audio)

        let b = Self.newSegmenter()
        var off = 0
        while off < audio.count {
            let end = min(off + 1600, audio.count)
            b.append(audio[off ..< end])
            off += 1600
        }

        while let sa = a.tryTakeSegment() {
            let sb = b.tryTakeSegment()
            #expect(sb != nil)
            #expect(sa.startSample == sb?.startSample)
            #expect(sa.endSample == sb?.endSample)
        }
        #expect(b.tryTakeSegment() == nil)
        #expect(a.cursor == b.cursor)
    }

    @Test("Offline tuning keeps a recording made at low gain")
    func offlineOptionsKeepQuietRecording() {
        // A 440 Hz tone at amplitude 0.002 (about -57 dBFS RMS): below the live -45 dBFS
        // gate, so the default energy classifier (no injected classifier) calls it silence.
        let quiet = Self.tone(amplitude: 0.002, seconds: 3)

        let live = StreamingSegmenter(options: .default)
        live.append(quiet)
        #expect(live.takeTail()?.containsSpeech == false)

        let options = StreamingSegmenterOptions.offline(for: quiet)
        let offline = StreamingSegmenter(options: options)
        offline.append(quiet)
        #expect(offline.takeTail()?.containsSpeech == true)

        // A normal level keeps the fixed gate.
        #expect(StreamingSegmenterOptions.offline(for: Self.tone(amplitude: 0.5, seconds: 3))
            .silenceThresholdDbfs == -45)
    }

    @Test("Offline tuning ignores a single transient and floors on room tone")
    func offlineOptionsAreRobust() {
        // Quiet speech plus one loud transient (a door slam): the threshold must follow
        // the speech, not the slam.
        var withTransient = Self.tone(amplitude: 0.002, seconds: 3)
        for i in 0 ..< (Self.rate / 20) { withTransient[Self.rate + i] = 0.9 }
        let robust = StreamingSegmenterOptions.offline(for: withTransient)
        #expect(robust.silenceThresholdDbfs < -45)

        let segmenter = StreamingSegmenter(options: robust)
        segmenter.append(withTransient)
        #expect(segmenter.takeTail()?.containsSpeech == true)

        // Room tone only (-80 dBFS): stays silence, or the model would hallucinate on it.
        let roomTone = Self.tone(amplitude: 0.0001, seconds: 3)
        let floored = StreamingSegmenterOptions.offline(for: roomTone)
        #expect(floored.silenceThresholdDbfs == StreamingSegmenterOptions.quietestUsefulDbfs)

        let silent = StreamingSegmenter(options: floored)
        silent.append(roomTone)
        #expect(silent.takeTail()?.containsSpeech == false)
    }

    private static func tone(amplitude: Float, seconds: Double) -> [Float] {
        (0 ..< Int(seconds * Double(rate))).map {
            amplitude * sin(2 * .pi * 440 * Float($0) / Float(rate))
        }
    }

    @Test("Queued segments come out in order")
    func queuedSegmentsComeOutInOrder() {
        let seg = Self.newSegmenter()
        for _ in 0 ..< 3 {
            seg.append(Self.speech(4.0))
            seg.append(Self.silence(0.7))
        }

        var prevEnd = 0
        var count = 0
        while let s = seg.tryTakeSegment() {
            #expect(s.endSample > prevEnd)
            prevEnd = s.endSample
            count += 1
        }
        #expect(count == 3)
    }
}
