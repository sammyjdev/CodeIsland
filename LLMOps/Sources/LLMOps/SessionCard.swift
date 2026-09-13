import SwiftUI
import CodeIslandCore
import LLMOpsCore

struct SessionCard: View {
    let row: LiveRow
    let now: Date

    var body: some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    StatusDot(status: row.status)
                    Text(row.title)
                        .font(Theme.Fonts.headline(15))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    TagPill(text: row.project)
                    if let profile = row.profile {
                        TagPill(text: profile)
                    }
                    if row.subagentCount > 0 {
                        TagPill(text: "\(row.subagentCount) subagents")
                    }
                    Spacer()
                }

                let toolText: String = {
                    if let tool = row.currentTool {
                        if let desc = row.toolDescription, !desc.isEmpty {
                            return "\(tool): \(desc)"
                        }
                        return tool
                    }
                    return "idle"
                }()
                Text(toolText)
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(1)

                if let prompt = row.lastUserPrompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(Theme.Fonts.body(12))
                        .foregroundStyle(Theme.Colors.textMuted)
                        .lineLimit(2)
                }

                SourceLine(text: "started \(LiveViewModel.elapsedText(from: row.startedAt, to: now)) ago, id \(row.id.prefix(8))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(row.isEnded ? 0.5 : 1.0)
    }
}
