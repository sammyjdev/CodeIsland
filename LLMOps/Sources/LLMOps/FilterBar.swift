import SwiftUI
import CodeIslandCore
import LLMOpsCore

struct FilterBar: View {
    var model: AppModel

    var body: some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(Period.allCases, id: \.self) { p in
                        Button {
                            model.filter.select(period: p)
                        } label: {
                            TagPill(text: p.label, active: model.filter.period == p)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 12) {
                    Picker("Project", selection: Binding(
                        get: { model.filter.project },
                        set: { model.filter.project = $0 }
                    )) {
                        Text("all projects").tag(String?.none)
                        ForEach(HistoryFilter.projects(in: model.profileSessions), id: \.self) { project in
                            Text(project).tag(String?.some(project))
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Model", selection: Binding(
                        get: { model.filter.model },
                        set: { model.filter.model = $0 }
                    )) {
                        Text("all models").tag(String?.none)
                        ForEach(HistoryFilter.models(in: model.profileSessions), id: \.self) { model in
                            Text(model).tag(String?.some(model))
                        }
                    }
                    .pickerStyle(.menu)

                    DatePicker("From", selection: Binding(
                        get: { model.filter.from ?? Date() },
                        set: { model.filter.setFrom($0) }
                    ), displayedComponents: .date)
                    .labelsHidden()

                    DatePicker("To", selection: Binding(
                        get: { model.filter.to ?? Date() },
                        set: { model.filter.setTo($0) }
                    ), displayedComponents: .date)
                    .labelsHidden()

                    GhostButton("clear") {
                        model.filter.setFrom(nil)
                        model.filter.setTo(nil)
                    }
                }

                HStack(spacing: 8) {
                    TextField("search prompts", text: Binding(
                        get: { model.filter.search },
                        set: { model.filter.search = $0 }
                    ))
                    .font(Theme.Fonts.mono(12))
                    .textFieldStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Theme.Colors.bg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(Theme.Colors.line, lineWidth: 1)
                    )
                }
            }
        }
    }
}
