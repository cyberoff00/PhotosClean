import AVFoundation
import UIKit

/// Swipe feedback styles. Each style is a family: the delete direction always
/// plays the whoosh ("throwing it away"), keep/maybe play the style's tap, and
/// consecutive swipes climb one semitone per swipe (pre-rendered variants
/// swipe_<name>_0...5) — the combo escalation is what makes rapid sorting feel
/// rewarding, far more than the timbre of any single click.
enum SwipeSoundStyle: String, CaseIterable, Identifiable {
    case off
    case bubble
    case click
    case glass
    case mech

    var id: String { rawValue }

    static let storageKey = "swipe_sound_style"

    static func current() -> SwipeSoundStyle {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? SwipeSoundStyle.off.rawValue
        if let style = SwipeSoundStyle(rawValue: raw) { return style }
        // Migrate v1 single-sound values.
        switch raw {
        case "tock": return .click
        case "tink": return .glass
        case "swoosh": return .bubble
        case "shutter": return .mech
        default: return .off
        }
    }

    var label: String {
        "settings.sound.\(rawValue)".localized
    }

    /// Base file played for keep/maybe swipes; nil disables sound.
    var tapFile: String? {
        switch self {
        case .off: return nil
        case .bubble: return "swipe_pop"
        case .click: return "swipe_click"
        case .glass: return "swipe_glass"
        case .mech: return "swipe_clunk"
        }
    }
}

final class SwipeFeedback {
    static let shared = SwipeFeedback()

    /// Highest combo pitch step (semitones above the base sound).
    private static let maxPitchStep = 5
    /// A pause longer than this resets the combo back to the base pitch.
    private let comboWindow: TimeInterval = 3.0

    /// setCategory / implicit session activation can block; keep every touch of
    /// the players and the audio session off the main thread.
    private let queue = DispatchQueue(label: "com.claire.tastytidy.swipeSound")
    private var players: [String: AVAudioPlayer] = [:]
    private var sessionConfigured = false
    private var streak = 0
    private var lastSwipeAt: TimeInterval = 0

    /// Single entry point for the swipe commit paths. Call on the main thread.
    func swipe(status: String) {
        let style = SwipeSoundStyle.current()
        guard let tapFile = style.tapFile else { return }
        let now = CACurrentMediaTime()
        queue.async {
            if now - self.lastSwipeAt > self.comboWindow {
                self.streak = 0
            } else {
                self.streak += 1
            }
            self.lastSwipeAt = now
            let step = min(self.streak, Self.maxPitchStep)

            self.configureSessionIfNeeded()
            let file = status == "delete" ? "swipe_swoosh" : tapFile
            guard let player = self.player(named: "\(file)_\(step)") else { return }
            player.volume = status == "maybe" ? 0.65 : 1.0
            player.currentTime = 0
            player.play()
        }
    }

    /// Three rising taps — demos the combo escalation from the settings picker.
    func preview(style: SwipeSoundStyle) {
        guard let tapFile = style.tapFile else { return }
        for (i, step) in [0, 2, 4].enumerated() {
            queue.asyncAfter(deadline: .now() + .milliseconds(170 * i)) {
                self.configureSessionIfNeeded()
                guard let player = self.player(named: "\(tapFile)_\(step)") else { return }
                player.currentTime = 0
                player.play()
            }
        }
    }

    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        // Stay audible with the silent switch on (the user explicitly opted
        // into sound). Video previews (AudioSessionManager) already run
        // .playback; only claim the category when nothing else has, and always
        // mix so we never interrupt the user's background music.
        if session.category != .playback {
            try? session.setCategory(.playback, options: [.mixWithOthers])
        }
    }

    private func player(named name: String) -> AVAudioPlayer? {
        if let cached = players[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav")
                ?? Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[name] = player
        return player
    }
}
