import Foundation
import WidgetKit
import LLMOpsCore

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetData.load())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let date = Date()
        let entry = SnapshotEntry(date: date, snapshot: WidgetData.load())
        let timeline = Timeline(entries: [entry], policy: .after(date + 15 * 60))
        completion(timeline)
    }
}
