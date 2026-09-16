import WidgetKit
import SwiftUI

@main
struct LLMOpsWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuotasWidget()
        TodayWidget()
        SystemWidget()
    }
}

struct QuotasWidget: Widget {
    let kind: String = "quotas"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            QuotasView(entry: entry)
        }
        .configurationDisplayName("LLMOps quotas")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TodayWidget: Widget {
    let kind: String = "today"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            TodayView(entry: entry)
        }
        .configurationDisplayName("LLMOps today")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct SystemWidget: Widget {
    let kind: String = "system"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            SystemView(entry: entry)
        }
        .configurationDisplayName("LLMOps system")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
