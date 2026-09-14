import SwiftUI
import CodeIslandCore
import LLMOpsCore

/// Injected so tests never spawn a process.
typealias JudgeRun = @Sendable (AnalysisDigest) async throws -> JudgeRunResult

@MainActor
final class AnalysisState: ObservableObject {
    @Published var latest: AnalysisRun?
    @Published var isRunning = false
    @Published var error: String?

    func load(store: AnalysisStore) {
        latest = store.loadLatest()
    }

    /// Builds the digest off the main actor, calls judge, saves, sets latest.
    /// On error sets error (mapped text below) and leaves latest untouched.
    /// Always resets isRunning. Ignored while isRunning is already true.
    func run(
        sessions: [Session],
        profile: String?,
        periodDays: Int,
        model: String,
        store: AnalysisStore,
        judge: @escaping JudgeRun,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        do {
            let digest = await Task.detached {
                AnalysisDigest.build(
                    sessions: sessions,
                    profile: profile,
                    periodDays: periodDays,
                    now: now,
                    calendar: calendar
                )
            }.value

            let result = try await judge(digest)

            let runDate = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
            let run = AnalysisRun(
                generatedAt: runDate,
                profile: profile,
                periodDays: periodDays,
                sessionCount: sessions.count,
                model: result.model,
                costUSD: result.costUSD,
                report: result.report,
                rawText: result.rawText
            )

            try store.save(run)
            self.latest = run
            self.error = nil
        } catch {
            self.error = Self.message(for: error, binaryPath: "")
        }
    }

    static func message(for error: Error, binaryPath: String) -> String {
        if let judgeError = error as? JudgeRunnerError {
            switch judgeError {
            case .binaryMissing(let p):
                let path = p.isEmpty ? binaryPath : p
                return "claude binary not found at \(path), set it in settings"
            case .nonZeroExit(let code, let stderr):
                return "judge exited with \(code): " + String(stderr.prefix(500))
            case .timeout:
                return "judge timed out after 120s"
            case .badOutput(let s):
                return "judge returned unexpected output: " + String(s.prefix(200))
            }
        }
        return String(describing: error)
    }
}

struct AnalysisView: View {
    var model: AppModel
    @StateObject private var state = AnalysisState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: "analysis")
                    Text("judge")
                        .font(Theme.Fonts.headline())
                        .foregroundStyle(Theme.Colors.text)
                }

                FilterBar(model: model)

                HStack(spacing: 12) {
                    PrimaryButton(title: state.isRunning ? "running..." : "run analysis") {
                        let binaryPath = model.settings.judgeBinaryPath
                        let judgeModel = model.settings.judgeModel
                        let store = AnalysisStore(directory: AnalysisStore.defaultDirectory)
                        let sessions = model.visibleSessions
                        let profile = model.selectedProfile
                        let periodDays = model.filter.dayCount(now: Date(), earliest: model.profileSessions.map(\.startedAt).min())
                        Task {
                            await state.run(
                                sessions: sessions,
                                profile: profile,
                                periodDays: periodDays,
                                model: judgeModel,
                                store: store,
                                judge: { digest in
                                    let runner = JudgeRunner(
                                        binaryPath: binaryPath,
                                        model: judgeModel,
                                        workingDirectory: AnalysisStore.defaultDirectory
                                    )
                                    return try await runner.run(digest: digest)
                                }
                            )
                        }
                    }
                    .disabled(state.isRunning)

                    if let run = state.latest {
                        SourceLine(text: cleanSourceLine("src: \(run.model), n=\(run.sessionCount) sessions, \(run.periodDays)d, cost \(run.costUSD.map(usd) ?? "n/a"), \(HistoryDateFormatter.formatDateTime(run.generatedAt))"))
                    }
                }

                if let error = state.error {
                    EvidenceCard {
                        Text(error)
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Colors.magenta)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let run = state.latest {
                    if let report = run.report {
                        EvidenceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Eyebrow(text: "verdict")
                                Text(report.verdict)
                                    .font(Theme.Fonts.body(13))
                                    .foregroundStyle(Theme.Colors.text)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        ForEach(sortedFindings(report.findings)) { finding in
                            EvidenceCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        TagPill(text: finding.severity, active: finding.severity == "high")
                                        Text(finding.title)
                                            .font(Theme.Fonts.headline(14))
                                            .foregroundStyle(Theme.Colors.text)
                                    }
                                    Text(finding.evidence)
                                        .font(Theme.Fonts.mono(11))
                                        .foregroundStyle(Theme.Colors.textDim)
                                    Text(finding.suggestion)
                                        .font(Theme.Fonts.body(12))
                                        .foregroundStyle(Theme.Colors.text)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } else {
                        EvidenceCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Eyebrow(text: "raw output")
                                Text(run.rawText)
                                    .font(Theme.Fonts.mono(11))
                                    .foregroundStyle(Theme.Colors.text)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else if state.error == nil {
                    Text("// no analysis yet, run one")
                        .font(Theme.Fonts.mono(12))
                        .foregroundStyle(Theme.Colors.textDim)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.Colors.bg)
        .onAppear {
            state.load(store: AnalysisStore(directory: AnalysisStore.defaultDirectory))
        }
    }

    private func cleanSourceLine(_ raw: String) -> String {
        if raw.hasPrefix("src: ") {
            return String(raw.dropFirst(5))
        }
        return raw
    }

    private func sortedFindings(_ findings: [JudgeFinding]) -> [JudgeFinding] {
        let rank: (String) -> Int = { severity in
            switch severity.lowercased() {
            case "high": return 0
            case "medium": return 1
            case "low": return 2
            default: return 3
            }
        }
        return findings.enumerated().sorted { a, b in
            let rankA = rank(a.element.severity)
            let rankB = rank(b.element.severity)
            if rankA != rankB {
                return rankA < rankB
            }
            return a.offset < b.offset
        }.map(\.element)
    }
}
