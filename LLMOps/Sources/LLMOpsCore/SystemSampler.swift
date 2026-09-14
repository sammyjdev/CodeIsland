import Foundation
import Darwin
import IOKit.ps

public struct MemorySample: Equatable, Sendable {
    public let total: UInt64      // bytes, ProcessInfo.processInfo.physicalMemory
    public let used: UInt64       // (active + wired + compressed) pages * pageSize
    public let wired: UInt64
    public let compressed: UInt64
    public let free: UInt64       // free pages * pageSize

    public init(total: UInt64, used: UInt64, wired: UInt64, compressed: UInt64, free: UInt64) {
        self.total = total
        self.used = used
        self.wired = wired
        self.compressed = compressed
        self.free = free
    }
}

public struct ProcessSample: Identifiable, Equatable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let cpuPercent: Double
    public let rssBytes: UInt64
    public let isAI: Bool

    public init(pid: Int32, name: String, cpuPercent: Double, rssBytes: UInt64, isAI: Bool) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.rssBytes = rssBytes
        self.isAI = isAI
    }
}

public struct BatterySample: Equatable, Sendable {
    public let percent: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let minutesRemaining: Int?   // nil when unknown or when charging
    public let cycleCount: Int?
    public let healthPercent: Int?      // max capacity / design capacity when both are known

    public init(percent: Int, isCharging: Bool, isPluggedIn: Bool, minutesRemaining: Int?, cycleCount: Int?, healthPercent: Int?) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.minutesRemaining = minutesRemaining
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
    }
}

public struct CPUTicks: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var total: UInt64 { user + system + idle + nice }
}

public struct RawProcess: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let cpuTimeNs: UInt64     // user + system time consumed so far, nanoseconds
    public let rssBytes: UInt64

    public init(pid: Int32, name: String, cpuTimeNs: UInt64, rssBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuTimeNs = cpuTimeNs
        self.rssBytes = rssBytes
    }
}

public struct RawReading: Equatable, Sendable {
    public let at: Date
    public let cpuTicks: CPUTicks          // summed over all cores
    public let memory: MemorySample
    public let processes: [RawProcess]
    public let battery: BatterySample?

    public init(at: Date, cpuTicks: CPUTicks, memory: MemorySample, processes: [RawProcess], battery: BatterySample?) {
        self.at = at
        self.cpuTicks = cpuTicks
        self.memory = memory
        self.processes = processes
        self.battery = battery
    }
}

public struct SystemSample: Equatable, Sendable {
    public let at: Date
    public let cpuPercent: Double          // 0...100
    public let memory: MemorySample
    public let topByCPU: [ProcessSample]
    public let topByMemory: [ProcessSample]
    public let battery: BatterySample?

    public init(at: Date, cpuPercent: Double, memory: MemorySample, topByCPU: [ProcessSample], topByMemory: [ProcessSample], battery: BatterySample?) {
        self.at = at
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.topByCPU = topByCPU
        self.topByMemory = topByMemory
        self.battery = battery
    }
}

public protocol SystemProbe: Sendable {
    func read(now: Date) -> RawReading
}

/// Real readings. cpuTicks: host_processor_info(PROCESSOR_CPU_LOAD_INFO) summed over cores
/// (remember vm_deallocate the returned array). memory: host_statistics64(HOST_VM_INFO64) with
/// vm_kernel_page_size. processes: proc_listallpids, then per pid proc_pidinfo(PROC_PIDTASKINFO)
/// for pti_total_user + pti_total_system (already nanoseconds on Apple silicon; convert with
/// mach_timebase_info to be safe) and pti_resident_size, and proc_name for the name; skip pids
/// where proc_pidinfo fails (permission). battery: IOPSCopyPowerSourcesInfo / IOPSCopyPowerSourcesList /
/// IOPSGetPowerSourceDescription (IOKit.ps): kIOPSCurrentCapacityKey, kIOPSIsChargingKey,
/// kIOPSPowerSourceStateKey == kIOPSACPowerValue for isPluggedIn, kIOPSTimeToEmptyKey (-1 = unknown),
/// nil when the list is empty. cycleCount and healthPercent may be nil in v1 (IOKit registry
/// lookup is optional; if you read AppleSmartBattery via IOServiceGetMatchingService, use
/// "CycleCount", "AppleRawMaxCapacity" and "DesignCapacity").
public struct MachProbe: SystemProbe {
    public init() {}

