import Foundation
import Testing
import CodeIslandCore
import LLMOpsCore
@testable import LLMOps

@Suite("IslandModelTests")
struct IslandModelTests {

    // 1. build with 6 live sessions ordered by lastActivity gives 4 slots (most recent first)
    // and hiddenCount == 2; project is the last path component of cwd; elapsed is now - startTime (tolerance 0.001).
    @Test func buildWithSixSessionsOrdersAndCapsAtFour() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var sessions: [SessionSnapshot] = []
        for i in 1...6 {
            var s = SessionSnapshot(startTime: now.addingTimeInterval(-Double(i * 100)))
            s.cwd = "/Users/test/dev/project\(i)"
            s.lastActivity = now.addingTimeInterval(-Double(10 - i)) // i=6 is newest (-4s), i=1 is oldest (-9s)
            s.status = .running
            s.currentTool = "tool\(i)"
            s.providerSessionId = "s\(i)"
            sessions.append(s)
        }

        let model = IslandModel.build(
            live: sessions,
            pending: [],
            hoverExpanded: false,
            pinnedExpanded: false,
            now: now
        )

        #expect(model.slots.count == 4)
        #expect(model.hiddenCount == 2)

        // Most recent activity first: i=6, 5, 4, 3
        #expect(model.slots[0].project == "project6")
        #expect(model.slots[1].project == "project5")
        #expect(model.slots[2].project == "project4")
        #expect(model.slots[3].project == "project3")

        #expect(abs(model.slots[0].elapsed - 600) < 0.001)
        #expect(abs(model.slots[1].elapsed - 500) < 0.001)
    }

    // 2. expanded is true with one pending item and false with none when neither hover nor pin is set;
    // true with hoverExpanded; true with pinnedExpanded.
    @Test func expandedStateRules() {
        let now = Date()
        let p1 = PendingPermission(
            id: UUID(),
            sessionId: "s1",
            kind: .permission,
            toolName: "Bash",
            description: "rm -rf",
            options: nil,
            receivedAt: now
        )

        // 1 pending -> expanded is true
        let m1 = IslandModel.build(live: [], pending: [p1], hoverExpanded: false, pinnedExpanded: false, now: now)
        #expect(m1.expanded == true)

        // 0 pending, no hover, no pin -> expanded is false
        let m2 = IslandModel.build(live: [], pending: [], hoverExpanded: false, pinnedExpanded: false, now: now)
        #expect(m2.expanded == false)

        // 0 pending, hoverExpanded true -> expanded is true
        let m3 = IslandModel.build(live: [], pending: [], hoverExpanded: true, pinnedExpanded: false, now: now)
        #expect(m3.expanded == true)

        // 0 pending, pinnedExpanded true -> expanded is true
        let m4 = IslandModel.build(live: [], pending: [], hoverExpanded: false, pinnedExpanded: true, now: now)
        #expect(m4.expanded == true)
    }

    // 3. isVisible: .whileLive with slots and no pending -> true; .whileLive with nothing -> false;
    // .onlyPending with slots and no pending -> false; .onlyPending with pending -> true;
    // any model with presentation == .none or .front -> false.
    @Test func isVisibleRules() {
        let now = Date()
        let slot = IslandModel.Slot(sessionId: "s1", project: "p", status: .running, tool: nil, elapsed: 10)
        let p1 = PendingPermission(
            id: UUID(),
            sessionId: "s1",
            kind: .permission,
            toolName: "Bash",
            description: "ls",
            options: nil,
            receivedAt: now
        )

        let modelWithSlotsOnly = IslandModel(slots: [slot], hiddenCount: 0, pending: [], expanded: false)
        let modelWithNothing = IslandModel(slots: [], hiddenCount: 0, pending: [], expanded: false)
        let modelWithPendingOnly = IslandModel(slots: [], hiddenCount: 0, pending: [p1], expanded: true)
        let modelWithBoth = IslandModel(slots: [slot], hiddenCount: 0, pending: [p1], expanded: true)

        // .whileLive with slots and no pending -> true
        #expect(IslandModel.isVisible(modelWithSlotsOnly, presentation: .notch, visibility: .whileLive) == true)

        // .whileLive with nothing -> false
        #expect(IslandModel.isVisible(modelWithNothing, presentation: .notch, visibility: .whileLive) == false)

        // .onlyPending with slots and no pending -> false
        #expect(IslandModel.isVisible(modelWithSlotsOnly, presentation: .notch, visibility: .onlyPending) == false)

        // .onlyPending with pending -> true
        #expect(IslandModel.isVisible(modelWithPendingOnly, presentation: .notch, visibility: .onlyPending) == true)
        #expect(IslandModel.isVisible(modelWithBoth, presentation: .notch, visibility: .onlyPending) == true)

        // any model with presentation == .none or .front -> false
        for pres: LLMOpsSettings.RequestPresentation in [.none, .front] {
            for vis: IslandVisibility in [.whileLive, .onlyPending] {
                #expect(IslandModel.isVisible(modelWithSlotsOnly, presentation: pres, visibility: vis) == false)
                #expect(IslandModel.isVisible(modelWithNothing, presentation: pres, visibility: vis) == false)
                #expect(IslandModel.isVisible(modelWithPendingOnly, presentation: pres, visibility: vis) == false)
                #expect(IslandModel.isVisible(modelWithBoth, presentation: pres, visibility: vis) == false)
            }
        }
    }

    // 4. isAlert: .waitingApproval and .waitingQuestion true; .idle, .processing, .running false.
    @Test func isAlertStatusMapping() {
        #expect(IslandModel.isAlert(.waitingApproval) == true)
        #expect(IslandModel.isAlert(.waitingQuestion) == true)
        #expect(IslandModel.isAlert(.idle) == false)
        #expect(IslandModel.isAlert(.processing) == false)
        #expect(IslandModel.isAlert(.running) == false)
    }
}
