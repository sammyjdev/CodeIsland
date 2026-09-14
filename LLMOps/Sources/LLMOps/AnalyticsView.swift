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
                    projectTokensCard(snapshot: snapshot)
                    modelTokensCard(snapshot: snapshot)
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
            state.refresh(sessions: model.visibleSessions, profiles: scopedProfiles)
        }
        .onChange(of: model.lastScanAt) { _, _ in
            state.refresh(sessions: model.visibleSessions, profiles: scopedProfiles)
        }
        .onChange(of: model.selectedProfile) { _, _ in
            state.refresh(sessions: model.visibleSessions, profiles: scopedProfiles)
        }
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

                SourceLine(text: cleanSourceLine(snapshot.sourceLine))
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
                Eyebrow(text: "tokens per day (30d)")

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

    private func projectTokensCard(snapshot: AnalyticsSnapshot) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "tokens by project (top 8)")

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
                Eyebrow(text: "tokens by model")

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
