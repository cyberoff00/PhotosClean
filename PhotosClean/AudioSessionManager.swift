import AVFoundation

/// Centralized AVAudioSession handling for video playback.
///
/// Desired behavior (default `.duck`):
/// - When video plays with sound: keep external audio playing but duck (lower) it.
/// - When video pauses/stops/ends: release audio focus and restore external audio volume.
enum AudioSessionManager {
    enum VideoAudioPolicy {
        /// Interrupt other apps' audio (external audio stops). Other apps *may* resume when we deactivate.
        case interrupt
        /// Keep other apps playing but reduce their volume while the video has sound.
        /// This avoids the user-perceived "killing" of background audio.
        case duck
    }

    /// Activate an audio session suitable for short video preview playback.
    /// - Note: iOS does not guarantee that other apps will automatically resume after an interruption.
    ///         If you want the most user-friendly behavior (other audio keeps playing), use `.duck`.
    static func beginVideoAudio(policy: VideoAudioPolicy = .duck) {
        let session = AVAudioSession.sharedInstance()
        do {
            switch policy {
            case .interrupt:
                // Interrupt other audio and respect mute switch.
                try session.setCategory(.soloAmbient, mode: .moviePlayback, options: [])
            case .duck:
                // Keep other apps playing, but temporarily lower their volume.
                // Using .playback here ensures AVPlayer audio is routed reliably while still mixing.
                // (Mute behavior is still controlled by `player.isMuted` in the UI.)
                try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .duckOthers])
            }
            try session.setActive(true)
        } catch {
            // Intentionally ignore errors; playback will still work but may not control external audio.
        }
    }

    /// Deactivate the session and notify other apps so they can resume audio.
    static func endVideoAudio() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Intentionally ignore errors.
        }
    }
}
