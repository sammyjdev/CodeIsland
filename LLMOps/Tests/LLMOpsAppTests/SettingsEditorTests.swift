import Foundation
import Testing
import LLMOpsCore
@testable import LLMOps

@Suite struct SettingsEditorTests {

    // 1. ProfilesDraft.add derives ids: "Work Laptop" -> "work-laptop";
    // adding "Work Laptop" again -> "work-laptop-2"; empty name -> "profile";
    // configDir stored as given.
    @Test func addDerivesIds() {
        var draft = ProfilesDraft(profiles: [])
        draft.add(name: "Work Laptop", configDir: "~/.claude-work")
        #expect(draft.profiles.count == 1)
        #expect(draft.profiles[0].id == "work-laptop")
        #expect(draft.profiles[0].name == "Work Laptop")
        #expect(draft.profiles[0].configDir == "~/.claude-work")
        #expect(draft.profiles[0].pathPrefixes == [])

        draft.add(name: "Work Laptop", configDir: "~/.claude-work-2")
        #expect(draft.profiles.count == 2)
        #expect(draft.profiles[1].id == "work-laptop-2")
        #expect(draft.profiles[1].name == "Work Laptop")
        #expect(draft.profiles[1].configDir == "~/.claude-work-2")

        draft.add(name: "", configDir: "~/.claude-empty")
        #expect(draft.profiles.count == 3)
        #expect(draft.profiles[2].id == "profile")
        #expect(draft.profiles[2].configDir == "~/.claude-empty")
    }

    // 2. remove(id:), addPrefix (ignores empty and duplicates), removePrefix behave;
    // isValid is false with an empty name, an empty configDir, duplicate ids, or zero profiles.
    @Test func removeAndPrefixOperationsAndIsValid() {
        var draft = ProfilesDraft(profiles: [
            Profile(id: "p1", name: "P1", configDir: "~/.c1", pathPrefixes: ["~/dir1"])
        ])
        #expect(draft.isValid)

        // addPrefix ignores empty and duplicates
        draft.addPrefix("", to: "p1")
        draft.addPrefix("   ", to: "p1")
        #expect(draft.profiles[0].pathPrefixes == ["~/dir1"])

        draft.addPrefix("~/dir1", to: "p1")
        #expect(draft.profiles[0].pathPrefixes == ["~/dir1"])

        draft.addPrefix("~/dir2", to: "p1")
        #expect(draft.profiles[0].pathPrefixes == ["~/dir1", "~/dir2"])

        // removePrefix
        draft.removePrefix("~/dir1", from: "p1")
        #expect(draft.profiles[0].pathPrefixes == ["~/dir2"])

        // remove(id:)
        draft.remove(id: "p1")
        #expect(draft.profiles.isEmpty)
        #expect(!draft.isValid) // zero profiles -> false

        // isValid is false with an empty name
        let dEmptyName = ProfilesDraft(profiles: [
            Profile(id: "p1", name: "", configDir: "~/.c1", pathPrefixes: [])
        ])
        #expect(!dEmptyName.isValid)

        let dWhitespaceName = ProfilesDraft(profiles: [
            Profile(id: "p1", name: "   ", configDir: "~/.c1", pathPrefixes: [])
        ])
        #expect(!dWhitespaceName.isValid)

        // isValid is false with an empty configDir
        let dEmptyDir = ProfilesDraft(profiles: [
            Profile(id: "p1", name: "P1", configDir: "", pathPrefixes: [])
        ])
        #expect(!dEmptyDir.isValid)

        let dWhitespaceDir = ProfilesDraft(profiles: [
            Profile(id: "p1", name: "P1", configDir: "   ", pathPrefixes: [])
        ])
        #expect(!dWhitespaceDir.isValid)

        // isValid is false with duplicate ids
        let dDuplicate = ProfilesDraft(profiles: [
            Profile(id: "dup", name: "A", configDir: "~/.a", pathPrefixes: []),
            Profile(id: "dup", name: "B", configDir: "~/.b", pathPrefixes: [])
        ])
        #expect(!dDuplicate.isValid)

        // isValid is true with valid profiles
        let dValid = ProfilesDraft(profiles: [
            Profile(id: "p1", name: "A", configDir: "~/.a", pathPrefixes: []),
            Profile(id: "p2", name: "B", configDir: "~/.b", pathPrefixes: [])
        ])
        #expect(dValid.isValid)
    }

    // 3. ListField.parse("Bash, Read ,  Grep, Bash") == ["Bash", "Read", "Grep"]; join round-trips.
    @Test func listFieldParsingAndJoining() {
        let parsed = ListField.parse("Bash, Read ,  Grep, Bash")
        #expect(parsed == ["Bash", "Read", "Grep"])

        let joined = ListField.join(parsed)
        #expect(joined == "Bash, Read, Grep")

        #expect(ListField.parse(joined) == parsed)
        #expect(ListField.parse("") == [])
        #expect(ListField.parse("   ") == [])
    }

    // 4. Minutes.text(1320) == "22:00", Minutes.text(485) == "08:05";
    // parse("22:00") == 1320, parse("8:05") == 485, parse("24:00") == nil, parse("abc") == nil.
    @Test func minutesFormattingAndParsing() {
        #expect(Minutes.text(1320) == "22:00")
        #expect(Minutes.text(485) == "08:05")
        #expect(Minutes.parse("22:00") == 1320)
        #expect(Minutes.parse("8:05") == 485)
        #expect(Minutes.parse("24:00") == nil)
        #expect(Minutes.parse("abc") == nil)
        #expect(Minutes.parse("23:60") == nil)
        #expect(Minutes.parse("-1:00") == nil)
    }

    // 5. SettingsState(profiles:settings:) seeds autoApproveText, excludedText,
    // quietStartText, quietEndText from a settings object with non-default values.
    @Test @MainActor func settingsStateSeedsFields() {
        let suite = "SettingsStateTests-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = LLMOpsSettings(userDefaults: defaults)
        settings.autoApproveTools = ["Bash", "GlobTool"]
        settings.excludedCwdSubstrings = ["node_modules", "vendor"]
        settings.quietHoursStartMinutes = 23 * 60 + 30 // 23:30 = 1410
        settings.quietHoursEndMinutes = 7 * 60 + 15   // 07:15 = 435

        let profiles = [
            Profile(id: "p1", name: "P1", configDir: "~/.c", pathPrefixes: ["~/p"])
        ]

        let state = SettingsState(profiles: profiles, settings: settings)
        #expect(state.draft.profiles == profiles)
        #expect(state.autoApproveText == "Bash, GlobTool")
        #expect(state.excludedText == "node_modules, vendor")
        #expect(state.quietStartText == "23:30")
        #expect(state.quietEndText == "07:15")
        #expect(state.newProfileName == "")
        #expect(state.newProfileDir == "")
    }
}
