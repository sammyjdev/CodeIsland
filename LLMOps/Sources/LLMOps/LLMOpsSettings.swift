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
        public static let endedRetentionSeconds = "llmops.live.endedRetentionSeconds" // default 60
        public static let hideIdleAfterSeconds = "llmops.live.hideIdleAfterSeconds"   // default 300
        public static let soundVolume = "llmops.sound.volume"                         // default 60
        public static let bringToFrontOnRequest = "llmops.live.bringToFrontOnRequest" // default true
        public static let requestPresentation = "llmops.live.requestPresentation"
        public static let judgeBinaryPath = "llmops.judge.binaryPath"   // default: NSHomeDirectory() + "/.local/bin/claude"
        public static let judgeModel = "llmops.judge.model"             // default: "sonnet"
        public static let antigravityUsagePath = "llmops.quotas.antigravityUsagePath"
        public static let zaiAuthPath = "llmops.quotas.zaiAuthPath"
        public static let islandVisibility = "llmops.island.visibility"
        public static let mascotSpeed = "llmops.island.mascotSpeed"
    }

    /// Newest (by version string, descending) NSHomeDirectory()/.nvm/versions/node/*/bin/antigravity-usage that exists,
    /// else "/usr/local/bin/antigravity-usage".
    public nonisolated static func defaultAntigravityUsagePath(
        home: String = NSHomeDirectory(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        let nodeDir = (home as NSString).appendingPathComponent(".nvm/versions/node")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: nodeDir) {
            let sortedVersions = contents.sorted { v1, v2 in
                v1.compare(v2, options: .numeric) == .orderedDescending
            }
            for version in sortedVersions {
                let candidate = ((nodeDir as NSString).appendingPathComponent(version) as NSString)
                    .appendingPathComponent("bin/antigravity-usage")
                if fileExists(candidate) {
                    return candidate
                }
            }
        }
        return "/usr/local/bin/antigravity-usage"
    }

    public var antigravityUsagePath: String {
        get {
            access(keyPath: \.antigravityUsagePath)
            return defaults.string(forKey: Key.antigravityUsagePath) ?? Self.defaultAntigravityUsagePath()
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            withMutation(keyPath: \.antigravityUsagePath) {
                defaults.set(newValue, forKey: Key.antigravityUsagePath)
            }
        }
    }

    public var zaiAuthPath: String {
        get {
            access(keyPath: \.zaiAuthPath)
            return defaults.string(forKey: Key.zaiAuthPath) ?? (NSHomeDirectory() + "/.local/share/opencode/auth.json")
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            withMutation(keyPath: \.zaiAuthPath) {
                defaults.set(newValue, forKey: Key.zaiAuthPath)
            }
        }
    }

    public enum RequestPresentation: String, CaseIterable, Sendable { case notch, front, none }

    public var judgeBinaryPath: String {
        get {
            access(keyPath: \.judgeBinaryPath)
            return defaults.string(forKey: Key.judgeBinaryPath) ?? (NSHomeDirectory() + "/.local/bin/claude")
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            withMutation(keyPath: \.judgeBinaryPath) {
                defaults.set(newValue, forKey: Key.judgeBinaryPath)
            }
        }
    }

    public var judgeModel: String {
        get {
            access(keyPath: \.judgeModel)
            return defaults.string(forKey: Key.judgeModel) ?? "sonnet"
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            withMutation(keyPath: \.judgeModel) {
                defaults.set(newValue, forKey: Key.judgeModel)
            }
        }
    }

    public var hideIdleAfterSeconds: Int {
        get {
            access(keyPath: \.hideIdleAfterSeconds)
            return defaults.object(forKey: Key.hideIdleAfterSeconds) as? Int ?? 300
        }
        set {
            let clamped = min(86400, max(0, newValue))
            withMutation(keyPath: \.hideIdleAfterSeconds) {
                defaults.set(clamped, forKey: Key.hideIdleAfterSeconds)
            }
        }
    }

    public var soundVolume: Int {
        get {
            access(keyPath: \.soundVolume)
            return defaults.object(forKey: Key.soundVolume) as? Int ?? 60
        }
        set {
            let clamped = min(100, max(0, newValue))
            withMutation(keyPath: \.soundVolume) {
                defaults.set(clamped, forKey: Key.soundVolume)
            }
        }
    }

    public var requestPresentation: RequestPresentation {
        get {
            access(keyPath: \.requestPresentation)
            if let raw = defaults.string(forKey: Key.requestPresentation),
               let presentation = RequestPresentation(rawValue: raw) {
                return presentation
            }
            if let legacy = defaults.object(forKey: Key.bringToFrontOnRequest) as? Bool, !legacy {
                return .none
            }
            return .notch
        }
        set {
            withMutation(keyPath: \.requestPresentation) {
                defaults.set(newValue.rawValue, forKey: Key.requestPresentation)
            }
        }
    }

    public var bringToFrontOnRequest: Bool {
        get {
            access(keyPath: \.bringToFrontOnRequest)
            return defaults.object(forKey: Key.bringToFrontOnRequest) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.bringToFrontOnRequest) {
                defaults.set(newValue, forKey: Key.bringToFrontOnRequest)
            }
        }
    }

    public var endedRetentionSeconds: Int {
        get {
            access(keyPath: \.endedRetentionSeconds)
            return defaults.object(forKey: Key.endedRetentionSeconds) as? Int ?? 60
        }
        set {
            let clamped = min(600, max(0, newValue))
            withMutation(keyPath: \.endedRetentionSeconds) {
                defaults.set(clamped, forKey: Key.endedRetentionSeconds)
            }
        }
    }

    public var islandVisibility: IslandVisibility {
        get {
            access(keyPath: \.islandVisibility)
            if let raw = defaults.string(forKey: Key.islandVisibility),
               let visibility = IslandVisibility(rawValue: raw) {
                return visibility
            }
            return .onlyPending
        }
        set {
            withMutation(keyPath: \.islandVisibility) {
                defaults.set(newValue.rawValue, forKey: Key.islandVisibility)
            }
        }
    }

    public var mascotSpeed: Int {
        get {
            access(keyPath: \.mascotSpeed)
            return defaults.object(forKey: Key.mascotSpeed) as? Int ?? 100
        }
        set {
            let clamped = min(300, max(25, newValue))
            withMutation(keyPath: \.mascotSpeed) {
                defaults.set(clamped, forKey: Key.mascotSpeed)
            }
        }
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
