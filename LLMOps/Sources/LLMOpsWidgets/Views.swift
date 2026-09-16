import SwiftUI
import WidgetKit
import LLMOpsCore

enum WidgetTimeFormat {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

struct QuotasView: View {
    @Environment(\.widgetFamily) var family
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot = entry.snapshot {
                let limit = family == .systemSmall ? 3 : 6
                let quotas = Array(snapshot.quotas.prefix(limit))
                ForEach(0..<quotas.count, id: \.self) { i in
                    Text(WidgetFormat.quotaLine(quotas[i]))
                        .foregroundColor(.white)
                }

                Spacer()

                Text(WidgetTimeFormat.format(snapshot.writtenAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
            } else {
                Text("no data, open LLMOps")
                    .foregroundColor(Color(white: 0.6))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.black, for: .widget)
    }
}

struct TodayView: View {
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot = entry.snapshot {
                Text("sessions ")
                    .foregroundColor(Color(white: 0.6))
                + Text("\(snapshot.today.sessions)")
                    .foregroundColor(.white)

                Text("tokens ")
                    .foregroundColor(Color(white: 0.6))
                + Text(WidgetFormat.tokens(snapshot.today.tokens))
                    .foregroundColor(.white)

                Text("cost ")
                    .foregroundColor(Color(white: 0.6))
                + Text(WidgetFormat.usd(snapshot.today.costUSD))
                    .foregroundColor(.white)

                Spacer()

                Text(WidgetTimeFormat.format(snapshot.writtenAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
            } else {
                Text("no data, open LLMOps")
                    .foregroundColor(Color(white: 0.6))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.black, for: .widget)
    }
}

struct SystemView: View {
    let entry: SnapshotEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot = entry.snapshot {
                Text("cpu ")
                    .foregroundColor(Color(white: 0.6))
                + Text(WidgetFormat.percent(snapshot.system.cpuPercent))
                    .foregroundColor(.white)

                Text("mem ")
                    .foregroundColor(Color(white: 0.6))
                + Text(WidgetFormat.percent(snapshot.system.memoryUsedPercent))
                    .foregroundColor(.white)

                Text("bat ")
                    .foregroundColor(Color(white: 0.6))
                + Text(snapshot.system.batteryPercent.map(WidgetFormat.percent) ?? "-")
                    .foregroundColor(.white)

                Spacer()

                Text(WidgetTimeFormat.format(snapshot.writtenAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Color(white: 0.6))
            } else {
                Text("no data, open LLMOps")
                    .foregroundColor(Color(white: 0.6))
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.black, for: .widget)
    }
}
