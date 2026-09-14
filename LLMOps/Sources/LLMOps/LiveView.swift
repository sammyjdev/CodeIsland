import SwiftUI
import CodeIslandCore
import LLMOpsCore

struct LiveView: View {
    var model: AppModel

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let now = timeline.date
                let rows = LiveViewModel.rows(from: model.live, profile: model.selectedProfile)
                let pending = LiveViewModel.pending(from: model.live, profile: model.selectedProfile)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 12) {
                        Eyebrow(text: "live")
                        Text("sessions")
                            .font(Theme.Fonts.headline())
                            .foregroundStyle(Theme.Colors.text)
                        Spacer()
                        if rows.contains(where: \.isEnded) {
                            GhostButton(title: "clear ended") {
                                model.live.clearEnded()
                            }
                        }
                        TagPill(
                            text: model.isServerListening ? "socket: listening" : "socket: down",
                            active: model.isServerListening
                        )
                    }

                    if pending.isEmpty && rows.isEmpty {
                        Text("// no active sessions")
                            .font(Theme.Fonts.mono(12))
                            .foregroundStyle(Theme.Colors.textMuted)
                    } else {
                        ForEach(pending) { item in
                            PermissionCard(item: item, now: now) { decision in
                                model.live.resolve(id: item.id, decision: decision)
                            }
                        }

                        ForEach(rows) { row in
                            SessionCard(row: row, now: now)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(24)
        }
        .background(Theme.Colors.bg)
    }
}
