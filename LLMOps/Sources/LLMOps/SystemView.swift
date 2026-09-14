import SwiftUI
import Charts
import CodeIslandCore
import LLMOpsCore

@MainActor
final class SystemState: ObservableObject {
    enum SortBy: Equatable { case cpu, memory }
    @Published var latest: SystemSample?
    @Published var cpuHistory: [Double] = []      // last 30 cpuPercent values, oldest first
    @Published var memoryHistory: [Double] = []   // last 30 used / total ratios (0...1), oldest first
    @Published var sortBy: SortBy = .cpu
    static let historyLength = 30
    static let top = 10

    private(set) var previous: RawReading?
    private var timer: Timer?

    /// Takes one reading immediately, then every interval seconds until stop().
    /// Calling start while running is a no-op.
    func start(probe: any SystemProbe, interval: TimeInterval = 2, now: @escaping () -> Date = Date.init) {
        guard timer == nil else { return }
        tick(probe: probe, now: now())
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick(probe: probe, now: now())
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One tick: read, sample against previous, append to histories (dropping the oldest past historyLength).
    func tick(probe: any SystemProbe, now: Date) {
        let reading = probe.read(now: now)
        let sample = SystemSampler.sample(previous: previous, current: reading, top: Self.top)
        previous = reading
        latest = sample

        cpuHistory.append(sample.cpuPercent)
        if cpuHistory.count > Self.historyLength {
            cpuHistory.removeFirst(cpuHistory.count - Self.historyLength)
        }

        let memoryRatio = sample.memory.total > 0
            ? Double(sample.memory.used) / Double(sample.memory.total)
            : 0.0
        memoryHistory.append(memoryRatio)
        if memoryHistory.count > Self.historyLength {
            memoryHistory.removeFirst(memoryHistory.count - Self.historyLength)
        }
    }
}

struct SystemView: View {
    var model: AppModel
    @StateObject private var state = SystemState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "system")
                    Text("machine")
                        .font(Theme.Fonts.headline())
                        .foregroundStyle(Theme.Colors.text)
                }

                if let sample = state.latest {
                    HStack(alignment: .top, spacing: 16) {
                        cpuCard(sample: sample)
                        ramCard(sample: sample)
                    }

                    topProcessesCard(sample: sample)
                    batteryCard(sample: sample)
                } else {
                    Text("// sampling...")
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.Colors.textDim)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.Colors.bg)
        .onAppear {
            state.start(probe: MachProbe())
        }
        .onDisappear {
            state.stop()
        }
    }

    private func cpuCard(sample: SystemSample) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                MetricLine(
                    value: String(format: "%.0f%%", sample.cpuPercent),
                    label: "cpu, all cores",
                    accent: .cyan
                )

                Chart(Array(state.cpuHistory.enumerated()), id: \.offset) { index, value in
                    BarMark(
                        x: .value("index", index),
                        y: .value("cpu", value)
                    )
                    .foregroundStyle(Theme.Colors.cyan)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...100)
                .frame(height: 36)

                SourceLine(text: "host_processor_info, 2s")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ramCard(sample: SystemSample) -> some View {
        let memory = sample.memory
        return EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                MetricLine(
                    value: "\(HistoryFormat.bytes(memory.used)) / \(HistoryFormat.bytes(memory.total))",
                    label: "memory used",
                    accent: .magenta
                )

                Chart(Array(state.memoryHistory.enumerated()), id: \.offset) { index, value in
                    BarMark(
                        x: .value("index", index),
                        y: .value("memory", value)
                    )
                    .foregroundStyle(Theme.Colors.magenta)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...1)
                .frame(height: 36)

                Text("wired \(HistoryFormat.bytes(memory.wired)), compressed \(HistoryFormat.bytes(memory.compressed)), free \(HistoryFormat.bytes(memory.free))")
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(Theme.Colors.textDim)

                SourceLine(text: "host_statistics64, 2s")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func topProcessesCard(sample: SystemSample) -> some View {
        let processes = state.sortBy == .cpu ? sample.topByCPU : sample.topByMemory

        return EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "top processes")

                HStack(spacing: 6) {
                    Button {
                        state.sortBy = .cpu
                    } label: {
                        TagPill(text: "cpu", active: state.sortBy == .cpu)
                    }
                    .buttonStyle(.plain)

                    Button {
                        state.sortBy = .memory
                    } label: {
                        TagPill(text: "memory", active: state.sortBy == .memory)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("pid")
                            .frame(width: 56, alignment: .trailing)
                        Text("name")
                            .frame(width: 220, alignment: .leading)
                        Text("cpu")
                            .frame(width: 64, alignment: .trailing)
                        Text("rss")
                            .frame(width: 80, alignment: .trailing)
                    }
                    .foregroundStyle(Theme.Colors.textDim)

                    ForEach(processes) { process in
                        HStack(spacing: 8) {
                            Text("\(process.pid)")
                                .frame(width: 56, alignment: .trailing)
                            Text(process.name)
                                .frame(width: 220, alignment: .leading)
                                .lineLimit(1)
                            Text(String(format: "%.1f%%", process.cpuPercent))
                                .frame(width: 64, alignment: .trailing)
                            Text(HistoryFormat.bytes(process.rssBytes))
                                .frame(width: 80, alignment: .trailing)
                            if process.isAI {
                                TagPill(text: "ai", active: true)
                            }
                        }
                        .foregroundStyle(Theme.Colors.text)
                    }
                }
                .font(Theme.Fonts.mono(11))

                SourceLine(text: "libproc, top \(SystemState.top)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func batteryCard(sample: SystemSample) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "battery")

                if let b = sample.battery {
                    MetricLine(value: "\(b.percent)%", label: "charge", accent: .magenta)

                    let stateText: String = {
                        if b.isCharging {
                            return "charging"
                        } else if b.isPluggedIn {
                            return "plugged in"
                        } else {
                            var text = "on battery"
                            if let minutes = b.minutesRemaining {
                                let h = minutes / 60
                                let mm = minutes % 60
                                text += String(format: ", %dh %02dm left", h, mm)
                            }
                            return text
                        }
                    }()

                    Text(stateText)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.text)

                    let cycleText = b.cycleCount.map { "cycles \($0)" }
                    let healthText = b.healthPercent.map { "health \($0)%" }
                    let extra = [cycleText, healthText].compactMap { $0 }.joined(separator: ", ")
                    if !extra.isEmpty {
                        Text(extra)
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Colors.textDim)
                    }
                } else {
                    Text("// no battery")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textDim)
                }

                SourceLine(text: "IOKit power sources")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
