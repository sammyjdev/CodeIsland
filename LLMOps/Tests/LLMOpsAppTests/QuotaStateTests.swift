import Foundation
import Testing
import LLMOpsCore
@testable import LLMOps

private struct StubProvider: QuotaProvider {
    let id: QuotaProviderID
    let result: Result<QuotaSnapshot, QuotaError>

    func fetch(now: Date) async throws -> QuotaSnapshot {
        switch result {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _count += 1
    }
}

private struct CountingStubProvider: QuotaProvider {
    let id: QuotaProviderID
    let counter: CounterBox

    func fetch(now: Date) async throws -> QuotaSnapshot {
        counter.increment()
        return QuotaSnapshot(provider: id, windows: [], fetchedAt: now, detail: nil)
    }
}

@Suite("QuotaStateTests")
@MainActor
struct QuotaStateTests {

    // 1. refresh with four stubs (three successes, one .network("boom")): results.count == 4,
    // the failing id holds the error, lastRefreshAt set, isRefreshing == false afterwards.
    @Test func refreshStoresResultsAndSetsLastRefreshAt() async throws {
        let now = Date()
        let s1 = QuotaSnapshot(provider: .claude, windows: [], fetchedAt: now, detail: nil)
        let s2 = QuotaSnapshot(provider: .codex, windows: [], fetchedAt: now, detail: nil)
        let s3 = QuotaSnapshot(provider: .antigravity, windows: [], fetchedAt: now, detail: nil)

        let providers: [any QuotaProvider] = [
            StubProvider(id: .claude, result: .success(s1)),
            StubProvider(id: .codex, result: .success(s2)),
            StubProvider(id: .antigravity, result: .success(s3)),
            StubProvider(id: .zai, result: .failure(.network("boom")))
        ]

        let state = QuotaState()
        await state.refresh(providers: providers, now: now)

        #expect(state.results.count == 4)
        #expect(state.results[.claude] == .success(s1))
        #expect(state.results[.codex] == .success(s2))
        #expect(state.results[.antigravity] == .success(s3))
        #expect(state.results[.zai] == .failure(.network("boom")))
        #expect(state.lastRefreshAt == now)
        #expect(state.isRefreshing == false)
    }

    // 2. sidebarPercent: a snapshot with windows [("7d", 40), ("5h", 53)] gives 53;
    // one without a "5h" window gives the max; an error gives nil; a missing id gives nil.
    @Test func sidebarPercentReturnsExpectedValues() {
        let state = QuotaState()
        let now = Date()

        let snapWith5h = QuotaSnapshot(
            provider: .claude,
            windows: [
                QuotaWindow(label: "7d", usedPercent: 40, resetsAt: nil),
                QuotaWindow(label: "5h", usedPercent: 53, resetsAt: nil)
            ],
            fetchedAt: now,
            detail: nil
        )

        let snapWithout5h = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(label: "7d", usedPercent: 40, resetsAt: nil),
                QuotaWindow(label: "30d", usedPercent: 82, resetsAt: nil)
            ],
            fetchedAt: now,
            detail: nil
        )

        state.results[.claude] = .success(snapWith5h)
        state.results[.codex] = .success(snapWithout5h)
        state.results[.antigravity] = .failure(.network("failed"))
        // .zai is missing

        #expect(state.sidebarPercent(for: .claude) == 53)
        #expect(state.sidebarPercent(for: .codex) == 82)
        #expect(state.sidebarPercent(for: .antigravity) == nil)
        #expect(state.sidebarPercent(for: .zai) == nil)
    }

    // 3. message(for:) for each of the five cases contains the payload string.
    @Test func errorMessageFormatting() {
        let payload = "sample-payload-123"
        let cases: [QuotaError] = [
            .missingCredential(payload),
            .network(payload),
            .badPayload(payload),
            .notFound(payload),
            .subprocess(payload)
        ]

        for error in cases {
            let msg = QuotaState.message(for: error)
            #expect(msg.contains(payload))
        }

        #expect(QuotaState.message(for: .missingCredential("key")) == "credential missing: key")
        #expect(QuotaState.message(for: .network("timeout")) == "network: timeout")
        #expect(QuotaState.message(for: .badPayload("corrupt")) == "unexpected payload: corrupt")
        #expect(QuotaState.message(for: .notFound("file")) == "not found: file")
        #expect(QuotaState.message(for: .subprocess("exit 1")) == "subprocess: exit 1")
    }

    // 4. start(providers:interval: 0.02) with stubs whose fetch increments a counter:
    // after 100 ms the counter is at least 3; after stop() it stops growing.
    @Test func startPeriodicallyRefreshesAndStopHalts() async throws {
        let counter = CounterBox()
        let provider = CountingStubProvider(id: .claude, counter: counter)
        let state = QuotaState()

        state.start(providers: [provider], interval: 0.02)
        for _ in 0..<20 {
            if counter.count >= 3 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(counter.count >= 3)
        state.stop()

        let countAtStop = counter.count
        try await Task.sleep(nanoseconds: 60_000_000) // 60 ms
        #expect(counter.count == countAtStop)
    }

    // 5. LLMOpsSettings.defaultAntigravityUsagePath(home:fileExists:): with fileExists true only for
    // <home>/.nvm/versions/node/v20.20.0/bin/antigravity-usage and
    // <home>/.nvm/versions/node/v18.0.0/bin/antigravity-usage returns the v20 one; with nothing
    // present returns /usr/local/bin/antigravity-usage.
    @Test func defaultAntigravityUsagePathResolution() throws {
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent("test-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        // When nothing is present
        let fallback = LLMOpsSettings.defaultAntigravityUsagePath(home: tempHome.path) { _ in false }
        #expect(fallback == "/usr/local/bin/antigravity-usage")

        // Build the node versions tree inside tempHome
        let v18Dir = tempHome.appendingPathComponent(".nvm/versions/node/v18.0.0/bin")
        let v20Dir = tempHome.appendingPathComponent(".nvm/versions/node/v20.20.0/bin")
        try FileManager.default.createDirectory(at: v18Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: v20Dir, withIntermediateDirectories: true)

        let v18Bin = v18Dir.appendingPathComponent("antigravity-usage").path
        let v20Bin = v20Dir.appendingPathComponent("antigravity-usage").path

        let resolved = LLMOpsSettings.defaultAntigravityUsagePath(home: tempHome.path) { path in
            path == v18Bin || path == v20Bin
        }
        #expect(resolved == v20Bin)
    }
}
