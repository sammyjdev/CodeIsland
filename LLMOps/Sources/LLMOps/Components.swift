import SwiftUI
import CodeIslandCore

struct EvidenceCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    init(content: Content) {
        self.content = content
    }

    var body: some View {
        content
            .padding(20)
            .background(Theme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .stroke(Theme.Colors.line, lineWidth: 1)
            )
    }
}

struct TagPill: View {
    let text: String
    var active: Bool

    init(text: String, active: Bool = false) {
        self.text = text
        self.active = active
    }

    var body: some View {
        Text(text)
            .font(Theme.Fonts.mono(11))
            .foregroundStyle(active ? Theme.Colors.magenta : Theme.Colors.textDim)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(active ? Theme.Colors.magenta : Theme.Colors.line, lineWidth: 1)
            )
    }
}

/// Local hover state without @State: SwiftUI macros are unavailable on a
/// CommandLineTools-only toolchain, so per-view state goes through
/// ObservableObject + @StateObject instead.
final class HoverFlag: ObservableObject {
    @Published var isOn = false
}

struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.mono(12))
                .foregroundStyle(Theme.Colors.bg)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(hover.isOn ? Theme.Colors.magentaBright : Theme.Colors.magenta)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hover.isOn = hovering
        }
    }
}

struct GhostButton: View {
    let title: String
    let action: () -> Void
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Fonts.mono(12))
                .foregroundStyle(Theme.Colors.text)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .stroke(hover.isOn ? Theme.Colors.magenta : Theme.Colors.line, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hover.isOn = hovering
        }
    }
}

enum MetricAccent: Sendable, Equatable {
    case cyan
    case magenta
    case neutral

    var color: Color {
        switch self {
        case .cyan: return Theme.Colors.cyan
        case .magenta: return Theme.Colors.magenta
        case .neutral: return Theme.Colors.text
        }
    }
}

struct MetricLine: View {
    let value: String
    let label: String
    var accent: MetricAccent

    init(value: String, label: String, accent: MetricAccent = .neutral) {
        self.value = value
        self.label = label
        self.accent = accent
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(Theme.Fonts.metric())
                .foregroundStyle(accent.color)
            Text(label)
                .font(Theme.Fonts.body())
                .foregroundStyle(Theme.Colors.textDim)
        }
    }
}

struct SourceLine: View {
    let text: String

    var body: some View {
        Text("src: " + text)
            .font(Theme.Fonts.mono(10))
            .foregroundStyle(Theme.Colors.textMuted)
    }
}

struct StatusDot: View {
    let status: AgentStatus

    static func color(for status: AgentStatus) -> Color {
        switch status {
        case .idle:
            return Theme.Colors.textMuted
        case .processing, .running:
            return Theme.Colors.magenta
        case .waitingApproval, .waitingQuestion:
            return Theme.Colors.magentaBright
        }
    }

    private var dotColor: Color {
        Self.color(for: status)
    }

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
    }
}

struct Eyebrow: View {
    let text: String

    var body: some View {
        Text("// " + text)
            .font(Theme.Fonts.label(11))
            .tracking(0.08 * 11)
            .foregroundStyle(Theme.Colors.magenta)
    }
}
