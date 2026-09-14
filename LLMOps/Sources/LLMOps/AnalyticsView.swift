import SwiftUI
import Charts
import CodeIslandCore
import LLMOpsCore

struct AnalyticsView: View {
    var model: AppModel
    @StateObject private var state = AnalyticsState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "analytics")
                    Text("usage")
                        .font(Theme.Fonts.headline())
                        .foregroundStyle(Theme.Colors.text)
                }

                FilterBar(model: model)

                if let snapshot = state.snapshot, snapshot.sessionCount > 0 {
                    let kind = AnalyticsViewModel.heroKind(selectedProfile: model.selectedProfile)
                    HStack(alignment: .top, spacing: 16) {
                        switch kind {
                        case .windowTokens:
                            windowTokensCard(snapshot: snapshot, isHero: true)
                            costCard(snapshot: snapshot, isHero: false)
                        case .weekCost:
                            costCard(snapshot: snapshot, isHero: true)
                            windowTokensCard(snapshot: snapshot, isHero: false)
                        }
                    }

                    dailyTokensCard(snapshot: snapshot)
                    shapeCard(snapshot: snapshot)
                    projectTokensCard(snapshot: snapshot)
                    modelTokensCard(snapshot: snapshot)
                    toolsCard(snapshot: snapshot)
                    hourCard(snapshot: snapshot)
                    cacheRatioCard(snapshot: snapshot)
                } else {
                    Text("// no sessions scanned yet")
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.Colors.textDim)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.Colors.bg)
        .onAppear {
            refresh()
        }
        .onChange(of: model.lastScanAt) { _, _ in
            refresh()
        }
        .onChange(of: model.selectedProfile) { _, _ in
            refresh()
        }
        .onChange(of: model.filter) { _, _ in
            refresh()
        }
    }

    private func refresh() {
        let days = model.filter.dayCount(now: Date(), earliest: model.profileSessions.map(\.startedAt).min())
        state.refresh(sessions: model.visibleSessions, profiles: scopedProfiles, days: days)
    }

    private var scopedProfiles: [Profile] {
        model.selectedProfile.map { id in model.profiles.filter { $0.id == id } } ?? model.profiles
    }

    private func cleanSourceLine(_ raw: String) -> String {
        if raw.hasPrefix("src: ") {
            return String(raw.dropFirst(5))
        }
        return raw
    }

    private func windowTokensCard(snapshot: AnalyticsSnapshot, isHero: Bool) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                MetricLine(
                    value: tokens(snapshot.window.last5h.outputTokens),
                    label: "output tokens, last 5h",
                    accent: isHero ? .cyan : .magenta
                )

                Chart(Array(snapshot.window.hourlyOutputTokens.enumerated()), id: \.offset) { index, tokens in
                    BarMark(
                        x: .value("hour", index),
                        y: .value("tokens", tokens)
                    )
                    .foregroundStyle(isHero ? Theme.Colors.cyan : Theme.Colors.magenta)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 36)

                SourceLine(text: "usage scanner, unfiltered")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func costCard(snapshot: AnalyticsSnapshot, isHero: Bool) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                if isHero {
                    MetricLine(
                        value: usd(snapshot.weekCostUSD),
                        label: "estimated cost, this ISO week",
                        accent: .cyan
                    )

                    Text("today: \(usd(snapshot.todayCostUSD)) (estimate, price table)")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textDim)
                } else {
                    MetricLine(
                        value: usd(snapshot.todayCostUSD),
                        label: "estimated cost today",
                        accent: .magenta
                    )

                    Text("week: \(usd(snapshot.weekCostUSD)) (estimate, price table)")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textDim)
                }

                Spacer(minLength: 0)

                SourceLine(text: cleanSourceLine(snapshot.sourceLine))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dailyTokensCard(snapshot: AnalyticsSnapshot) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "tokens per day (\(snapshot.days)d)")

                Chart(AnalyticsViewModel.dailySeries(snapshot.perDay)) { point in
                    BarMark(
                        x: .value("day", point.day, unit: .day),
                        y: .value("tokens", point.tokens)
                    )
                    .foregroundStyle(by: .value("kind", point.kind))
                }
                .chartForegroundStyleScale([
                    "input": Theme.Colors.magenta,
                    "output": Theme.Colors.magentaBright,
                    "cache read": Theme.Colors.textDim,
                    "cache write": Theme.Colors.textMuted
                ])
                .chartXAxis {
                    AxisMarks {
                        AxisGridLine().foregroundStyle(Theme.Colors.line)
                        AxisValueLabel().font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.textDim)
                    }
                }
                .chartYAxis {
                    AxisMarks {
                        AxisGridLine().foregroundStyle(Theme.Colors.line)
                        AxisValueLabel().font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.textDim)
                    }
                }
                .frame(height: 180)

                SourceLine(text: cleanSourceLine(snapshot.sourceLine))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func shapeCard(snapshot: AnalyticsSnapshot) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "shape")

                HStack(alignment: .top, spacing: 24) {
                    MetricLine(
                        value: "\(snapshot.shape.sessions)",
                        label: "sessions",
                        accent: .magenta
                    )
                    MetricLine(
                        value: "\(snapshot.shape.turns)",
                        label: "turns",
                        accent: .magenta
                    )
                    MetricLine(
                        value: String(format: "%.1f", snapshot.shape.turnsPerSession),
                        label: "turns per session",
                        accent: .magenta
                    )
                    MetricLine(
                        value: tokens(Int(snapshot.shape.tokensPerTurn)),
                        label: "tokens per turn",
                        accent: .magenta
                    )
                    MetricLine(
                        value: String(format: "%.0f%%", snapshot.shape.toolErrorRate * 100),
                        label: "tool error rate",
                        accent: .magenta
                    )
                }

                SourceLine(text: cleanSourceLine(snapshot.sourceLine))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func projectTokensCard(snapshot: AnalyticsSnapshot) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "tokens and cost by project (top 8)")

                if snapshot.perProject.isEmpty {
                    Text("// no project data")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textDim)
                        .frame(height: 180)
                } else {
                    Chart(snapshot.perProject) { bucket in
                        let totalTokens = bucket.usage.inputTokens + bucket.usage.outputTokens + bucket.usage.cacheCreationTokens + bucket.usage.cacheReadTokens
                        BarMark(
                            x: .value("tokens", totalTokens),
                            y: .value("project", bucket.key)
                        )
                        .foregroundStyle(Theme.Colors.magenta)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(usd(bucket.costUSD))
                                .font(Theme.Fonts.mono(10))
                                .foregroundStyle(Theme.Colors.textDim)
                        }
                    }
                    .chartYScale(domain: snapshot.perProject.map(\.key))
                    .chartXAxis {
                        AxisMarks {
                            AxisGridLine().foregroundStyle(Theme.Colors.line)
                            AxisValueLabel().font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.textDim)
                        }
                    }
                    .chartYAxis {
                        AxisMarks {
                            AxisGridLine().foregroundStyle(Theme.Colors.line)
                            AxisValueLabel().font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.textDim)
                        }
                    }
                    .frame(height: 180)
                }

                SourceLine(text: cleanSourceLine(snapshot.sourceLine))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func modelTokensCard(snapshot: AnalyticsSnapshot) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "tokens and cost by model")

                if snapshot.perModel.isEmpty {
                    Text("// no model data")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textDim)
                        .frame(height: 180)
                } else {
                    Chart(snapshot.perModel) { bucket in
                        let totalTokens = bucket.usage.inputTokens + bucket.usage.outputTokens + bucket.usage.cacheCreationTokens + bucket.usage.cacheReadTokens
                        BarMark(
                            x: .value("tokens", totalTokens),
                            y: .value("model", bucket.key)
                        )
                        .foregroundStyle(Theme.Colors.magenta)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text(usd(bucket.costUSD))
                                .font(Theme.Fonts.mono(10))
                                .foregroundStyle(Theme.Colors.textDim)
                        }
                    }
                    .chartYScale(domain: snapshot.perModel.map(\.key))
                    .chartXAxis {
                        AxisMarks {
                            AxisGridLine().foregroundStyle(Theme.Colors.line)
                            AxisValueLabel().font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.textDim)
                        }
                    }
                    .chartYAxis {
                        AxisMarks {
                            AxisGridLine().foregroundStyle(Theme.Colors.line)
                            AxisValueLabel().font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.textDim)
                        }
                    }
                    .frame(height: 180)
                }

                SourceLine(text: cleanSourceLine(snapshot.sourceLine))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toolsCard(snapshot: AnalyticsSnapshot) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "tools (top 10)")

                if snapshot.perTool.isEmpty {
                    Text("// no tool data")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textDim)
                        .frame(height: 180)
                } else {
                    let topTools = Array(snapshot.perTool.prefix(10))
                    Chart(topTools) { tool in
                        BarMark(
                            x: .value("calls", tool.calls),
                            y: .value("name", tool.name),
                            stacking: .unstacked
                        )
                        .foregroundStyle(Theme.Colors.magenta)

                        BarMark(
                            x: .value("errors", tool.errors),
                            y: .value("name", tool.name),
                            stacking: .unstacked
                        )
                        .foregroundStyle(Theme.Colors.magentaBright)
                    }
                    .chartYScale(domain: topTools.map(\.name))
                    .chartXAxis {
                        AxisMarks {
                            AxisGridLine().foregroundStyle(Theme.Colors.line)
                            AxisValueLabel().font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.textDim)
                        }
                    }
                    .chartYAxis {
                        AxisMarks {
                            AxisGridLine().foregroundStyle(Theme.Colors.line)
                            AxisValueLabel().font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.textDim)
                        }
                    }
                    .frame(height: 200)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("tool")
                                .frame(width: 160, alignment: .leading)
                            Text("calls")
                                .frame(width: 64, alignment: .trailing)
                            Text("errors")
                                .frame(width: 64, alignment: .trailing)
                            Text("median")
                                .frame(width: 64, alignment: .trailing)
                        }
                        .foregroundStyle(Theme.Colors.textDim)

                        ForEach(topTools) { tool in
                            HStack(spacing: 8) {
                                Text(tool.name)
                                    .frame(width: 160, alignment: .leading)
                                Text("\(tool.calls)")
                                    .frame(width: 64, alignment: .trailing)
                                Text("\(tool.errors)")
                                    .frame(width: 64, alignment: .trailing)
                                Text(HistoryFormat.duration(ms: tool.medianDurationMs))
                                    .frame(width: 64, alignment: .trailing)
                            }
                            .foregroundStyle(Theme.Colors.text)
                        }
                    }
                    .font(Theme.Fonts.mono(11))
                }

                SourceLine(text: cleanSourceLine(snapshot.sourceLine))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hourCard(snapshot: AnalyticsSnapshot) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "tokens by hour of day")

                Chart(Array(snapshot.perHour.enumerated()), id: \.offset) { index, tokens in
                    BarMark(
                        x: .value("hour", index),
                        y: .value("tokens", tokens)
                    )
                    .foregroundStyle(Theme.Colors.magenta)
                }
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18]) { value in
                        AxisGridLine().foregroundStyle(Theme.Colors.line)
                        AxisValueLabel {
                            if let hour = value.as(Int.self) {
                                Text(String(format: "%02d", hour))
                                    .font(Theme.Fonts.mono(10))
                                    .foregroundStyle(Theme.Colors.textDim)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks {
                        AxisGridLine().foregroundStyle(Theme.Colors.line)
                        AxisValueLabel().font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.textDim)
                    }
                }
                .frame(height: 140)

                SourceLine(text: cleanSourceLine(snapshot.sourceLine))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cacheRatioCard(snapshot: AnalyticsSnapshot) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "cache read ratio (30d)")

                Chart(AnalyticsViewModel.cacheSeries(snapshot.perDay)) { point in
                    LineMark(
                        x: .value("day", point.day, unit: .day),
                        y: .value("ratio", point.ratio)
                    )
                    .foregroundStyle(Theme.Colors.magenta)
                }
                .chartYScale(domain: 0...1)
                .chartXAxis {
                    AxisMarks {
                        AxisGridLine().foregroundStyle(Theme.Colors.line)
                        AxisValueLabel().font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.textDim)
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Theme.Colors.line)
                        AxisValueLabel {
                            if let d = value.as(Double.self) {
                                Text("\(Int(round(d * 100)))%")
                                    .font(Theme.Fonts.mono(10))
                                    .foregroundStyle(Theme.Colors.textDim)
                            }
                        }
                    }
                }
                .frame(height: 180)

                SourceLine(text: cleanSourceLine(snapshot.sourceLine))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
