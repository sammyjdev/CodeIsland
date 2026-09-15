import SwiftUI
import LLMOpsCore

struct Sidebar: View {
    // Plain reference, not @Bindable: SwiftUI macros are unavailable on a
    // CommandLineTools-only toolchain. @Observable still tracks reads.
    var model: AppModel
    @ObservedObject private var quotas: QuotaState

    init(model: AppModel) {
        self.model = model
        _quotas = ObservedObject(wrappedValue: model.quotas)
    }

    private var quotaLine: String {
        QuotaProviderID.allCases.map { id in
            let label: String
            switch id {
            case .claude: label = "claude"
            case .codex: label = "codex"
            case .antigravity: label = "agy"
            case .zai: label = "zai"
            case .openrouter: label = "or"
            }
            let valueText: String
            if let pct = quotas.sidebarPercent(for: id) {
                valueText = "\(Int(pct.rounded()))"
            } else {
                valueText = "--"
            }
            return "\(label) \(valueText)"
        }.joined(separator: "  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                Text("~ ")
                    .foregroundStyle(Theme.Colors.text)
                Text("$")
                    .foregroundStyle(Theme.Colors.magenta)
                Text(" llmops")
                    .foregroundStyle(Theme.Colors.text)
            }
            .font(Theme.Fonts.mono(12))
            .padding(.horizontal, 16)
            .padding(.top, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button {
                        model.selectedProfile = nil
                    } label: {
                        TagPill(text: "all", active: model.selectedProfile == nil)
                    }
                    .buttonStyle(.plain)

                    ForEach(model.profiles) { profile in
                        Button {
                            model.selectedProfile = profile.id
                        } label: {
                            TagPill(text: profile.id, active: model.selectedProfile == profile.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Route.allCases) { route in
                    let isSelected = model.route == route
                    Button {
                        model.route = route
                    } label: {
                        HStack(spacing: 8) {
                            Rectangle()
                                .fill(isSelected ? Theme.Colors.magenta : Color.clear)
                                .frame(width: 2)

                            Text(route.rawValue)
                                .font(Theme.Fonts.mono(12))
                                .foregroundStyle(isSelected ? Theme.Colors.text : Theme.Colors.textDim)

                            Spacer()
                        }
                        .frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(quotaLine)
                .font(Theme.Fonts.mono(10))
                .foregroundStyle(Theme.Colors.textDim)
                .padding(.horizontal, 16)

            Spacer()
        }
        .frame(minWidth: 200, idealWidth: 220)
        .background(Theme.Colors.bg)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.Colors.line)
                .frame(width: 1)
        }
    }
}
