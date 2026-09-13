import Foundation
import Observation

@MainActor @Observable
public final class LLMOpsSettings {
    public enum Key {
        public static let soundEnabled = "llmops.sound.enabled"          // default true
        public static let soundBoot = "llmops.sound.boot"                // default true
        public static let soundSessionStart = "llmops.sound.sessionStart" // default true
        public static let soundTaskComplete = "llmops.sound.taskComplete" // default true
        public static let soundTaskError = "llmops.sound.taskError"       // default true
        public static let soundApprovalNeeded = "llmops.sound.approvalNeeded" // default true
        public static let soundPromptSubmit = "llmops.sound.promptSubmit" // default false
        public static let quietHoursEnabled = "llmops.quietHours.enabled" // default false
        public static let quietHoursStart = "llmops.quietHours.startMinutes" // default 22*60
        public static let quietHoursEnd = "llmops.quietHours.endMinutes"     // default 8*60
        public static let autoApproveTools = "llmops.hooks.autoApproveTools" // [String], default []
        public static let excludedCwdSubstrings = "llmops.hooks.excludedCwdSubstrings" // [String], default []
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    public var soundEnabled: Bool {
        get {
            access(keyPath: \.soundEnabled)
            return defaults.object(forKey: Key.soundEnabled) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.soundEnabled) {
                defaults.set(newValue, forKey: Key.soundEnabled)
            }
        }
    }

    public var soundBoot: Bool {
        get {
            access(keyPath: \.soundBoot)
            return defaults.object(forKey: Key.soundBoot) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.soundBoot) {
                defaults.set(newValue, forKey: Key.soundBoot)
            }
        }
    }

    public var soundSessionStart: Bool {
        get {
            access(keyPath: \.soundSessionStart)
            return defaults.object(forKey: Key.soundSessionStart) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.soundSessionStart) {
                defaults.set(newValue, forKey: Key.soundSessionStart)
            }
        }
    }

    public var soundTaskComplete: Bool {
        get {
            access(keyPath: \.soundTaskComplete)
            return defaults.object(forKey: Key.soundTaskComplete) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.soundTaskComplete) {
                defaults.set(newValue, forKey: Key.soundTaskComplete)
            }
        }
    }

    public var soundTaskError: Bool {
        get {
            access(keyPath: \.soundTaskError)
            return defaults.object(forKey: Key.soundTaskError) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.soundTaskError) {
                defaults.set(newValue, forKey: Key.soundTaskError)
            }
        }
    }

    public var soundApprovalNeeded: Bool {
        get {
            access(keyPath: \.soundApprovalNeeded)
            return defaults.object(forKey: Key.soundApprovalNeeded) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.soundApprovalNeeded) {
                defaults.set(newValue, forKey: Key.soundApprovalNeeded)
            }
        }
    }

    public var soundPromptSubmit: Bool {
        get {
            access(keyPath: \.soundPromptSubmit)
            return defaults.object(forKey: Key.soundPromptSubmit) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.soundPromptSubmit) {
                defaults.set(newValue, forKey: Key.soundPromptSubmit)
            }
        }
    }

    public var quietHoursEnabled: Bool {
        get {
            access(keyPath: \.quietHoursEnabled)
            return defaults.object(forKey: Key.quietHoursEnabled) as? Bool ?? false
        }
        set {
            withMutation(keyPath: \.quietHoursEnabled) {
                defaults.set(newValue, forKey: Key.quietHoursEnabled)
            }
        }
    }

    public var quietHoursStartMinutes: Int {
        get {
            access(keyPath: \.quietHoursStartMinutes)
            return defaults.object(forKey: Key.quietHoursStart) as? Int ?? (22 * 60)
        }
        set {
            withMutation(keyPath: \.quietHoursStartMinutes) {
                defaults.set(newValue, forKey: Key.quietHoursStart)
            }
        }
    }

    public var quietHoursEndMinutes: Int {
        get {
            access(keyPath: \.quietHoursEndMinutes)
            return defaults.object(forKey: Key.quietHoursEnd) as? Int ?? (8 * 60)
        }
        set {
            withMutation(keyPath: \.quietHoursEndMinutes) {
                defaults.set(newValue, forKey: Key.quietHoursEnd)
            }
        }
    }

    public var autoApproveTools: [String] {
        get {
            access(keyPath: \.autoApproveTools)
            return defaults.stringArray(forKey: Key.autoApproveTools) ?? []
        }
        set {
            withMutation(keyPath: \.autoApproveTools) {
                defaults.set(newValue, forKey: Key.autoApproveTools)
            }
        }
    }

    public var excludedCwdSubstrings: [String] {
        get {
            access(keyPath: \.excludedCwdSubstrings)
            return defaults.stringArray(forKey: Key.excludedCwdSubstrings) ?? []
        }
        set {
            withMutation(keyPath: \.excludedCwdSubstrings) {
                defaults.set(newValue, forKey: Key.excludedCwdSubstrings)
            }
        }
    }

    /// Pure. True when `minutesSinceMidnight` falls inside [start, end), handling
    /// windows that cross midnight (start 22:00, end 08:00). start == end means
    /// the window is empty (never quiet). Copy the parent's logic.
    public nonisolated static func isInQuietHours(minutesSinceMidnight m: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false }
        if start < end { return m >= start && m < end }
        return m >= start || m < end
    }
}
