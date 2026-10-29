// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  AudioPlaybackService.swift
//  Onit
//
//  Created by Kévin Naudin on 21/01/2026.
//

import AVFoundation
import Foundation

/// Service for playing back recorded transcription audio.
/// Uses AVAudioEngine with AVAudioPlayerNode for smooth playback.
@MainActor
final class AudioPlaybackService: ObservableObject {

    // MARK: - Singleton

    static let shared = AudioPlaybackService()

    // MARK: - Published Properties

    /// Whether audio is currently playing
    @Published private(set) var isPlaying = false

    /// Current playback position in seconds
    @Published private(set) var currentTime: TimeInterval = 0

    /// Total duration of loaded audio in seconds
    @Published private(set) var duration: TimeInterval = 0

    /// Maximum user trim multiplier (slider range 0..maxGain, where 1.0 = normalized level)
    static let maxGain: Float = 6.0

    /// Target peak amplitude after normalization (-3 dBFS)
    private static let normalizationTargetPeak: Float = 0.7

    /// Maximum normalization gain to avoid amplifying silence/noise to full scale
    private static let maxNormalizationGain: Float = 20.0

    /// User trim multiplier around the normalized level (1.0 = play at normalized volume)
    @Published var gain: Float = 2.0 {
        didSet {
            // Update mixer volume in real-time (no buffer recreation needed)
            gainMixerNode?.outputVolume = gain / Self.maxGain
        }
    }

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var gainMixerNode: AVAudioMixerNode?
    private var audioBuffer: AVAudioPCMBuffer?
    private var audioFormat: AVAudioFormat?

    private var updateTimer: Timer?
    private var playbackStartTime: TimeInterval = 0
    private var playbackStartSampleTime: AVAudioFramePosition = 0

    /// Generation counter to invalidate stale completion handlers after seek/stop
    private var playbackGeneration = 0

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Load audio samples for playback
    /// - Parameters:
    ///   - samples: Float32 audio samples (mono)
    ///   - sampleRate: Sample rate of the audio (default: 16000 Hz)
    func loadAudio(samples: [Float], sampleRate: Double = 16000) {
        stop()

        guard !samples.isEmpty else {
            log.warning("AudioPlaybackService: Cannot load empty audio samples")
            return
        }

        // Create audio format (mono, float32)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            log.error("AudioPlaybackService: Failed to create audio format")
            return
        }

