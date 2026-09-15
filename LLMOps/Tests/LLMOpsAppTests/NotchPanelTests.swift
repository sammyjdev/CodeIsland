import AppKit
import Foundation
import Testing
import CodeIslandCore
import LLMOpsCore
@testable import LLMOps

@Suite("NotchPanelTests")
@MainActor
struct NotchPanelTests {
    // 1. frame(height:screen:) on NSScreen.main!
    @Test func framePositioningOnScreen() throws {
        let screen = try #require(NSScreen.main)
        let height: CGFloat = 120
        let frame = NotchPanelController.frame(height: height, screen: screen)
        let topInset = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : (screen.frame.maxY - screen.visibleFrame.maxY)
        #expect(abs(frame.origin.x - (screen.frame.midX - 210)) < 0.5)
        #expect(abs(frame.maxY - (screen.frame.maxY - topInset)) < 0.5)
        #expect(frame.height == height)
        #expect(frame.width == NotchPanelController.width)
    }

    // 2. Visibility follows pending items and resolves
    @Test func visibilityFollowsPendingItems() async throws {
        let suite = "NotchPanelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        defer { model.stopPeriodicRescan() }

        let controller = NotchPanelController(model: model)
        controller.start()
        #expect(controller.isShowing == false)

        let reqJSON = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash"}"#.utf8)
        let event = try #require(HookEvent(from: reqJSON))
        final class Box: @unchecked Sendable { var value = false }
        let replied = Box()
        model.live.permissionRequested(event: event, cwd: nil) { _ in
            replied.value = true
        }

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(controller.isShowing == true)

        let pendingItem = try #require(model.live.pending.first)
        model.live.resolve(id: pendingItem.id, decision: .allow)

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(controller.isShowing == false)
        #expect(replied.value == true)
    }

    // 3. With settings.requestPresentation = .none, panel stays hidden
    @Test func panelStaysHiddenWhenPresentationIsNone() async throws {
        let suite = "NotchPanelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        defer { model.stopPeriodicRescan() }
        model.settings.requestPresentation = .none

        let controller = NotchPanelController(model: model)
        controller.start()
        #expect(controller.isShowing == false)

        let reqJSON = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash"}"#.utf8)
        let event = try #require(HookEvent(from: reqJSON))

        model.live.permissionRequested(event: event, cwd: nil) { _ in }

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(controller.isShowing == false)
    }

    // 4. Panel styleMask and level
    @Test func panelStyleMaskAndLevel() throws {
        let suite = "NotchPanelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        defer { model.stopPeriodicRescan() }

        let controller = NotchPanelController(model: model)
        controller.start()

        let panel = try #require(controller.panel)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level.rawValue == Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
    }

    // 5. With islandVisibility = .whileLive and one live session, panel is visible;
    // after SessionEnd and retention purge it hides.
    @Test func visibilityWhileLiveShowsWithSessionAndHidesAfterPurge() async throws {
        let suite = "NotchPanelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        defer { model.stopPeriodicRescan() }
        model.settings.islandVisibility = .whileLive

        let controller = NotchPanelController(model: model)
        controller.start()
        #expect(controller.isShowing == false)

        model.live.endedRetention = 0

        let startJSON = Data(#"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/tmp/testProj"}"#.utf8)
        let startEvent = try #require(HookEvent(from: startJSON))
        model.live.handle(event: startEvent, cwd: "/tmp/testProj")

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(controller.isShowing == true)

        let endJSON = Data(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#.utf8)
        let endEvent = try #require(HookEvent(from: endJSON))
        model.live.handle(event: endEvent, cwd: nil)

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(controller.isShowing == false)
    }

    // 6. With islandVisibility = .onlyPending, a live session alone keeps panel hidden;
    // a pending permission shows it.
    @Test func visibilityOnlyPendingKeepsLiveSessionHiddenUntilPending() async throws {
        let suite = "NotchPanelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        defer { model.stopPeriodicRescan() }
        model.settings.islandVisibility = .onlyPending

        let controller = NotchPanelController(model: model)
        controller.start()
        #expect(controller.isShowing == false)

        let startJSON = Data(#"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/tmp/testProj"}"#.utf8)
        let startEvent = try #require(HookEvent(from: startJSON))
        model.live.handle(event: startEvent, cwd: "/tmp/testProj")

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(controller.isShowing == false)

        let reqJSON = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash"}"#.utf8)
        let reqEvent = try #require(HookEvent(from: reqJSON))
        model.live.permissionRequested(event: reqEvent, cwd: nil) { _ in }

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(controller.isShowing == true)
    }
}
