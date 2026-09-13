import SwiftUI

@main
struct LLMOpsApp: App {
    init() {
        FontRegistrar.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("llmops") {
            NavigationSplitView {
                Text("~ $ llmops")
                    .font(.custom("JetBrainsMono-Medium", size: 12))
                    .padding()
            } detail: {
                Text("// nothing here yet")
                    .font(.custom("JetBrainsMono-Regular", size: 12))
            }
        }
    }
}