        // Create audio buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            log.error("AudioPlaybackService: Failed to create audio buffer")
            return
        }

        // Normalize the buffer to a target peak level (-3 dBFS).
        // Only normGain is baked into the buffer; the user gain slider is applied
        // separately by the mixer node (gainMixerNode.outputVolume = gain / maxGain).
        // Writing normGain * maxGain into the buffer previously caused out-of-range
        // float values that the engine couldn't clip cleanly, producing distortion.
        let peak = samples.reduce(0 as Float) { max($0, abs($1)) }
        let normGain: Float
        if peak > 0.001 {
            normGain = min(Self.normalizationTargetPeak / peak, Self.maxNormalizationGain)
        } else {
            normGain = 1.0
        }
        log.info("AudioPlaybackService: normGain=\(String(format: "%.2f", normGain))x (peak=\(String(format: "%.4f", peak)))")

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<samples.count {
                channelData[i] = samples[i] * normGain
            }
        }

        self.audioFormat = format
        self.audioBuffer = buffer
        self.duration = Double(samples.count) / sampleRate
        self.currentTime = 0

        log.info("AudioPlaybackService: Loaded \(String(format: "%.1f", duration))s of audio")
    }

    /// Start or resume playback
    func play() {
        guard let buffer = audioBuffer, let format = audioFormat else {
            log.warning("AudioPlaybackService: No audio loaded")
            return
        }

        if isPlaying {
            return
        }

        // Setup audio engine if needed
        if audioEngine == nil {
            setupAudioEngine(format: format)
        }

        guard let engine = audioEngine, let player = playerNode else {
            log.error("AudioPlaybackService: Audio engine not initialized")
            return
        }

        do {
            if !engine.isRunning {
                try engine.start()
            }

            // Clear any previously scheduled buffers (e.g., from a paused state)
            // This triggers completion handlers, but they'll be ignored due to generation check
            playbackGeneration += 1
            player.stop()

            // Schedule buffer for playback from current position
            let startFrame = AVAudioFramePosition(currentTime * format.sampleRate)
            let remainingFrames = AVAudioFrameCount(buffer.frameLength) - AVAudioFrameCount(startFrame)

            if remainingFrames > 0 {
                // Create a sub-buffer starting from current position
                if let subBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remainingFrames) {
                    subBuffer.frameLength = remainingFrames
                    if let srcData = buffer.floatChannelData?[0],
                       let dstData = subBuffer.floatChannelData?[0] {
                        dstData.assign(from: srcData.advanced(by: Int(startFrame)), count: Int(remainingFrames))
                    }

                    playbackStartTime = currentTime
                    playbackStartSampleTime = 0

                    let currentGeneration = playbackGeneration
                    player.scheduleBuffer(subBuffer) { [weak self] in
                        Task { @MainActor in
                            self?.handlePlaybackComplete(generation: currentGeneration)
                        }
                    }

                    player.play()
                    isPlaying = true
                    startUpdateTimer()

                    log.info("AudioPlaybackService: Started playback from \(String(format: "%.1f", currentTime))s")
                }
            }
        } catch {
            log.error("AudioPlaybackService: Failed to start playback: \(error.localizedDescription)")
        }
    }

    /// Pause playback
    func pause() {
        guard isPlaying, let player = playerNode else { return }

        player.pause()
        isPlaying = false
        stopUpdateTimer()

        // Update current time based on player position
        if let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime) {
            currentTime = playbackStartTime + Double(playerTime.sampleTime) / playerTime.sampleRate
        }

        log.info("AudioPlaybackService: Paused at \(String(format: "%.1f", currentTime))s")
    }

    /// Stop playback and reset to beginning
    func stop() {
        playerNode?.stop()
        audioEngine?.stop()
        isPlaying = false
        currentTime = 0
        stopUpdateTimer()

        // Clean up
        audioEngine = nil
        playerNode = nil
        gainMixerNode = nil
    }

    /// Seek to a specific time
    /// - Parameter time: Time in seconds to seek to
    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying

        if isPlaying {
            playbackGeneration += 1  // Invalidate pending completion handlers
            playerNode?.stop()
            isPlaying = false
        }

        currentTime = max(0, min(time, duration))

        if wasPlaying {
            play()
        }
    }

    /// Clear loaded audio
    func clear() {
        stop()
        audioBuffer = nil
        audioFormat = nil
        duration = 0
        currentTime = 0
    }

    // MARK: - Private Methods


    private func setupAudioEngine(format: AVAudioFormat) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let gainMixer = AVAudioMixerNode()

        engine.attach(player)
        engine.attach(gainMixer)

        // Connect: player -> gainMixer -> mainMixer
        engine.connect(player, to: gainMixer, format: format)
        engine.connect(gainMixer, to: engine.mainMixerNode, format: nil)

        // Set initial volume based on current gain
        gainMixer.outputVolume = gain / Self.maxGain

        self.audioEngine = engine
        self.playerNode = player
        self.gainMixerNode = gainMixer
    }

    private func handlePlaybackComplete(generation: Int) {
        // Ignore stale completion handlers from previous playback sessions
        guard generation == playbackGeneration else { return }

        isPlaying = false
        currentTime = 0  // Reset to beginning so play() will replay from start
        stopUpdateTimer()
        log.info("AudioPlaybackService: Playback complete")
    }

    private func startUpdateTimer() {
        stopUpdateTimer()

        // Use Timer for macOS (CADisplayLink is iOS-only)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePlaybackTime()
            }
        }
        // Add to common mode so timer fires during gesture tracking (e.g., slider drag)
        if let timer = updateTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func updatePlaybackTime() {
        guard isPlaying,
              let player = playerNode,
              let nodeTime = player.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return
        }

        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        currentTime = min(playbackStartTime + elapsed, duration)
    }
}
