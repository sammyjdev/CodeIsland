import Foundation
import Testing
@testable import LLMOps

@Suite struct SoundAndSettingsTests {

    // 1. Fresh settings expose the documented defaults
    @Test @MainActor func freshSettingsExposeDocumentedDefaults() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = LLMOpsSettings(userDefaults: defaults)
        #expect(settings.soundEnabled == true)
        #expect(settings.soundBoot == true)
        #expect(settings.soundSessionStart == true)
        #expect(settings.soundTaskComplete == true)
        #expect(settings.soundTaskError == true)
        #expect(settings.soundApprovalNeeded == true)
        #expect(settings.soundPromptSubmit == false)
        #expect(settings.quietHoursEnabled == false)
        #expect(settings.quietHoursStartMinutes == 22 * 60)
        #expect(settings.quietHoursEndMinutes == 8 * 60)
        #expect(settings.autoApproveTools == [])
        #expect(settings.excludedCwdSubstrings == [])
    }

    // 2. Setting each property persists across instances
    @Test @MainActor func settingPropertiesPersistsAcrossInstances() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = LLMOpsSettings(userDefaults: defaults)
        settings.soundEnabled = false
        settings.soundBoot = false
        settings.soundSessionStart = false
        settings.soundTaskComplete = false
        settings.soundTaskError = false
        settings.soundApprovalNeeded = false
        settings.soundPromptSubmit = true
        settings.quietHoursEnabled = true
        settings.quietHoursStartMinutes = 23 * 60
        settings.quietHoursEndMinutes = 7 * 60
        settings.autoApproveTools = ["read_file", "write_to_file"]
        settings.excludedCwdSubstrings = ["/tmp", "/private"]

        let reloaded = LLMOpsSettings(userDefaults: defaults)
        #expect(reloaded.soundEnabled == false)
        #expect(reloaded.soundBoot == false)
        #expect(reloaded.soundSessionStart == false)
        #expect(reloaded.soundTaskComplete == false)
        #expect(reloaded.soundTaskError == false)
        #expect(reloaded.soundApprovalNeeded == false)
        #expect(reloaded.soundPromptSubmit == true)
        #expect(reloaded.quietHoursEnabled == true)
        #expect(reloaded.quietHoursStartMinutes == 23 * 60)
        #expect(reloaded.quietHoursEndMinutes == 7 * 60)
        #expect(reloaded.autoApproveTools == ["read_file", "write_to_file"])
        #expect(reloaded.excludedCwdSubstrings == ["/tmp", "/private"])
    }

    // 3. isInQuietHours calculation tests
    @Test func isInQuietHoursWindowCalculations() {
        // window 22:00-08:00
        let start22 = 22 * 60
        let end08 = 8 * 60
        #expect(LLMOpsSettings.isInQuietHours(minutesSinceMidnight: 23 * 60, start: start22, end: end08) == true)
        #expect(LLMOpsSettings.isInQuietHours(minutesSinceMidnight: 3 * 60, start: start22, end: end08) == true)
        #expect(LLMOpsSettings.isInQuietHours(minutesSinceMidnight: 8 * 60, start: start22, end: end08) == false)
        #expect(LLMOpsSettings.isInQuietHours(minutesSinceMidnight: 12 * 60, start: start22, end: end08) == false)
        #expect(LLMOpsSettings.isInQuietHours(minutesSinceMidnight: 21 * 60 + 59, start: start22, end: end08) == false)

        // window 09:00-17:00
        let start09 = 9 * 60
        let end17 = 17 * 60
        #expect(LLMOpsSettings.isInQuietHours(minutesSinceMidnight: 12 * 60, start: start09, end: end17) == true)
        #expect(LLMOpsSettings.isInQuietHours(minutesSinceMidnight: 17 * 60, start: start09, end: end17) == false)

        // start == end -> always false
        #expect(LLMOpsSettings.isInQuietHours(minutesSinceMidnight: 0, start: 600, end: 600) == false)
        #expect(LLMOpsSettings.isInQuietHours(minutesSinceMidnight: 600, start: 600, end: 600) == false)
        #expect(LLMOpsSettings.isInQuietHours(minutesSinceMidnight: 1439, start: 600, end: 600) == false)
    }

    // 4. All six wav resources resolve through Bundle.module
    @Test func allSixWavResourcesResolveThroughBundle() throws {
        let wavs = [
            "8bit_approval",
            "8bit_boot",
            "8bit_complete",
            "8bit_error",
            "8bit_start",
            "8bit_submit",
        ]
        for name in wavs {
            let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Resources/Sounds")
            let resolvedURL = try #require(url, "Expected \(name).wav to resolve in bundle")
            let attributes = try FileManager.default.attributesOfItem(atPath: resolvedURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            #expect(fileSize > 0, "\(name).wav size should be > 0")
        }
    }

    // 5. SoundManager with audioEnabled = false dispatches events properly
    @Test @MainActor func soundManagerAudioDisabledDispatchesEvents() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = LLMOpsSettings(userDefaults: defaults)
        let manager = SoundManager(settings: settings)
        manager.audioEnabled = false

        // handleEvent("PermissionRequest") sets lastPlayed == "8bit_approval"
        manager.handleEvent("PermissionRequest")
        #expect(manager.lastPlayed == "8bit_approval")

        // with soundApprovalNeeded = false it stays nil
        settings.soundApprovalNeeded = false
        let manager2 = SoundManager(settings: settings)
        manager2.audioEnabled = false
        manager2.handleEvent("PermissionRequest")
        #expect(manager2.lastPlayed == nil)

        // with soundEnabled = false nothing plays for any event
        settings.soundApprovalNeeded = true
        settings.soundEnabled = false
        let manager3 = SoundManager(settings: settings)
        manager3.audioEnabled = false
        for event in ["SessionStart", "TaskRoundComplete", "Stop", "PostToolUseFailure", "PermissionRequest", "UserPromptSubmit"] {
            manager3.handleEvent(event)
            #expect(manager3.lastPlayed == nil)
        }

        // unknown event name plays nothing
        settings.soundEnabled = true
        let manager4 = SoundManager(settings: settings)
        manager4.audioEnabled = false
        manager4.handleEvent("UnknownEvent")
        #expect(manager4.lastPlayed == nil)

        // playBoot plays 8bit_boot when enabled and nothing when soundBoot is false
        let bootManager = SoundManager(settings: settings)
        bootManager.audioEnabled = false
        bootManager.playBoot()
        #expect(bootManager.lastPlayed == "8bit_boot")

        settings.soundBoot = false
        let bootManagerDisabled = SoundManager(settings: settings)
        bootManagerDisabled.audioEnabled = false
        bootManagerDisabled.playBoot()
        #expect(bootManagerDisabled.lastPlayed == nil)
    }

    // 6. Quiet hours gate event sounds but not preview
    @Test @MainActor func quietHoursGateEventSoundsButNotPreview() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = LLMOpsSettings(userDefaults: defaults)
        settings.quietHoursEnabled = true
        settings.quietHoursStartMinutes = 0
        settings.quietHoursEndMinutes = 1439 // 00:00-23:59

        // Injected time inside quiet hours (12:00)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let components = DateComponents(year: 2026, month: 9, day: 13, hour: 12, minute: 0, second: 0)
        let injectedDate = try #require(calendar.date(from: components))

        let manager = SoundManager(
            settings: settings,
            audioEnabled: false,
            nowProvider: { injectedDate }
        )

        // handleEvent("SessionStart") plays nothing
        manager.handleEvent("SessionStart")
        #expect(manager.lastPlayed == nil)

        // preview("8bit_start") still sets lastPlayed
        manager.preview("8bit_start")
        #expect(manager.lastPlayed == "8bit_start")
    }

    // Required F6.4: endedRetentionSeconds defaults to 60, clamps to 0...600, persists
    @Test @MainActor func endedRetentionSecondsDefaultsAndClamps() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = LLMOpsSettings(userDefaults: defaults)
        #expect(settings.endedRetentionSeconds == 60)

        settings.endedRetentionSeconds = 1000
        #expect(settings.endedRetentionSeconds == 600)

        let reloaded1 = LLMOpsSettings(userDefaults: defaults)
        #expect(reloaded1.endedRetentionSeconds == 600)

        settings.endedRetentionSeconds = -5
        #expect(settings.endedRetentionSeconds == 0)

        let reloaded2 = LLMOpsSettings(userDefaults: defaults)
        #expect(reloaded2.endedRetentionSeconds == 0)
    }

    // Required F7.2: newSettingsDefaultsAndClamps
    @Test @MainActor func newSettingsDefaultsAndClamps() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = LLMOpsSettings(userDefaults: defaults)
        #expect(settings.hideIdleAfterSeconds == 300)
        #expect(settings.soundVolume == 60)
        #expect(settings.bringToFrontOnRequest == true)

        // Clamping hideIdleAfterSeconds
        settings.hideIdleAfterSeconds = -1
        #expect(settings.hideIdleAfterSeconds == 0)

        settings.hideIdleAfterSeconds = 99999
        #expect(settings.hideIdleAfterSeconds == 86400)

        // Clamping soundVolume
        settings.soundVolume = 150
        #expect(settings.soundVolume == 100)

        settings.soundVolume = -3
        #expect(settings.soundVolume == 0)

        // Persist across instances
        settings.hideIdleAfterSeconds = 600
        settings.soundVolume = 75
        settings.bringToFrontOnRequest = false

        let reloaded = LLMOpsSettings(userDefaults: defaults)
        #expect(reloaded.hideIdleAfterSeconds == 600)
        #expect(reloaded.soundVolume == 75)
        #expect(reloaded.bringToFrontOnRequest == false)
    }

    // Required F7.2: soundManagerAppliesVolume
    @Test @MainActor func soundManagerAppliesVolume() throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = LLMOpsSettings(userDefaults: defaults)
        settings.soundVolume = 25

        let manager = SoundManager(settings: settings)
        manager.audioEnabled = false

        manager.handleEvent("SessionStart")
        #expect(manager.lastVolume == 0.25)
    }
}
