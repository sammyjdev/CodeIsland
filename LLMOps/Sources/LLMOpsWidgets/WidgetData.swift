import Foundation
import LLMOpsCore

enum WidgetData {
    static func load() -> WidgetSnapshot? {
        WidgetSnapshotStore(
            directory: FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
        ).read()
    }
}
