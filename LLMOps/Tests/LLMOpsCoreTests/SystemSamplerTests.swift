import Foundation
import Testing
@testable import LLMOpsCore

@Suite("SystemSamplerTests")
struct SystemSamplerTests {
    private let dummyMemory = MemorySample(total: 16_000_000_000, used: 8_000_000_000, wired: 2_000_000_000, compressed: 1_000_000_000, free: 5_000_000_000)
    private let dummyBattery = BatterySample(percent: 85, isCharging: false, isPluggedIn: true, minutesRemaining: nil, cycleCount: 120, healthPercent: 98)

    // 1. cpu percent: previous ticks (user 100, system 50, idle 850, nice 0), current (user 150, system 100, idle 950, nice 0): busy delta 100, total delta 200, expect cpuPercent == 50.0 (tolerance 0.001).
    @Test func cpuPercentCalculatedFromTickDeltas() {
        let prevTicks = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let currTicks = CPUTicks(user: 150, system: 100, idle: 950, nice: 0)
        let t0 = Date()
        let prev = RawReading(at: t0, cpuTicks: prevTicks, memory: dummyMemory, processes: [], battery: nil)
        let curr = RawReading(at: t0.addingTimeInterval(1), cpuTicks: currTicks, memory: dummyMemory, processes: [], battery: nil)

        let sample = SystemSampler.sample(previous: prev, current: curr, top: 5)
        #expect(abs(sample.cpuPercent - 50.0) < 0.001)
    }

    // 2. cpu percent with previous == nil is 0; with identical ticks is 0.
    @Test func cpuPercentZeroWhenPreviousNilOrIdenticalTicks() {
        let ticks = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let t0 = Date()
        let reading1 = RawReading(at: t0, cpuTicks: ticks, memory: dummyMemory, processes: [], battery: nil)
        let reading2 = RawReading(at: t0.addingTimeInterval(1), cpuTicks: ticks, memory: dummyMemory, processes: [], battery: nil)

        let sampleNil = SystemSampler.sample(previous: nil, current: reading1, top: 5)
        #expect(sampleNil.cpuPercent == 0.0)

        let sampleIdentical = SystemSampler.sample(previous: reading1, current: reading2, top: 5)
        #expect(sampleIdentical.cpuPercent == 0.0)
    }

    // 3. per process: previous at t0 has pid 7 cpuTimeNs 1_000_000_000; current at t0 + 2 s has pid 7 cpuTimeNs 1_500_000_000: expect 25.0. A pid only in current gets 0.
    @Test func perProcessCpuPercentCalculatedFromTimeDeltas() {
        let t0 = Date()
        let t1 = t0.addingTimeInterval(2.0)
        let prevTicks = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let currTicks = CPUTicks(user: 200, system: 100, idle: 850, nice: 0)

        let prev = RawReading(
            at: t0,
            cpuTicks: prevTicks,
            memory: dummyMemory,
            processes: [
                RawProcess(pid: 7, name: "proc7", cpuTimeNs: 1_000_000_000, rssBytes: 1024)
            ],
            battery: nil
        )
        let curr = RawReading(
            at: t1,
            cpuTicks: currTicks,
            memory: dummyMemory,
            processes: [
                RawProcess(pid: 7, name: "proc7", cpuTimeNs: 1_500_000_000, rssBytes: 1024),
                RawProcess(pid: 8, name: "proc8", cpuTimeNs: 500_000_000, rssBytes: 2048)
            ],
            battery: nil
        )

        let sample = SystemSampler.sample(previous: prev, current: curr, top: 5)
        let proc7 = sample.topByCPU.first { $0.pid == 7 }
        let proc8 = sample.topByCPU.first { $0.pid == 8 }

        #expect(proc7 != nil)
        if let proc7 {
            #expect(abs(proc7.cpuPercent - 25.0) < 0.001)
        }
        #expect(proc8 != nil)
        if let proc8 {
            #expect(proc8.cpuPercent == 0.0)
        }
    }

    // 4. top ordering: five processes with cpu 5, 9, 9, 1, 3 and top: 3 gives the two 9s (lower pid first) then 5. topByMemory sorts by rss desc, ties by pid asc.
    @Test func topOrderingByCpuAndMemoryWithTies() {
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1.0)
        let prevTicks = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let currTicks = CPUTicks(user: 200, system: 100, idle: 850, nice: 0)

