import SwiftUI
import CodeIslandCore
import LLMOpsCore

@MainActor
final class QuotaState: ObservableObject {
    @Published var results: [QuotaProviderID: Result<QuotaSnapshot, QuotaError>] = [:]
    @Published var isRefreshing = false
    @Published var lastRefreshAt: Date?
    nonisolated static let interval: TimeInterval = 300

    private var timer: Timer?

    /// Fetches every provider concurrently, each inside Task.detached (the Keychain and Codex providers do
    /// blocking file and subprocess work, keep them off the main actor), storing one result per id.
    /// Errors that are not QuotaError are wrapped as .network(String(describing:)).
    /// Ignored while isRefreshing.
    func refresh(providers: [any QuotaProvider], now: Date = Date()) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: (QuotaProviderID, Result<QuotaSnapshot, QuotaError>).self) { group in
            for provider in providers {
                group.addTask {
                    await Task.detached {
                        let result: Result<QuotaSnapshot, QuotaError>
                        do {
                            let snapshot = try await provider.fetch(now: now)
                            result = .success(snapshot)
                        } catch let error as QuotaError {
                            result = .failure(error)
                        } catch {
                            result = .failure(.network(String(describing: error)))
                        }
                        return (provider.id, result)
                    }.value
                }
            }
            for await (id, result) in group {
                self.results[id] = result
            }
        }
        self.lastRefreshAt = now
    }

    /// Refreshes now, then every `interval` on a main run loop Timer until stop(). start twice is a no-op.
    func start(providers: [any QuotaProvider], interval: TimeInterval = QuotaState.interval) {
        guard timer == nil else { return }
        Task { [weak self] in
            await self?.refresh(providers: providers)
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh(providers: providers)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Worst used percent for the sidebar: the "5h" window when present, else worstUsedPercent; nil on error or missing.
    func sidebarPercent(for id: QuotaProviderID) -> Double? {
        guard let result = results[id] else { return nil }
        switch result {
        case .failure:
            return nil
        case .success(let snapshot):
            if let fiveHour = snapshot.windows.first(where: { $0.label == "5h" }) {
                return fiveHour.usedPercent
            }
            return snapshot.worstUsedPercent
        }
    }

    static func message(for error: QuotaError) -> String {
        switch error {
        case .missingCredential(let s):
            return "credential missing: \(s)"
        case .network(let s):
            return "network: \(s)"
        case .badPayload(let s):
            return "unexpected payload: \(s)"
        case .notFound(let s):
            return "not found: \(s)"
        case .subprocess(let s):
            return "subprocess: \(s)"
        }
    }
}

struct QuotasView: View {
    var model: AppModel
    @ObservedObject private var state: QuotaState

    init(model: AppModel) {
        self.model = model
        _state = ObservedObject(wrappedValue: model.quotas)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "quotas")
                    Text("limits")
                        .font(Theme.Fonts.headline())
                        .foregroundStyle(Theme.Colors.text)
                }

                HStack(spacing: 12) {
                    PrimaryButton(title: state.isRefreshing ? "refreshing..." : "refresh") {
                        Task {
                            await state.refresh(providers: model.quotaProviders())
                        }
                    }
                    .disabled(state.isRefreshing)

                    if let date = state.lastRefreshAt {
                        SourceLine(text: "last refresh \(HistoryDateFormatter.formatTime(date))")
                    }
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    ForEach(QuotaProviderID.allCases, id: \.self) { id in
                        providerCard(for: id)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.Colors.bg)
    }

    private func providerCard(for id: QuotaProviderID) -> some View {
        EvidenceCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: id.displayName)

                switch state.results[id] {
                case .none:
                    Text("// fetching...")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.textDim)
                case .failure(let error):
                    Text(QuotaState.message(for: error))
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.magenta)
                case .success(let snapshot):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                            windowRow(window)
                        }
                    }

                    if let detail = snapshot.detail {
                        Text(detail)
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Colors.textDim)
                    }

                    SourceLine(text: sourceText(for: id))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func windowRow(_ window: QuotaWindow) -> some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.textDim)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Colors.line)
                        .frame(height: 8)

                    let fraction = max(0, min(1.0, window.usedPercent / 100.0))
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(window.usedPercent >= 80 ? Theme.Colors.magentaBright : Theme.Colors.magenta)
                        .frame(width: max(0, geo.size.width * fraction), height: 8)
                }
            }
            .frame(height: 8)

            Text(String(format: "%.0f%%", window.usedPercent))
                .font(Theme.Fonts.mono(12))
                .foregroundStyle(Theme.Colors.text)
                .frame(width: 44, alignment: .trailing)

            let resetStr = resetText(for: window.resetsAt)
            Text(resetStr)
                .font(Theme.Fonts.mono(11))
                .foregroundStyle(Theme.Colors.textDim)
        }
    }

    private func resetText(for resetsAt: Date?, now: Date = Date()) -> String {
        guard let resetsAt, resetsAt > now else { return "" }
        let diff = resetsAt.timeIntervalSince(now)
        let totalSeconds = Int(diff)
        let totalHours = totalSeconds / 3600
        if totalHours >= 24 {
            let d = totalHours / 24
            let h = totalHours % 24
            return "resets in \(d)d \(h)h"
        } else {
            let h = totalHours
            let mm = String(format: "%02d", (totalSeconds % 3600) / 60)
            return "resets in \(h)h \(mm)m"
        }
    }

    private func sourceText(for id: QuotaProviderID) -> String {
        switch id {
        case .claude: return "api.anthropic.com/api/oauth/usage"
        case .codex: return "~/.codex/sessions rollouts"
        case .antigravity: return "antigravity-usage quota --json"
        case .zai: return "api.z.ai quota/limit"
        case .openrouter: return "openrouter.ai credits and auth/key"
        }
    }
}
