import SwiftUI

struct RouteView: View {
    var model: AppModel

    var body: some View {
        switch model.route {
        case .live:
            LiveView(model: model)
        case .history:
            HistoryView(model: model)
        case .analytics:
            AnalyticsView(model: model)
        case .settings:
            SettingsView(model: model)
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
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            } detail: {
                RouteView(model: model)
            }
            .background(Theme.Colors.bg)
            .preferredColorScheme(.dark)
            .task {
                model.rescan()
                model.startPeriodicRescan()
                model.startServer()
                model.sounds.playBoot()
            }
        }
        .defaultSize(width: 1400, height: 900)
    }
}
