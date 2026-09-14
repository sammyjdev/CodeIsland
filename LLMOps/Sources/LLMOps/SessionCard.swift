import SwiftUI
import CodeIslandCore
import LLMOpsCore

struct SessionCard: View {
    let row: LiveRow
    let now: Date

    private var statusWord: String {
        switch row.status {
        case .idle: return "idle"
        case .processing: return "processing"
        case .running: return "running"
        case .waitingApproval: return "waiting approval"
        case .waitingQuestion: return "waiting question"
        }
    }

    private var statusText: String {
        guard let tool = row.currentTool else {
            return "idle"
        }
        let word = statusWord
        if let desc = row.toolDescription, !desc.isEmpty {
            return "\(word) \(tool): \(desc)"
        }
        return "\(word) \(tool)"
    }

    var body: some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    StatusDot(status: row.status)
                    Text(row.title)
                        .font(Theme.Fonts.headline(17))
                        .foregroundStyle(Theme.Colors.text)
                        .lineLimit(1)
                    if row.isEnded {
                        TagPill(text: "ended")
                    }
                    if row.title != row.project && row.project != "unknown" {
                        TagPill(text: row.project)
                    }
                    if let profile = row.profile {
                        TagPill(text: profile)
                    }
                    if row.subagentCount > 0 {
                        TagPill(text: "\(row.subagentCount) subagents")
                    }
                    Spacer()
                }

                if let prompt = row.lastUserPrompt {
                    let firstLine = prompt.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                    if !firstLine.isEmpty {
                        Text(firstLine)
                            .font(Theme.Fonts.body(14))
                            .foregroundStyle(Theme.Colors.textDim)
                            .lineLimit(2)
                    }
                }

                Text(statusText)
                    .font(Theme.Fonts.mono(13))
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(1)

                SourceLine(text: "started \(LiveViewModel.elapsedText(from: row.startedAt, to: now)) ago, id \(row.id.prefix(8))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(row.isEnded ? 0.5 : 1.0)
    }
}
