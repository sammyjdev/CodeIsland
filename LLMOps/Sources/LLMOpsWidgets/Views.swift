import SwiftUI
import WidgetKit
import LLMOpsCore

struct QuotasView: View {
    @Environment(\.widgetFamily) var family
    let entry: SnapshotEntry

    var body: some View {
        let groups = entry.snapshot.map { WidgetFormat.grouped($0.quotas) } ?? []
        let hasData = entry.snapshot != nil && !groups.isEmpty

        WidgetFrame(title: "quotas", writtenAt: hasData ? entry.snapshot?.writtenAt : nil) {
            if hasData {
                switch family {
                case .systemMedium:
                    QuotasMediumView(groups: groups, now: entry.date)
                default:
                    QuotasSmallView(groups: groups)
                }
            } else {
                EmptyState()
            }
        }
    }
}

private struct QuotasSmallView: View {
    let groups: [(provider: QuotaProviderID, quotas: [WidgetQuota])]

    var body: some View {
        // Fixed name and percent columns so the bars align; spacing 4 fits 5 rows in systemSmall.
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            ForEach(Array(groups.prefix(5)), id: \.provider) { group in
                let worst = WidgetFormat.worstPercent(group.quotas)
                HStack(spacing: 6) {
                    Text(WidgetFormat.providerName(group.provider))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(WidgetPalette.accentBright)
                        .lineLimit(1)
                        .frame(width: 60, alignment: .leading)

                    QuotaBar(percent: worst)

                    Text(WidgetFormat.percent(worst))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(WidgetPalette.text)
                        .lineLimit(1)
                        .frame(width: 28, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct QuotasMediumView: View {
    let groups: [(provider: QuotaProviderID, quotas: [WidgetQuota])]
    let now: Date

    var body: some View {
        let mid = (groups.count + 1) / 2
        let col1 = Array(groups.prefix(mid))
        let col2 = Array(groups.dropFirst(mid))

        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(col1, id: \.provider) { group in
                    providerBlock(group)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(col2, id: \.provider) { group in
                    providerBlock(group)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func providerBlock(_ group: (provider: QuotaProviderID, quotas: [WidgetQuota])) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(WidgetFormat.providerName(group.provider))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(WidgetPalette.accentBright)
                .lineLimit(1)

            // A column is about 150 pt: label, bar and percent on one line, the reset
            // under it, otherwise the bar collapses to a few points.
            ForEach(Array(group.quotas.prefix(3).enumerated()), id: \.offset) { _, window in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(window.label)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(WidgetPalette.dim)
                            .lineLimit(1)
                            .frame(width: 44, alignment: .leading)

                        QuotaBar(percent: window.usedPercent)
                            .frame(minWidth: 40)

                        Text(WidgetFormat.percent(window.usedPercent))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(WidgetPalette.text)
                            .lineLimit(1)
                            .frame(width: 28, alignment: .trailing)
                    }
                    if let resets = WidgetFormat.resetsIn(window.resetsAt, now: now) {
                        Text("resets \(resets)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(WidgetPalette.muted)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct TodayView: View {
    @Environment(\.widgetFamily) var family
    let entry: SnapshotEntry

    var body: some View {
        WidgetFrame(title: "today", writtenAt: entry.snapshot?.writtenAt) {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemMedium:
                    TodayMediumView(today: snapshot.today)
                default:
                    TodaySmallView(today: snapshot.today)
                }
            } else {
                EmptyState()
            }
        }
    }
}

private struct TodaySmallView: View {
    let today: TodaySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)

            Text(WidgetFormat.usd(today.costUSD))
                .font(.system(size: 24, design: .monospaced))
                .foregroundColor(WidgetPalette.text)
                .lineLimit(1)

            Spacer(minLength: 2)

            Text("\(today.sessions) sessions")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(WidgetPalette.dim)
                .lineLimit(1)

            Text("\(WidgetFormat.tokens(today.tokens)) tokens")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(WidgetPalette.dim)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct TodayMediumView: View {
    let today: TodaySummary

    var body: some View {
        HStack(spacing: 0) {
            statTile(label: "cost", value: WidgetFormat.usd(today.costUSD))

            Rectangle()
                .fill(WidgetPalette.line)
                .frame(width: 1)
                .padding(.vertical, 4)

            statTile(label: "sessions", value: "\(today.sessions)")

            Rectangle()
                .fill(WidgetPalette.line)
                .frame(width: 1)
                .padding(.vertical, 4)

            statTile(label: "tokens", value: WidgetFormat.tokens(today.tokens))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundColor(WidgetPalette.dim)
            Text(value)
                .font(.system(size: 20, design: .monospaced))
                .foregroundColor(WidgetPalette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }
}

struct SystemView: View {
    @Environment(\.widgetFamily) var family
    let entry: SnapshotEntry

    var body: some View {
        WidgetFrame(title: "system", writtenAt: entry.snapshot?.writtenAt) {
            if let snapshot = entry.snapshot {
                SystemRowsView(system: snapshot.system, isMedium: family == .systemMedium)
            } else {
                EmptyState()
            }
        }
    }
}

private struct SystemRowsView: View {
    let system: SystemSummary
    let isMedium: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isMedium ? 10 : 8) {
            Spacer(minLength: 0)
            systemRow(
                label: "cpu",
                percent: system.cpuPercent,
                tint: WidgetPalette.cyan,
                value: WidgetFormat.percent(system.cpuPercent)
            )
            systemRow(
                label: "mem",
                percent: system.memoryUsedPercent,
                tint: WidgetPalette.accent,
                value: WidgetFormat.percent(system.memoryUsedPercent)
            )
            systemRow(
                label: "bat",
                percent: system.batteryPercent,
                tint: WidgetPalette.accentBright,
                value: system.batteryPercent.map(WidgetFormat.percent) ?? "-"
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func systemRow(label: String, percent: Double?, tint: Color, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: isMedium ? 11 : 10, design: .monospaced))
                .foregroundColor(WidgetPalette.dim)
                .frame(width: isMedium ? 28 : 24, alignment: .leading)

            QuotaBar(percent: percent, tint: tint)

            Text(value)
                .font(.system(size: isMedium ? 14 : 10, design: .monospaced))
                .foregroundColor(WidgetPalette.text)
                .frame(width: isMedium ? 44 : 32, alignment: .trailing)
        }
    }
}
