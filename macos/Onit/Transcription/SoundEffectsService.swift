// SPDX-License-Identifier: GPL-3.0-or-later WITH AdditionRef-Cloudless-Voice-linking-exception
//
//  SoundEffectsService.swift
//  Onit
//
//  Plays short UI sound effects for dictation start/stop. Gated behind
//  `Defaults[.transcriptionSoundEffectsEnabled]` (off by default), so callers
//  fire effects unconditionally and the service no-ops when disabled.
//
//  All player work (asset decode, `AVAudioPlayer` prepare, and playback) runs on
//  a dedicated background queue so the caller never blocks. The first play
//  decodes the asset + prepares the player (~160ms); on the main thread that
//  would delay audio capture at dictation start, so `play(_:)` returns
//  immediately and the work happens off-thread. Call `prewarm()` once (e.g. at
//  launch) to do that decode ahead of time so even the first chime is prompt.
//

import AppKit
import AVFoundation
import Defaults
import Foundation

final class SoundEffectsService: @unchecked Sendable {

    static let shared = SoundEffectsService()

    /// The available dictation sound effects. Audio ships as data assets in
    /// `Assets.xcassets/Sounds` (loaded by `NSDataAsset`), matching the project's
    /// existing onboarding-video assets - reliably bundled by `actool`.
    enum Effect {
        case dictationStart
        case dictationStop

        var assetName: String {
            switch self {
            case .dictationStart: return "start-01"
            case .dictationStop:  return "finish-01"
            }
        }
    }

    /// Serializes all player access (cache + decode + playback) off the main
    /// thread. `players` must only be touched on this queue.
    private let queue = DispatchQueue(label: "com.onit.sound-effects", qos: .userInitiated)

    /// Players are cached + prepared on first use so repeated playback is low
    /// latency (no per-play decode). Accessed only on `queue`.
    private var players: [String: AVAudioPlayer] = [:]

    private init() {}

    /// Decode + prepare the players ahead of time so the first real play doesn't
    /// pay the one-time (~160ms) decode cost on the hot path. Safe to call more
    /// than once - subsequent calls hit the cache and no-op.
    func prewarm() {
        queue.async { [self] in
            _ = player(for: .dictationStart)
            _ = player(for: .dictationStop)
        }
    }

    /// Play `effect` when the user has enabled dictation sound effects. Returns
    /// immediately; playback happens on the background queue.
    func play(_ effect: Effect) {
        guard Defaults[.transcriptionSoundEffectsEnabled] else { return }
        enqueue(effect)
    }

    /// Play `effect` ignoring the enabled gate - used by the settings slider to
    /// preview the chosen volume regardless of the on/off state.
    func preview(_ effect: Effect) {
        enqueue(effect)
    }

    private func enqueue(_ effect: Effect) {
        // Read volume on the caller's thread (fast UserDefaults access), then do
        // all AVAudioPlayer work on the background queue. Clamp defensively.
        let volume = Float(min(max(Defaults[.transcriptionSoundEffectsVolume], 0), 1))
        queue.async { [self] in
            guard let player = player(for: effect) else { return }
            player.volume = volume
            player.currentTime = 0
            player.play()
        }
    }

    /// Resolve (and cache) the prepared player for `effect`. Must run on `queue`.
    private func player(for effect: Effect) -> AVAudioPlayer? {
        if let cached = players[effect.assetName] {
            return cached
        }
        guard let asset = NSDataAsset(name: effect.assetName) else {
            log.error("[SoundEffectsService] Missing sound asset: \(effect.assetName)")
            return nil
        }
        do {
            let player = try AVAudioPlayer(data: asset.data)
            player.prepareToPlay()
            players[effect.assetName] = player
            return player
        } catch {
            log.error("[SoundEffectsService] Failed to load \(effect.assetName): \(error)")
            return nil
        }
    }
}
