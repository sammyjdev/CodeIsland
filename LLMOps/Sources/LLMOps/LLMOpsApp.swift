import SwiftUI

struct RouteView: View {
    var model: AppModel

    var body: some View {
        switch model.route {
        case .live:
            LiveView()
        case .history:
            HistoryView()
        case .analytics:
            AnalyticsView()
        case .settings:
            SettingsView()
        }
    }
}

@main
struct LLMOpsApp: App {
    // Not @State: SwiftUI macros (SwiftUIMacros) are missing from the
    // CommandLineTools toolchain. The App struct is created once, so a plain
    // stored @Observable reference is enough.
    private let model = AppModel()

    init() {
        FontRegistrar.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("llmops") {
            NavigationSplitView {
                Sidebar(model: model)
            } detail: {
                RouteView(model: model)
            }
            .background(Theme.Colors.bg)
            .preferredColorScheme(.dark)
            .task {
                model.rescan()
                model.startPeriodicRescan()
            }
        }
    }
}
