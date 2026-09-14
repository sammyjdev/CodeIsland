import Foundation
import Testing
import LLMOpsCore
@testable import LLMOps

private final class IndexBox: @unchecked Sendable {
    var index: Int = 0
}

private struct ScriptedProbe: SystemProbe {
    let readings: [RawReading]
    private let box = IndexBox()

    init(readings: [RawReading]) {
        self.readings = readings
    }

    func read(now: Date) -> RawReading {
        guard !readings.isEmpty else {
            fatalError("ScriptedProbe requires at least one reading")
        }
        let reading = readings[min(box.index, readings.count - 1)]
        box.index += 1
        return RawReading(
            at: now,
            cpuTicks: reading.cpuTicks,
            memory: reading.memory,
            processes: reading.processes,
            battery: reading.battery
        )
    }
}

@Suite("SystemStateTests")
@MainActor
struct SystemStateTests {
    // 1. tick twice with readings whose ticks give 50% cpu: latest?.cpuPercent == 50,
    // cpuHistory == [0, 50] (first tick has no previous), memoryHistory.count == 2,
    // previous is the second reading.
    @Test func tickTwiceComputesCpuAndHistories() {
        let dummyMemory = MemorySample(total: 1000, used: 400, wired: 100, compressed: 100, free: 500)
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1.0)
        let r1 = RawReading(at: t0, cpuTicks: CPUTicks(user: 100, system: 50, idle: 850, nice: 0), memory: dummyMemory, processes: [], battery: nil)
        let r2 = RawReading(at: t1, cpuTicks: CPUTicks(user: 150, system: 100, idle: 950, nice: 0), memory: dummyMemory, processes: [], battery: nil)
        let probe = ScriptedProbe(readings: [r1, r2])

        let state = SystemState()
        state.tick(probe: probe, now: t0)
        state.tick(probe: probe, now: t1)

        #expect(state.latest?.cpuPercent == 50)
        #expect(state.cpuHistory == [0, 50])
        #expect(state.memoryHistory.count == 2)
        #expect(state.previous?.cpuTicks == r2.cpuTicks)
        #expect(state.previous?.at == t1)
    }

    // 2. 40 ticks: cpuHistory.count == 30 and memoryHistory.count == 30, oldest dropped
    // (first element equals the value from tick 11).
    @Test func fortyTicksDropsOldestHistory() {
        let dummyMemory = MemorySample(total: 1000, used: 400, wired: 100, compressed: 100, free: 500)
        let t0 = Date()
        var readings: [RawReading] = []
        var user: UInt64 = 0
        var idle: UInt64 = 0
        for i in 1...40 {
            user += UInt64(i)
            idle += UInt64(100 - i)
            readings.append(RawReading(
                at: t0.addingTimeInterval(Double(i)),
                cpuTicks: CPUTicks(user: user, system: 0, idle: idle, nice: 0),
                memory: dummyMemory,
                processes: [],
                battery: nil
            ))
        }
        let probe = ScriptedProbe(readings: readings)
        let state = SystemState()

        var tick11Value: Double?
        for i in 1...40 {
            state.tick(probe: probe, now: t0.addingTimeInterval(Double(i)))
            if i == 11 {
                tick11Value = state.latest?.cpuPercent
            }
        }

        #expect(state.cpuHistory.count == 30)
        #expect(state.memoryHistory.count == 30)
        #expect(state.cpuHistory.first == tick11Value)
    }

    // 3. start(probe:interval: 0.01) then try await Task.sleep(for: .milliseconds(120)):
    // cpuHistory.count >= 3; then stop(), record the count, sleep 50 ms more, count unchanged.
    @Test func startAndStopPeriodicSampling() async throws {
        let dummyMemory = MemorySample(total: 1000, used: 400, wired: 100, compressed: 100, free: 500)
        let r1 = RawReading(at: Date(), cpuTicks: CPUTicks(user: 100, system: 50, idle: 850, nice: 0), memory: dummyMemory, processes: [], battery: nil)
        let r2 = RawReading(at: Date().addingTimeInterval(0.01), cpuTicks: CPUTicks(user: 150, system: 100, idle: 950, nice: 0), memory: dummyMemory, processes: [], battery: nil)
        let probe = ScriptedProbe(readings: [r1, r2])

        let state = SystemState()
        state.start(probe: probe, interval: 0.01)
        try await Task.sleep(for: .milliseconds(120))
        #expect(state.cpuHistory.count >= 3)

        state.stop()
        let countAfterStop = state.cpuHistory.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.cpuHistory.count == countAfterStop)
    }

    // 4. start twice does not create a second timer (after stop() no more updates, same check as 3).
    @Test func startTwiceDoesNotCreateDuplicateTimer() async throws {
        let dummyMemory = MemorySample(total: 1000, used: 400, wired: 100, compressed: 100, free: 500)
        let r1 = RawReading(at: Date(), cpuTicks: CPUTicks(user: 100, system: 50, idle: 850, nice: 0), memory: dummyMemory, processes: [], battery: nil)
        let r2 = RawReading(at: Date().addingTimeInterval(0.01), cpuTicks: CPUTicks(user: 150, system: 100, idle: 950, nice: 0), memory: dummyMemory, processes: [], battery: nil)
        let probe = ScriptedProbe(readings: [r1, r2])

        let state = SystemState()
        state.start(probe: probe, interval: 0.01)
        state.start(probe: probe, interval: 0.01)
        try await Task.sleep(for: .milliseconds(120))
        #expect(state.cpuHistory.count >= 3)

        state.stop()
        let countAfterStop = state.cpuHistory.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.cpuHistory.count == countAfterStop)
    }

    // 5. sortBy defaults to .cpu.
    @Test func sortByDefaultsToCpu() {
        let state = SystemState()
        #expect(state.sortBy == .cpu)
    }
}
