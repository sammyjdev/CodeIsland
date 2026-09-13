import SwiftUI
import LLMOpsCore

struct SessionInspector: View {
    let session: Session
    @ObservedObject var state: HistoryState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let titleText = (session.title?.isEmpty == false ? session.title! : session.id)
                Text(titleText)
                    .font(Theme.Fonts.headline(16))
                    .foregroundStyle(Theme.Colors.text)

                VStack(alignment: .leading, spacing: 8) {
                    MetricLine(
                        value: HistoryFormat.tokens(session.usage.inputTokens),
                        label: "input",
                        accent: .neutral
                    )
                    MetricLine(
                        value: HistoryFormat.tokens(session.usage.outputTokens),
                        label: "output",
                        accent: .neutral
                    )
                    MetricLine(
                        value: HistoryFormat.tokens(session.usage.cacheReadTokens),
                        label: "cache read",
                        accent: .magenta
                    )
                    MetricLine(
                        value: HistoryFormat.tokens(session.usage.cacheCreationTokens),
                        label: "cache write",
                        accent: .neutral
                    )
                }

                let costUSD = Aggregates.sessionCost(session).usd
                SourceLine(text: "est. cost \(HistoryFormat.usd(costUSD)) (estimate, price table)")

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.turns) { turn in
                        turnRow(turn)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func turnRow(_ turn: Turn) -> some View {
        let isExpanded = state.expandedTurnIds.contains(turn.id)
        let timeStr = HistoryDateFormatter.formatTime(turn.startedAt)
        let promptFirstLine: String = {
            if let prompt = turn.userPrompt, !prompt.isEmpty {
                let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                if !firstLine.isEmpty {
                    return firstLine
                }
            }
            return "(tool results only)"
        }()
        let turnTokens = turn.usage.inputTokens + turn.usage.outputTokens + turn.usage.cacheCreationTokens + turn.usage.cacheReadTokens
        let tokensStr = HistoryFormat.tokens(turnTokens)

        VStack(alignment: .leading, spacing: 8) {
            Button {
                if isExpanded {
                    state.expandedTurnIds.remove(turn.id)
                } else {
                    state.expandedTurnIds.insert(turn.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(timeStr)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textDim)

                    Text(promptFirstLine)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)

                    Spacer()

                    TagPill(text: "\(turn.toolCalls.count) tools")
                    TagPill(text: tokensStr)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let userPrompt = turn.userPrompt, !userPrompt.isEmpty {
                        Text(userPrompt)
                            .font(Theme.Fonts.body(12))
                            .foregroundStyle(Theme.Colors.text)
                            .lineLimit(8)
                    }

                    if let assistantText = turn.assistantText, !assistantText.isEmpty {
                        Text(assistantText)
                            .font(Theme.Fonts.body(12))
                            .foregroundStyle(Theme.Colors.textDim)
                            .lineLimit(12)
                    }

                    if !turn.toolCalls.isEmpty {
                        ToolTraceView(calls: turn.toolCalls)
                    }
                }
                .padding(.leading, 8)
                .padding(.top, 4)
            }
        }
        .padding(10)
        .background(Theme.Colors.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(Theme.Colors.line, lineWidth: 1)
        )
    }
}
