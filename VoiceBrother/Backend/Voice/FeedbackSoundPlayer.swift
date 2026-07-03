import AppKit
import AudioToolbox
import Foundation

/// Plays the short start/end feedback cues for a voice recording.
//
// Why these are stored properties (not `NSSound(named:)?.play()` inline):
// The inline pattern creates a temporary NSSound that ARC drops as soon as the
// expression returns. macOS often (but not always) keeps the sound playing via
// its own retain inside `play()`, but in practice — especially for short clips
// played in rapid succession — the dealloc races the playback start and the
// sound is silenced. Holding the instance for the lifetime of the service
// makes playback reliable. Also: pre-loading from the system .aiff file via
// file URL is more robust than `NSSound(named:)`, which depends on the sound
// being registered in the search paths.
@MainActor
final class FeedbackSoundPlayer {
    private lazy var startSound: NSSound? = Self.loadSystemSound(named: "Tink")
    private lazy var endSound: NSSound? = Self.loadSystemSound(named: "Pop")

    private static func loadSystemSound(named name: String) -> NSSound? {
        let path = "/System/Library/Sounds/\(name).aiff"
        if FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let sound = NSSound(contentsOf: url, byReference: true) {
                sound.volume = 0.5
                return sound
            }
        }
        // Fall back to the named lookup (works if the sound is in standard search paths)
        return NSSound(named: NSSound.Name(name))
    }

    /// Plays a short cue when recording starts. Prefers the held NSSound (volume-controlled
    /// and reliable). If that's nil for any reason — sound file missing, audio device contention —
    /// falls back to AudioServicesPlaySystemSoundID, which uses CoreAudio's UI-feedback path
    /// and is harder to silence.
    func playStartSound() {
        if let sound = startSound {
            if sound.isPlaying { sound.stop() }
            sound.play()
        } else {
            AudioServicesPlaySystemSound(1057) // Tink
        }
    }

    func playEndSound() {
        if let sound = endSound {
            if sound.isPlaying { sound.stop() }
            sound.play()
        } else {
            AudioServicesPlaySystemSound(1103) // Pop-ish
        }
    }
}
