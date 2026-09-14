import SwiftUI
import LLMOpsCore

struct SettingsView: View {
    var model: AppModel
    @StateObject private var state: SettingsState

    init(model: AppModel) {
        self.model = model
        _state = StateObject(wrappedValue: SettingsState(profiles: model.profiles, settings: model.settings))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("settings")
                    Text("preferences")
                        .font(Theme.Fonts.headline(18))
                        .foregroundStyle(Theme.Colors.text)
                }

                profilesCard
                soundsCard
                liveCard
                hookServerCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.Colors.bg)
    }

    // MARK: - Profiles Card

    private var profilesCard: some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 16) {
                Eyebrow("profiles")

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(state.draft.profiles) { profile in
                        profileRow(profile)
                    }
                }

                HStack(spacing: 8) {
                    TextField("name", text: Binding(
                        get: { state.newProfileName },
                        set: { state.newProfileName = $0 }
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

                    TextField("~/.claude-something", text: Binding(
                        get: { state.newProfileDir },
                        set: { state.newProfileDir = $0 }
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

                    GhostButton("add profile") {
                        state.draft.add(name: state.newProfileName, configDir: state.newProfileDir)
                        state.newProfileName = ""
                        state.newProfileDir = ""
                    }
                }

                HStack {
                    let canSave = state.draft.isValid && state.draft.profiles != model.profiles
                    PrimaryButton("save profiles") {
                        model.saveProfiles(state.draft.profiles)
                    }
                    .disabled(!canSave)
                    .opacity(canSave ? 1.0 : 0.4)

                    Spacer()

                    SourceLine("stored in UserDefaults llmops.profiles.v1")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func profileRow(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TagPill(profile.id)

                TextField("name", text: Binding(
                    get: {
                        state.draft.profiles.first(where: { $0.id == profile.id })?.name ?? ""
                    },
                    set: { newName in
                        if let idx = state.draft.profiles.firstIndex(where: { $0.id == profile.id }) {
                            state.draft.profiles[idx].name = newName
                        }
                    }
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

                TextField("config dir", text: Binding(
                    get: {
                        state.draft.profiles.first(where: { $0.id == profile.id })?.configDir ?? ""
                    },
                    set: { newDir in
                        if let idx = state.draft.profiles.firstIndex(where: { $0.id == profile.id }) {
                            state.draft.profiles[idx].configDir = newDir
                        }
                    }
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

                GhostButton("remove") {
                    state.draft.remove(id: profile.id)
                }
                .disabled(state.draft.profiles.count <= 1)
                .opacity(state.draft.profiles.count <= 1 ? 0.4 : 1.0)
            }

            if !profile.pathPrefixes.isEmpty {
                FlowWrapLayout(spacing: 6) {
                    ForEach(profile.pathPrefixes, id: \.self) { prefix in
                        HStack(spacing: 4) {
                            TagPill(prefix)
                            GhostButton("x") {
                                state.draft.removePrefix(prefix, from: profile.id)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("add prefix", text: Binding(
                    get: { state.newPrefix[profile.id] ?? "" },
                    set: { state.newPrefix[profile.id] = $0 }
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
                .onSubmit {
                    let prefix = state.newPrefix[profile.id] ?? ""
                    state.draft.addPrefix(prefix, to: profile.id)
                    state.newPrefix[profile.id] = ""
                }

                GhostButton("add") {
                    let prefix = state.newPrefix[profile.id] ?? ""
                    state.draft.addPrefix(prefix, to: profile.id)
                    state.newPrefix[profile.id] = ""
                }
            }
        }
        .padding(12)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(Theme.Colors.line, lineWidth: 1)
        )
    }

    // MARK: - Sounds Card

    private var soundsCard: some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("sounds")

                Toggle(isOn: Binding(
                    get: { model.settings.soundEnabled },
                    set: { model.settings.soundEnabled = $0 }
                )) {
                    Text("sound enabled")
                        .font(Theme.Fonts.body(12))
                        .foregroundStyle(Theme.Colors.text)
                }
                .toggleStyle(.switch)
                .tint(Theme.Colors.magenta)

                Divider().overlay(Theme.Colors.line)

                soundRow(
                    title: "boot",
                    binding: Binding(
                        get: { model.settings.soundBoot },
                        set: { model.settings.soundBoot = $0 }
                    ),
                    wavName: "8bit_boot"
                )

                soundRow(
                    title: "session start",
                    binding: Binding(
                        get: { model.settings.soundSessionStart },
                        set: { model.settings.soundSessionStart = $0 }
                    ),
                    wavName: "8bit_start"
                )

                soundRow(
                    title: "task complete",
                    binding: Binding(
                        get: { model.settings.soundTaskComplete },
                        set: { model.settings.soundTaskComplete = $0 }
                    ),
                    wavName: "8bit_complete"
                )

                soundRow(
                    title: "task error",
                    binding: Binding(
                        get: { model.settings.soundTaskError },
                        set: { model.settings.soundTaskError = $0 }
                    ),
                    wavName: "8bit_error"
                )

                soundRow(
                    title: "approval needed",
                    binding: Binding(
                        get: { model.settings.soundApprovalNeeded },
                        set: { model.settings.soundApprovalNeeded = $0 }
                    ),
                    wavName: "8bit_approval"
                )

                soundRow(
                    title: "prompt submit",
                    binding: Binding(
                        get: { model.settings.soundPromptSubmit },
                        set: { model.settings.soundPromptSubmit = $0 }
                    ),
                    wavName: "8bit_submit"
                )

                Divider().overlay(Theme.Colors.line)

                HStack(spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { model.settings.quietHoursEnabled },
                        set: { model.settings.quietHoursEnabled = $0 }
                    )) {
                        Text("quiet hours")
                            .font(Theme.Fonts.body(12))
                            .foregroundStyle(Theme.Colors.text)
                    }
                    .toggleStyle(.switch)
                    .tint(Theme.Colors.magenta)

                    Spacer()

                    let startInvalid = Minutes.parse(state.quietStartText) == nil
                    TextField("22:00", text: Binding(
                        get: { state.quietStartText },
                        set: { state.quietStartText = $0 }
                    ))
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(startInvalid ? Theme.Colors.magentaDeep : Theme.Colors.text)
                    .textFieldStyle(.plain)
                    .frame(width: 56)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Theme.Colors.bg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(Theme.Colors.line, lineWidth: 1)
                    )
                    .onSubmit {
                        if let minutes = Minutes.parse(state.quietStartText) {
                            model.settings.quietHoursStartMinutes = minutes
                        }
                    }

                    let endInvalid = Minutes.parse(state.quietEndText) == nil
                    TextField("08:00", text: Binding(
                        get: { state.quietEndText },
                        set: { state.quietEndText = $0 }
                    ))
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(endInvalid ? Theme.Colors.magentaDeep : Theme.Colors.text)
                    .textFieldStyle(.plain)
                    .frame(width: 56)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Theme.Colors.bg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(Theme.Colors.line, lineWidth: 1)
                    )
                    .onSubmit {
                        if let minutes = Minutes.parse(state.quietEndText) {
                            model.settings.quietHoursEndMinutes = minutes
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func soundRow(title: String, binding: Binding<Bool>, wavName: String) -> some View {
        HStack {
            Toggle(isOn: binding) {
                Text(title)
                    .font(Theme.Fonts.body(12))
                    .foregroundStyle(Theme.Colors.text)
            }
            .toggleStyle(.switch)
            .tint(Theme.Colors.magenta)

            Spacer()

            GhostButton("play") {
                model.sounds.preview(wavName)
            }
        }
    }

    // MARK: - Live Card

    private var liveCard: some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("live")

                HStack(spacing: 12) {
                    Text("ended sessions linger (s)")
                        .font(Theme.Fonts.body(12))
                        .foregroundStyle(Theme.Colors.text)

                    Spacer()

                    let isInvalid = Int(state.endedRetentionText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
                    TextField("60", text: Binding(
                        get: { state.endedRetentionText },
                        set: { state.endedRetentionText = $0 }
                    ))
                    .font(Theme.Fonts.mono(12))
                    .foregroundStyle(isInvalid ? Theme.Colors.magentaDeep : Theme.Colors.text)
                    .textFieldStyle(.plain)
                    .frame(width: 56)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(Theme.Colors.bg)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .stroke(Theme.Colors.line, lineWidth: 1)
                    )
                    .onSubmit {
                        if let seconds = Int(state.endedRetentionText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            model.settings.endedRetentionSeconds = seconds
                            model.applySettings()
                            state.endedRetentionText = "\(model.settings.endedRetentionSeconds)"
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Hook Server Card

    private var hookServerCard: some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("hook server")

                VStack(alignment: .leading, spacing: 6) {
                    Text("auto-approve tools")
                        .font(Theme.Fonts.body(12))
                        .foregroundStyle(Theme.Colors.textDim)

                    TextField("Bash, Read", text: Binding(
                        get: { state.autoApproveText },
                        set: { state.autoApproveText = $0 }
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
                    .onSubmit {
                        applyHookServerSettings()
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("excluded cwd substrings")
                        .font(Theme.Fonts.body(12))
                        .foregroundStyle(Theme.Colors.textDim)

                    TextField("substring, substring", text: Binding(
                        get: { state.excludedText },
                        set: { state.excludedText = $0 }
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
                    .onSubmit {
                        applyHookServerSettings()
                    }
                }

                HStack {
                    GhostButton("apply") {
                        applyHookServerSettings()
                    }

                    Spacer()

                    TagPill(model.isServerListening ? "listening" : "down")
                }

                SourceLine("socket: \(HookServer.socketPath)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func applyHookServerSettings() {
        model.settings.autoApproveTools = ListField.parse(state.autoApproveText)
        model.settings.excludedCwdSubstrings = ListField.parse(state.excludedText)
        model.applySettingsToServer()
    }
}

// MARK: - Flow Layout

struct FlowWrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Helpers

extension PrimaryButton {
    init(_ title: String, action: @escaping () -> Void) {
        self.init(title: title, action: action)
    }
}
