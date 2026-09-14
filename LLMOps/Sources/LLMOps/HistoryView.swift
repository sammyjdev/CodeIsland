import SwiftUI
import LLMOpsCore

struct HistoryView: View {
    var model: AppModel
    @StateObject private var state = HistoryState()

    var body: some View {
        let profileSessions = model.profileSessions
        let filtered = model.visibleSessions
        let selectedSession = profileSessions.first(where: { $0.id == state.selectedSessionId })

        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                // Eyebrow("history") + headline "sessions" + TagPill("\(filtered.count) sessions")
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("history")

                    HStack(spacing: 8) {
                        Text("sessions")
                            .font(Theme.Fonts.headline(18))
                            .foregroundStyle(Theme.Colors.text)

                        TagPill("\(filtered.count) sessions")
                    }
                }

                FilterBar(model: model)

                // List of sessions or empty message
                if filtered.isEmpty {
                    Text("// no sessions match")
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.Colors.textMuted)
                        .padding(.top, 16)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filtered) { session in
                                sessionCard(session)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // When a session is selected, show SessionInspector in a trailing panel (HStack, inspector width 460) with a GhostButton("close")
            if let selectedSession {
                Rectangle()
                    .fill(Theme.Colors.line)
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        GhostButton("close") {
                            state.selectedSessionId = nil
                        }
                    }

                    SessionInspector(session: selectedSession, state: state)
                }
                .padding(20)
                .frame(width: 460)
                .background(Theme.Colors.surface)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.bg)
    }

    @ViewBuilder
    private func sessionCard(_ session: Session) -> some View {
        Button {
            state.selectedSessionId = session.id
        } label: {
            EvidenceCard {
                VStack(alignment: .leading, spacing: 8) {
                    // line 1 title (headline 14, falls back to session.id prefix 8) + TagPill(project) + TagPill(model ?? "unknown") + TagPill(profile)
                    HStack(spacing: 8) {
                        let titleText = (session.title?.isEmpty == false ? session.title! : String(session.id.prefix(8)))
                        Text(titleText)
                            .font(Theme.Fonts.headline(14))
                            .foregroundStyle(Theme.Colors.text)
                            .lineLimit(1)

                        Spacer()

                        TagPill(session.project)
                        TagPill(session.model ?? "unknown")
                        TagPill(session.profile)
                    }

                    // line 2 mono 11 textDim: "\(turns.count) turns, \(tokens) tokens, cache \(ratio), est. \(usd)" using HistoryFormat and Aggregates.sessionCost
                    let totalTokens = session.usage.inputTokens + session.usage.outputTokens + session.usage.cacheCreationTokens + session.usage.cacheReadTokens
                    let tokensStr = HistoryFormat.tokens(totalTokens)
                    let ratioStr = HistoryFormat.cacheRatio(session.usage)
                    let costUSD = Aggregates.sessionCost(session).usd
                    let usdStr = HistoryFormat.usd(costUSD)
                    Text("\(session.turns.count) turns, \(tokensStr) tokens, cache \(ratioStr), est. \(usdStr)")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textDim)

                    // line 3 SourceLine("started <date time>, src: <filePath last two components>")
                    let dateStr = HistoryDateFormatter.formatDateTime(session.startedAt)
                    let pathComponents = URL(fileURLWithPath: session.filePath).pathComponents
                    let srcStr = pathComponents.suffix(2).joined(separator: "/")
                    SourceLine("started \(dateStr), src: \(srcStr)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

extension Eyebrow {
    init(_ text: String) {
        self.init(text: text)
    }
}

extension TagPill {
    init(_ text: String, active: Bool = false) {
        self.init(text: text, active: active)
    }
}

extension GhostButton {
    init(_ title: String, action: @escaping () -> Void) {
        self.init(title: title, action: action)
    }
}

extension SourceLine {
    init(_ text: String) {
        self.init(text: text)
    }
}
