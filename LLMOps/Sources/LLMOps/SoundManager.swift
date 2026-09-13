import AppKit
import Foundation

/// Plays 8-bit sound effects in response to hook events.
@MainActor
public final class SoundManager {
    public struct EventSound {
        public let event: String
        public let sound: String
        public let keyPath: KeyPath<LLMOpsSettings, Bool>
        public let label: String

        public init(event: String, sound: String, keyPath: KeyPath<LLMOpsSettings, Bool>, label: String) {
            self.event = event
            self.sound = sound
            self.keyPath = keyPath
            self.label = label
        }
    }

    /// Map event names to 8-bit WAV file names (without extension).
    public static let eventSounds: [EventSound] = [
        EventSound(event: "SessionStart", sound: "8bit_start", keyPath: \.soundSessionStart, label: "Session Start"),
        EventSound(event: "TaskRoundComplete", sound: "8bit_complete", keyPath: \.soundTaskComplete, label: "Task Complete"),
        EventSound(event: "Stop", sound: "8bit_complete", keyPath: \.soundTaskComplete, label: "Task Complete"),
        EventSound(event: "PostToolUseFailure", sound: "8bit_error", keyPath: \.soundTaskError, label: "Task Error"),
        EventSound(event: "PermissionRequest", sound: "8bit_approval", keyPath: \.soundApprovalNeeded, label: "Approval Needed"),
        EventSound(event: "UserPromptSubmit", sound: "8bit_submit", keyPath: \.soundPromptSubmit, label: "Prompt Submit"),
    ]

    private let settings: LLMOpsSettings
    private let nowProvider: () -> Date
    private var soundCache: [String: NSSound] = [:]

    /// For tests: the last sound name that would have been played, or nil.
    public private(set) var lastPlayed: String?

    /// For tests: when false, resolve the file and record `lastPlayed` without touching NSSound.
    public var audioEnabled: Bool

    public init(
        settings: LLMOpsSettings,
        audioEnabled: Bool = true,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.audioEnabled = audioEnabled
        self.nowProvider = nowProvider
    }

    /// Maps a normalized hook event name to a sound and plays it if that
    /// event's toggle is on, sound is enabled, and quiet hours do not apply.
    /// Mapping (same as parent): SessionStart -> 8bit_start, Stop and
    /// TaskRoundComplete -> 8bit_complete, PostToolUseFailure -> 8bit_error,
    /// PermissionRequest -> 8bit_approval, UserPromptSubmit -> 8bit_submit.
    public func handleEvent(_ eventName: String) {
        guard settings.soundEnabled else { return }
        guard !quietHoursActive else { return }
        guard let entry = Self.eventSounds.first(where: { $0.event == eventName }) else { return }
        guard settings[keyPath: entry.keyPath] else { return }
        play(entry.sound)
    }

    /// Play boot sound on app launch
    public func playBoot() {
        guard settings.soundEnabled else { return }
        guard !quietHoursActive else { return }
        guard settings.soundBoot else { return }
        play("8bit_boot")
    }

    /// Previews ignore quiet hours and per-event toggles (settings UI use).
    public func preview(_ soundName: String) {
        play(soundName)
    }

    private var quietHoursActive: Bool {
        guard settings.quietHoursEnabled else { return false }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: nowProvider())
        let currentMinutes = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return LLMOpsSettings.isInQuietHours(
            minutesSinceMidnight: currentMinutes,
            start: settings.quietHoursStartMinutes,
            end: settings.quietHoursEndMinutes
        )
    }

    private func soundURL(for name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Resources/Sounds")
    }

    private func play(_ name: String) {
        guard let url = soundURL(for: name) else { return }
        lastPlayed = name
        guard audioEnabled else { return }
        let sound = soundCache[name] ?? NSSound(contentsOf: url, byReference: false)
        if let sound {
            soundCache[name] = sound
            if sound.isPlaying { sound.stop() }
            sound.play()
        }
    }
}