    public func read(now: Date) -> RawReading {
        // CPU Ticks
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0

        let host = mach_host_self()
        let cpuKr = host_processor_info(
            host,
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCpuInfo
        )

        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0

        if cpuKr == KERN_SUCCESS, let cpuInfo {
            for i in 0..<Int(numCPUs) {
                let base = i * Int(CPU_STATE_MAX)
                user += UInt64(max(0, cpuInfo[base + Int(CPU_STATE_USER)]))
                system += UInt64(max(0, cpuInfo[base + Int(CPU_STATE_SYSTEM)]))
                idle += UInt64(max(0, cpuInfo[base + Int(CPU_STATE_IDLE)]))
                nice += UInt64(max(0, cpuInfo[base + Int(CPU_STATE_NICE)]))
            }
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), size)
        }
        let cpuTicks = CPUTicks(user: user, system: system, idle: idle, nice: nice)

        // Memory
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let memKr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let wiredMemory: UInt64
        let compressedMemory: UInt64
        let freeMemory: UInt64
        let usedMemory: UInt64
        if memKr == KERN_SUCCESS {
            wiredMemory = UInt64(vmStats.wire_count) * pageSize
            compressedMemory = UInt64(vmStats.compressor_page_count) * pageSize
            freeMemory = UInt64(vmStats.free_count) * pageSize
            usedMemory = (UInt64(vmStats.active_count) + UInt64(vmStats.wire_count) + UInt64(vmStats.compressor_page_count)) * pageSize
        } else {
            wiredMemory = 0
            compressedMemory = 0
            freeMemory = 0
            usedMemory = 0
        }
        let memory = MemorySample(
            total: totalMemory,
            used: usedMemory,
            wired: wiredMemory,
            compressed: compressedMemory,
            free: freeMemory
        )

        // Processes
        var tbInfo = mach_timebase_info()
        if mach_timebase_info(&tbInfo) != KERN_SUCCESS || tbInfo.denom == 0 {
            tbInfo = mach_timebase_info(numer: 1, denom: 1)
        }

        let estimatedPids = proc_listallpids(nil, 0)
        let capacity = max(1024, Int(estimatedPids) * 2)
        var pids = [pid_t](repeating: 0, count: capacity)
        let actualCount = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))

        var processes: [RawProcess] = []
        if actualCount > 0 {
            processes.reserveCapacity(min(actualCount, pids.count))
            var taskInfo = proc_taskinfo()
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            var nameBuf = [CChar](repeating: 0, count: 256)

            for i in 0..<min(actualCount, pids.count) {
                let pid = pids[i]
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize) == taskInfoSize else {
                    continue
                }

                let nameLen = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
                let name = nameLen > 0 ? String(cString: nameBuf) : ""

                let rawTicks = taskInfo.pti_total_user + taskInfo.pti_total_system
                let cpuTimeNs: UInt64
                let (prod, overflow) = rawTicks.multipliedReportingOverflow(by: UInt64(tbInfo.numer))
                if overflow {
                    cpuTimeNs = (rawTicks / UInt64(tbInfo.denom)) * UInt64(tbInfo.numer)
                } else {
                    cpuTimeNs = prod / UInt64(tbInfo.denom)
                }

                processes.append(RawProcess(
                    pid: pid,
                    name: name,
                    cpuTimeNs: cpuTimeNs,
                    rssBytes: taskInfo.pti_resident_size
                ))
            }
        }

        // mach_host_self returns a send right each call; release it or the port count grows every tick.
        mach_port_deallocate(mach_task_self_, host)

        // Battery
        var battery: BatterySample? = nil
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
           !sources.isEmpty {
            for source in sources {
                if let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] {
                    let percent = (desc[kIOPSCurrentCapacityKey] as? Int) ?? 0
                    let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? ((desc[kIOPSIsChargingKey] as? Int) == 1)
                    let isPluggedIn = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                    let minutesRemaining: Int? = {
                        if isCharging || isPluggedIn {
                            return nil
                        }
                        guard let t = desc[kIOPSTimeToEmptyKey] as? Int, t >= 0 else {
                            return nil
                        }
                        return t
                    }()
                    battery = BatterySample(
                        percent: percent,
                        isCharging: isCharging,
                        isPluggedIn: isPluggedIn,
                        minutesRemaining: minutesRemaining,
                        cycleCount: nil,
                        healthPercent: nil
                    )
                    break
                }
            }
        }

        return RawReading(
            at: now,
            cpuTicks: cpuTicks,
            memory: memory,
            processes: processes,
            battery: battery
        )
    }
}

