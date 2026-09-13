import SwiftUI
import CodeIslandCore
import LLMOpsCore

struct PermissionCard: View {
    let item: PendingPermission
    var now: Date = Date()
    let onDecide: (Decision) -> Void

    init(item: PendingPermission, now: Date = Date(), onDecide: @escaping (Decision) -> Void) {
        self.item = item
        self.now = now
        self.onDecide = onDecide
    }

    var body: some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: item.kind == .permission ? "permission" : "question")

                HStack(alignment: .center, spacing: 8) {
                    if let toolName = item.toolName, !toolName.isEmpty {
                        Text(toolName)
                            .font(Theme.Fonts.mono(13))
                            .foregroundStyle(Theme.Colors.text)
                    }
                    TagPill(text: String(item.sessionId.prefix(8)))
                    Spacer()
                }

                if let description = item.description, !description.isEmpty {
                    Text(description)
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.Colors.textDim)
                        .lineLimit(6)
                }

                HStack(spacing: 8) {
                    switch item.kind {
                    case .permission:
                        PrimaryButton(title: "allow") {
                            onDecide(.allow)
                        }
                        GhostButton(title: "deny") {
                            onDecide(.deny)
                        }
                    case .question:
                        if let options = item.options, !options.isEmpty {
                            ForEach(options, id: \.self) { option in
                                GhostButton(title: option) {
                                    onDecide(.answer(option))
                                }
                            }
                        } else {
                            GhostButton(title: "deny") {
                                onDecide(.deny)
                            }
                        }
                    }
                }

                SourceLine(text: "waiting \(LiveViewModel.elapsedText(from: item.receivedAt, to: now))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.Colors.cyan)
                .frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
    }
}
