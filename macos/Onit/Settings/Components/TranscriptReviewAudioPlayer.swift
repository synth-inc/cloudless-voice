// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  TranscriptReviewAudioPlayer.swift
//  Onit
//
//  Created by Kévin Naudin on 2026-04-28.
//

import AVFoundation
import SwiftUI

/// Compact audio player used inside the review modal. Renders a static
/// waveform (bars downsampled from the WAV samples), a play/pause button,
/// a `mm:ss / mm:ss` timestamp and a loop toggle.
///
/// Bars rendered before the current playback position are tinted darker so
/// progress is visible without a scrubber handle.
struct TranscriptReviewAudioPlayer: View {
    // MARK: - Properties

    let historyItem: TranscriptionHistory

    // MARK: - States

    @State private var isLoadingAudio: Bool = true
    @State private var loadFailed: Bool = false

    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlaying: Bool = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var progressTimer: Timer?
    @State private var loopEnabled: Bool = false

    /// Pre-computed bar heights (0...1), generated once from the loaded samples.
    @State private var barHeights: [CGFloat] = []

    // MARK: - Layout constants

    private let barCount: Int = 80
    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 3
    private let minBarHeight: CGFloat = 3
    private let maxBarHeight: CGFloat = 25
    private let actionButtonSize: CGFloat = 28
    private let actionIconSize: CGFloat = 18

    // MARK: - Body

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            playPauseButton

            waveform
                .frame(maxWidth: .infinity, alignment: .leading)

            timestampLabel