public enum SystemSampler {
    public static let aiNamePrefixes: [String] = ["claude", "codex", "agy", "ccm", "llmops", "codeisland-bridge"]

    /// name lowercased has one of aiNamePrefixes as prefix.
    public static func isAIProcess(name: String) -> Bool {
        let lower = name.lowercased()
        guard !lower.isEmpty else { return false }
        return aiNamePrefixes.contains { lower.hasPrefix($0) }
    }

    /// Pure. cpuPercent = 100 * (busy delta) / (total delta) where busy = user + system + nice;
    /// 0 when previous is nil or total delta is 0. Per process cpuPercent =
    /// 100 * (cpuTimeNs delta) / (wall delta ns); 0 when the pid is absent from previous or wall
    /// delta is 0; clamp to 0...(100 * cores) is NOT required, just never negative.
    /// topByCPU: first `top` by cpuPercent desc, ties by pid asc. topByMemory: by rssBytes desc, ties by pid asc.
    public static func sample(previous: RawReading?, current: RawReading, top: Int) -> SystemSample {
        let cpuPercent: Double
        if let previous {
            let userDelta = current.cpuTicks.user >= previous.cpuTicks.user ? current.cpuTicks.user - previous.cpuTicks.user : 0
            let systemDelta = current.cpuTicks.system >= previous.cpuTicks.system ? current.cpuTicks.system - previous.cpuTicks.system : 0
            let niceDelta = current.cpuTicks.nice >= previous.cpuTicks.nice ? current.cpuTicks.nice - previous.cpuTicks.nice : 0
            let busyDelta = userDelta + systemDelta + niceDelta

            let totalDelta = current.cpuTicks.total >= previous.cpuTicks.total ? current.cpuTicks.total - previous.cpuTicks.total : 0
            if totalDelta > 0 {
                cpuPercent = 100.0 * Double(busyDelta) / Double(totalDelta)
            } else {
                cpuPercent = 0.0
            }
        } else {
            cpuPercent = 0.0
        }

        guard top > 0 else {
            return SystemSample(
                at: current.at,
                cpuPercent: cpuPercent,
                memory: current.memory,
                topByCPU: [],
                topByMemory: [],
                battery: current.battery
            )
        }

        let wallDeltaSeconds = previous != nil ? current.at.timeIntervalSince(previous!.at) : 0.0
        let wallDeltaNs = wallDeltaSeconds * 1_000_000_000.0

        var previousByPid: [Int32: RawProcess] = [:]
        if let previous {
            for proc in previous.processes {
                previousByPid[proc.pid] = proc
            }
        }

        let processSamples: [ProcessSample] = current.processes.map { proc in
            let procCpuPercent: Double
            if wallDeltaNs > 0, let prev = previousByPid[proc.pid], proc.cpuTimeNs > prev.cpuTimeNs {
                let cpuDeltaNs = proc.cpuTimeNs - prev.cpuTimeNs
                procCpuPercent = max(0.0, 100.0 * Double(cpuDeltaNs) / wallDeltaNs)
            } else {
                procCpuPercent = 0.0
            }
            return ProcessSample(
                pid: proc.pid,
                name: proc.name,
                cpuPercent: procCpuPercent,
                rssBytes: proc.rssBytes,
                isAI: isAIProcess(name: proc.name)
            )
        }

        let sortedByCPU = processSamples.sorted { a, b in
            if a.cpuPercent != b.cpuPercent {
                return a.cpuPercent > b.cpuPercent
            }
            return a.pid < b.pid
        }
        let topByCPU = Array(sortedByCPU.prefix(top))

        let sortedByMemory = processSamples.sorted { a, b in
            if a.rssBytes != b.rssBytes {
                return a.rssBytes > b.rssBytes
            }
            return a.pid < b.pid
        }
        let topByMemory = Array(sortedByMemory.prefix(top))

        return SystemSample(
            at: current.at,
            cpuPercent: cpuPercent,
            memory: current.memory,
            topByCPU: topByCPU,
            topByMemory: topByMemory,
            battery: current.battery
        )
    }
}