        let prev = RawReading(
            at: t0,
            cpuTicks: prevTicks,
            memory: dummyMemory,
            processes: [
                RawProcess(pid: 1, name: "p1", cpuTimeNs: 0, rssBytes: 500),
                RawProcess(pid: 2, name: "p2", cpuTimeNs: 0, rssBytes: 100),
                RawProcess(pid: 3, name: "p3", cpuTimeNs: 0, rssBytes: 300),
                RawProcess(pid: 4, name: "p4", cpuTimeNs: 0, rssBytes: 900),
                RawProcess(pid: 5, name: "p5", cpuTimeNs: 0, rssBytes: 900),
            ],
            battery: nil
        )
        let curr = RawReading(
            at: t1,
            cpuTicks: currTicks,
            memory: dummyMemory,
            processes: [
                RawProcess(pid: 1, name: "p1", cpuTimeNs: 50_000_000, rssBytes: 500),
                RawProcess(pid: 2, name: "p2", cpuTimeNs: 90_000_000, rssBytes: 100),
                RawProcess(pid: 3, name: "p3", cpuTimeNs: 90_000_000, rssBytes: 300),
                RawProcess(pid: 4, name: "p4", cpuTimeNs: 10_000_000, rssBytes: 900),
                RawProcess(pid: 5, name: "p5", cpuTimeNs: 30_000_000, rssBytes: 900),
            ],
            battery: nil
        )

        let sample = SystemSampler.sample(previous: prev, current: curr, top: 3)
        #expect(sample.topByCPU.map(\.pid) == [2, 3, 1])
        #expect(sample.topByMemory.map(\.pid) == [4, 5, 1])
    }

    // 5. top: 0 gives empty lists; sample passes memory and battery through unchanged.
    @Test func topZeroGivesEmptyListsAndPassesMemoryAndBattery() {
        let t0 = Date()
        let ticks = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let curr = RawReading(
            at: t0,
            cpuTicks: ticks,
            memory: dummyMemory,
            processes: [RawProcess(pid: 1, name: "p1", cpuTimeNs: 100, rssBytes: 200)],
            battery: dummyBattery
        )

        let sample = SystemSampler.sample(previous: nil, current: curr, top: 0)
        #expect(sample.topByCPU.isEmpty)
        #expect(sample.topByMemory.isEmpty)
        #expect(sample.memory == dummyMemory)
        #expect(sample.battery == dummyBattery)
        #expect(sample.at == t0)
    }

    // 6. isAIProcess: "claude" true, "Claude Helper" true, "codex" true, "agy" true, "ccm" true, "LLMOps" true, "codeisland-bridge" true, "node" false, "Safari" false, "" false.
    @Test func isAIProcessMatching() {
        #expect(SystemSampler.isAIProcess(name: "claude") == true)
        #expect(SystemSampler.isAIProcess(name: "Claude Helper") == true)
        #expect(SystemSampler.isAIProcess(name: "codex") == true)
        #expect(SystemSampler.isAIProcess(name: "agy") == true)
        #expect(SystemSampler.isAIProcess(name: "ccm") == true)
        #expect(SystemSampler.isAIProcess(name: "LLMOps") == true)
        #expect(SystemSampler.isAIProcess(name: "codeisland-bridge") == true)
        #expect(SystemSampler.isAIProcess(name: "node") == false)
        #expect(SystemSampler.isAIProcess(name: "Safari") == false)
        #expect(SystemSampler.isAIProcess(name: "") == false)
    }

    // 7. MachProbe().read(now:) on this machine: cpuTicks.total > 0, memory.total > 0, memory.used <= memory.total, processes.count > 10, and processes contains a pid equal to ProcessInfo.processInfo.processIdentifier with rssBytes > 0 (the test process itself).
    @Test func machProbeLiveRead() {
        let probe = MachProbe()
        let now = Date()
        let reading = probe.read(now: now)

        #expect(reading.at == now)
        #expect(reading.cpuTicks.total > 0)
        #expect(reading.memory.total > 0)
        #expect(reading.memory.used <= reading.memory.total)
        #expect(reading.processes.count > 10)

        let selfPid = ProcessInfo.processInfo.processIdentifier
        let selfProc = reading.processes.first { $0.pid == selfPid }
        #expect(selfProc != nil)
        if let selfProc {
            #expect(selfProc.rssBytes > 0)
        }
    }

    // 8. Two MachProbe reads 200 ms apart: sample(previous:current:top: 5).cpuPercent is within 0...100.
    @Test func machProbeTwoReadsCpuPercentInRange() {
        let probe = MachProbe()
        let r1 = probe.read(now: Date())
        Thread.sleep(forTimeInterval: 0.2)
        let r2 = probe.read(now: Date())

        let sample = SystemSampler.sample(previous: r1, current: r2, top: 5)
        #expect(sample.cpuPercent >= 0.0 && sample.cpuPercent <= 100.0)
    }
}