            loopButton
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.T_9)
        )
        // `.task` and not `.onAppear`: it is cancelled when the row changes or the view
        // goes away, so arrowing through the queue cannot stack whole-file reads.
        .task(id: historyItem.id) { await loadAudio() }
        .onDisappear { stopPlayback() }
    }

    // MARK: - Sub-views

    private var playPauseButton: some View {
        Button(action: togglePlayback) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: actionIconSize, weight: .semibold))
                .foregroundColor(Color.S_0)
                .frame(width: actionButtonSize, height: actionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(audioPlayer == nil)
        .opacity(audioPlayer == nil ? 0.4 : 1)
    }

    /// Renders only as many bars as fit in the available width so the player
    /// doesn't push past its parent (audio player container) when the modal is
    /// laid out at its design width - the full `barCount` (80) has a minimum
    /// intrinsic width that exceeds the modal's content area.
    private var waveform: some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width)
            let barUnit = barWidth + barSpacing
            let visibleCount = min(
                barHeights.count,
                max(0, Int((availableWidth + barSpacing) / barUnit))
            )

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<visibleCount, id: \.self) { index in
                    let normalized = barHeights[index]
                    let progress = duration > 0 ? currentTime / duration : 0
                    let played = Double(index) / Double(max(1, visibleCount - 1)) <= progress
                    RoundedRectangle(cornerRadius: 3)
                        .fill(played ? Color.S_0 : Color.T_3)
                        .frame(
                            width: barWidth,
                            height: barHeight(for: normalized)
                        )
                }
            }
            .frame(width: availableWidth, height: maxBarHeight, alignment: .leading)
            // Make the full row (including gaps between bars) hit-tested,
            // not just the bars themselves - a click anywhere in the strip
            // should seek to that position.
            .contentShape(Rectangle())
            // `minimumDistance: 0` turns this into a tap-AND-drag handler:
            // a single click seeks once, holding down lets the user scrub
            // continuously through the clip.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        seek(toX: value.location.x, in: availableWidth)
                    }
            )
        }
        .frame(height: maxBarHeight)
    }

    /// Maps a horizontal pixel offset within the waveform to a playback
    /// position and applies it to the player. Triggered by both a single
    /// tap and a drag scrub on the waveform.
    private func seek(toX x: CGFloat, in width: CGFloat) {
        guard let player = audioPlayer, duration > 0, width > 0 else { return }
        let clampedX = max(0, min(width, x))
        let target = Double(clampedX / width) * duration
        player.currentTime = target
        currentTime = target
        // Defensive resync: if our local `isPlaying` flag thinks playback is
        // active but `AVAudioPlayer` paused itself under the hood (e.g. a
        // seek-during-end-of-clip glitch), kick it back into play so the
        // scrub doesn't silently leave the player stuck. A paused-scrub
        // (`isPlaying == false`) intentionally falls through and stays paused.
        if isPlaying, !player.isPlaying {
            player.play()
        }
    }

    private var timestampLabel: some View {
        Text("\(formatTime(currentTime)) / \(formatTime(duration))")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundColor(Color.T_2)
    }

    private var loopButton: some View {
        Button {
            loopEnabled.toggle()
            audioPlayer?.numberOfLoops = loopEnabled ? -1 : 0
        } label: {
            Image(systemName: "repeat")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(loopEnabled ? Color.S_0 : Color.T_3)
                .frame(width: actionButtonSize, height: actionButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(audioPlayer == nil)
    }

    // MARK: - Helpers

    private func barHeight(for normalized: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, normalized))
        return minBarHeight + clamped * (maxBarHeight - minBarHeight)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Audio loading

    private func loadAudio() async {
        isLoadingAudio = true
        loadFailed = false

        let manager = TranscriptionHistoryManager.shared
        guard let audioURL = manager.audioFileURL(for: historyItem) else {
            isLoadingAudio = false
            loadFailed = true
            return
        }

        // Read and scan off the main actor: a dictation is a few seconds, but a file
        // transcript's audio runs up to 30 min (28.8 M samples to scan).
        let item = historyItem
        let count = barCount
        let bars = await Task.detached(priority: .userInitiated) {
            Self.computeBars(from: manager.loadAudioSamples(for: item) ?? [], count: count)
        }.value
        guard !Task.isCancelled else { return }

        do {
            // From the URL, not from a `Data` copy: that copy is 57 MB for a 30 min file.
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.prepareToPlay()
            player.numberOfLoops = loopEnabled ? -1 : 0
            audioPlayer = player
            duration = player.duration
            barHeights = bars
        } catch {
            loadFailed = true
        }
        isLoadingAudio = false
    }

    /// Reduces the raw audio samples to `count` peak-magnitude bars in [0,1].
    nonisolated private static func computeBars(from samples: [Float], count: Int) -> [CGFloat] {
        guard !samples.isEmpty, count > 0 else {
            // Fall back to a flat low-amplitude bar pattern when no audio is available.
            return Array(repeating: 0.15, count: max(0, count))
        }
        let bucketSize = max(1, samples.count / count)
        var bars: [CGFloat] = []
        bars.reserveCapacity(count)
        var index = 0
        while bars.count < count && index < samples.count {
            let end = min(samples.count, index + bucketSize)
            var peak: Float = 0
            for i in index..<end {
                let amp = abs(samples[i])
                if amp > peak { peak = amp }
            }
            bars.append(CGFloat(peak))
            index = end
        }
        // Pad if the final bucket was short.
        while bars.count < count { bars.append(0.15) }

        // Normalize so the loudest peak fills the bar.
        let maxPeak = bars.max() ?? 1
        guard maxPeak > 0 else { return bars }
        return bars.map { $0 / maxPeak }
    }

    // MARK: - Playback

    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard let player = audioPlayer else { return }
        player.play()
        isPlaying = true
        startProgressTimer()
    }

    private func pausePlayback() {
        audioPlayer?.pause()
        isPlaying = false
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in tickProgress() }
        }
    }

    /// Self-invalidates if the player vanished (sheet dismissed before
    /// `.onDisappear` ran, view torn down by `.id(...)` change, etc.) so the
    /// 30 Hz tick doesn't keep firing into stale @State.
    private func tickProgress() {
        guard let player = audioPlayer else {
            progressTimer?.invalidate()
            progressTimer = nil
            return
        }
        if player.isPlaying {
            currentTime = player.currentTime
        } else if !loopEnabled, currentTime >= duration - 0.1 {
            isPlaying = false
            currentTime = 0
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }
}
