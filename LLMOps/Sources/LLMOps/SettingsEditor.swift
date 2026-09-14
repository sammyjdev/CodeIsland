import Foundation
import LLMOpsCore

/// Draft of the profiles table.
struct ProfilesDraft: Equatable {
    var profiles: [Profile]

    init(profiles: [Profile] = []) {
        self.profiles = profiles
    }

    /// Adds a profile with a unique id derived from `name` (lowercased, spaces to "-",
    /// non [a-z0-9-] dropped, "-2", "-3" suffix on collision). Empty name -> "profile".
    mutating func add(name: String, configDir: String) {
        var slug = ""
        for char in name.lowercased() {
            if char == " " {
                slug.append("-")
            } else if (char >= "a" && char <= "z") || (char >= "0" && char <= "9") || char == "-" {
                slug.append(char)
            }
        }
        if slug.isEmpty {
            slug = "profile"
        }

        var candidate = slug
        var counter = 2
        let existingIDs = Set(profiles.map(\.id))
        while existingIDs.contains(candidate) {
            candidate = "\(slug)-\(counter)"
            counter += 1
        }

        let newProfile = Profile(id: candidate, name: name, configDir: configDir, pathPrefixes: [])
        profiles.append(newProfile)
    }

    mutating func remove(id: String) {
        profiles.removeAll { $0.id == id }
    }

    mutating func addPrefix(_ prefix: String, to id: String) {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        if !profiles[index].pathPrefixes.contains(trimmed) {
            profiles[index].pathPrefixes.append(trimmed)
        }
    }

    mutating func removePrefix(_ prefix: String, from id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].pathPrefixes.removeAll { $0 == prefix }
    }

    /// Non-empty name and configDir for every profile, unique ids, at least one profile.
    var isValid: Bool {
        guard !profiles.isEmpty else { return false }
        let ids = profiles.map(\.id)
        guard Set(ids).count == ids.count else { return false }
        for profile in profiles {
            if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
            if profile.configDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return false
            }
        }
        return true
    }
}

enum ListField {
    /// "Bash, Read ,  Grep" -> ["Bash", "Read", "Grep"] (trimmed, empties dropped, order kept, duplicates dropped).
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for part in text.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    static func join(_ items: [String]) -> String {
        items.joined(separator: ", ")
    }
}

enum Minutes {
    static func text(_ minutes: Int) -> String {
        let clamped = max(0, minutes)
        let hours = (clamped / 60) % 24
        let mins = clamped % 60
        return String(format: "%02d:%02d", hours, mins)
    }

    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        guard h >= 0 && h < 24 && m >= 0 && m < 60 else { return nil }
        return h * 60 + m
    }
}

/// Per-view state (ObservableObject, see toolchain rule).
@MainActor
final class SettingsState: ObservableObject {
    @Published var draft: ProfilesDraft
    @Published var newProfileName = ""
    @Published var newProfileDir = ""
    @Published var newPrefix: [String: String] = [:]
    @Published var autoApproveText = ""
    @Published var excludedText = ""
    @Published var quietStartText = ""
    @Published var quietEndText = ""
    @Published var endedRetentionText = ""
    @Published var hideIdleAfterText = ""

    init(profiles: [Profile], settings: LLMOpsSettings) {
        self.draft = ProfilesDraft(profiles: profiles)
        self.newProfileName = ""
        self.newProfileDir = ""
        self.newPrefix = [:]
        self.autoApproveText = ListField.join(settings.autoApproveTools)
        self.excludedText = ListField.join(settings.excludedCwdSubstrings)
        self.quietStartText = Minutes.text(settings.quietHoursStartMinutes)
        self.quietEndText = Minutes.text(settings.quietHoursEndMinutes)
        self.endedRetentionText = "\(settings.endedRetentionSeconds)"
        self.hideIdleAfterText = "\(settings.hideIdleAfterSeconds)"
    }
}
