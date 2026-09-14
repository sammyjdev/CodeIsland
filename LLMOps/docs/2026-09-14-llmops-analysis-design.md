# LLMOps v1.1: shared filters, richer metrics, analysis tab

Status: approved by the owner on 2026-09-14. Extends `docs/2026-09-13-llmops-mac-design.md`; everything not restated there still holds (design tokens, no `.shadow`, plain hyphen only, `swift test` gate).

## Context

v1 shipped on `main` (merge 7c0ca31). Gaps the owner named: metrics visibility, filtering, and a screen where a model judges the usage history and suggests improvements.

State of the code that this spec builds on:

- `AnalyticsView` renders six fixed cards over a hardcoded 30 day window and only honors the sidebar profile. `HistoryFilter` (project, model, date range, search) is tested but lives in `HistoryState`, so Analytics ignores it.
- `Aggregates.perProject` / `perModel` already compute `costUSD` and `sessions` per bucket; the UI shows tokens only.
- `Turn` carries `userPrompt`, `assistantText`, `model`, `usage`, `toolCalls[{name, durationMs, isError}]`. Enough for a judge without touching the scanner.
- Nothing in the app talks to the network. That stays true: the judge is the `claude` CLI as a subprocess.

Decisions locked in the brainstorm:

- Judge backend: `claude -p` subprocess (owner picked it over direct API and Ollama). Subscription pays, no key in the app, no new dependency. `--no-session-persistence` means the judge writes no JSONL, so the scanner never sees its own runs.
- The binary is `~/.local/bin/claude`. The shell `claude` is a function that routes through `ccm`; the app must never rely on it.
- Executor: agy (Gemini 3.8 Flash Medium) per the v1 execution protocol. Claude orchestrates, validates on host, reviews, commits.

## Spec

### S1. Shared filters

- `HistoryFilter` gains `period: Period` where `enum Period: String, CaseIterable { case d7, d30, d90, all }`. `period` and `from`/`to` are exclusive: picking a preset clears `from`/`to`; editing either date sets `period = .all`. `HistoryFilter.dayCount(now:calendar:earliest:)` returns the number of days the daily chart should show: 7, 30, 90, or days from `earliest` session start to `now` (minimum 1) for `.all`. Default `period = .d30`.
- `apply(to:)` derives the lower bound from `period` when `from` is nil: `now - (dayCount - 1) days` at start of day. `now` is injected (`apply(to:now:)`, default `Date()`).
- The filter moves from `HistoryState` to `AppModel` as `var filter = HistoryFilter()`. `AppModel.visibleSessions` applies profile then filter. `HistoryState` keeps only `selectedSessionId` and `expandedTurnIds`.
- `FilterBar` becomes its own view (`Sources/LLMOps/FilterBar.swift`) rendering: period pills (`7d 30d 90d all`, `TagPill` style, active in magenta), project picker, model picker, from/to date pickers, search field, clear button. History and Analytics both place it under their headline. Picker options come from the profile scoped sessions before the filter is applied (`AppModel.profileSessions`), so narrowing by project never empties the project picker.
- `AnalyticsView` refreshes on `model.filter` changes in addition to `lastScanAt` and `selectedProfile`. `AnalyticsViewModel.build` takes `days: Int` instead of the literal 30 and passes it to `Aggregates.perDay`. The daily card eyebrow reads `tokens per day (<Nd>)`. The 5 h window card is unaffected by the filter (it reads the scanner, not sessions) and its source line says so: `src: usage scanner, unfiltered`.

### S2. New metrics

All in `Sources/LLMOpsCore/Aggregates.swift`, pure, tested in `Tests/LLMOpsCoreTests/CostAndAggregatesTests.swift`.

```swift
public struct ToolUsage: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let calls: Int
    public let errors: Int
    public let medianDurationMs: Int?   // nil when no call has a duration
}
public struct UsageShape: Equatable, Sendable {
    public let sessions: Int
    public let turns: Int
    public let toolCalls: Int
    public let toolErrors: Int
    public var turnsPerSession: Double   // 0 when sessions == 0
    public var tokensPerTurn: Double     // total tokens / turns, 0 when turns == 0
    public var toolErrorRate: Double     // toolErrors / toolCalls, 0 when toolCalls == 0
}
```

- `Aggregates.perTool(_:) -> [ToolUsage]` sorted by calls desc, ties by name. Median over calls with non-nil `durationMs`, lower median for even counts.
- `Aggregates.perHour(_:calendar:) -> [Int]` always 24 entries, total tokens (four kinds) of every turn bucketed by `calendar.component(.hour, from: turn.startedAt)`.
- `Aggregates.shape(_:) -> UsageShape`.
- `AnalyticsSnapshot` gains `perTool`, `perHour`, `shape`. `AnalyticsView` gains three cards after the existing ones, in this order: `shape` (five `MetricLine`s in a row, magenta), `tools (top 10)` (horizontal bars of calls, errors drawn as a second `BarMark` in `magentaBright`, then a mono table name / calls / errors / median), `hour of day` (24 vertical bars, x axis labels `00`, `06`, `12`, `18`).
- Project and model cards show cost: each bar gets an `.annotation(position: .trailing)` with `usd(bucket.costUSD)` in `Theme.Fonts.mono(10)`, and the eyebrow reads `tokens and cost by project (top 8)` / `tokens and cost by model`.

### S3. Analysis tab

**Route.** `Route.analysis` between `analytics` and `settings`. `RouteView` maps it to `AnalysisView`.

**Digest** (`Sources/LLMOpsCore/AnalysisDigest.swift`, Codable, Equatable, Sendable, pure):

```swift
public struct AnalysisDigest: Codable, Equatable, Sendable {
    public struct SessionRow: Codable, Equatable, Sendable {
        let id, title, project, model: String
        let startedAt: Date
        let turns, totalTokens, toolCalls, toolErrors: Int
        let cacheReadRatio, costUSD: Double
    }
    public struct DayRow: Codable, Equatable, Sendable { let day: Date; let totalTokens: Int; let costUSD, cacheReadRatio: Double }
    public struct BucketRow: Codable, Equatable, Sendable { let key: String; let totalTokens, sessions: Int; let costUSD: Double }
    public let generatedAt: Date
    public let profile: String?          // nil = all
    public let periodDays: Int
    public let sessionCount: Int
    public let totals: BucketRow         // key "total"
    public let days: [DayRow]            // one per day, oldest first
    public let projects: [BucketRow]     // top 8
    public let models: [BucketRow]
    public let tools: [ToolUsage]        // top 15
    public let shape: UsageShape
    public let topByCost: [SessionRow]   // top 10
    public let topByErrors: [SessionRow] // top 10 with toolErrors > 0, desc
}
```

`AnalysisDigest.build(sessions:profile:periodDays:now:calendar:)` composes it from `Aggregates`. No prompt or assistant text ever enters the digest; `title` is the session title truncated to 80 characters. Encoded with ISO 8601 dates and sorted keys; a test asserts a 200 session fixture encodes under 20 KB.

**Judge output** (`Sources/LLMOpsCore/JudgeReport.swift`):

```swift
public struct JudgeFinding: Codable, Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let severity: String   // "high" | "medium" | "low"
    public let title: String
    public let evidence: String   // numbers from the digest the model relied on
    public let suggestion: String // one concrete action
}
public struct JudgeReport: Codable, Equatable, Sendable {
    public let verdict: String
    public let findings: [JudgeFinding]
}
public enum JudgeReportParser {
    /// Accepts the raw `result` string. Strips a ```json fence if present, then
    /// decodes. Returns nil on any failure; the caller shows the raw text instead.
    public static func parse(_ text: String) -> JudgeReport?
}
```

**Prompt** (`Sources/LLMOps/JudgePrompt.swift`, one static string, English). System prompt: the model is auditing a developer's Claude Code usage from an aggregated digest; it must return only JSON matching `JudgeReport`; severities are high/medium/low; each finding cites numbers from the digest; at most 8 findings; it must look for: low cache read ratio, tools with high error rate, sessions with many turns and high cost, expensive model on small sessions, cost concentrated in one project, usage spikes by hour or day; suggestions must be actions the developer can take in Claude Code (prompting, session hygiene, model choice, tool allowlists). Plain hyphen only, no em dashes.

**Runner** (`Sources/LLMOps/JudgeRunner.swift`):

```swift
struct JudgeRunResult: Equatable { let report: JudgeReport?; let rawText: String; let costUSD: Double?; let model: String }
enum JudgeRunnerError: Error, Equatable { case binaryMissing(String); case nonZeroExit(Int32, String); case timeout; case badOutput(String) }
struct JudgeRunner {
    var binaryPath: String
    var model: String
    var timeout: TimeInterval = 120
    func run(digest: AnalysisDigest) async throws -> JudgeRunResult
}
```

- Arguments: `-p --output-format json --no-session-persistence --tools "" --model <model> --system-prompt <JudgePrompt.system>`. The digest JSON is written to stdin, then stdin closes. `cwd` is the app's `Application Support/LLMOps` directory so the CLI never picks up a project `CLAUDE.md`. Environment: inherited, with `CLAUDECODE` removed so the CLI does not refuse as a nested session; `CLAUDE_CONFIG_DIR` is left untouched (default profile).
- Parse stdout as JSON: `result` (string) and `total_cost_usd` (double, optional). `rawText = result`, `report = JudgeReportParser.parse(result)`. Missing `result` is `badOutput`.
- `binaryPath` not executable: `binaryMissing`. Exit status != 0: `nonZeroExit(status, stderr)`. Timeout: terminate the process, throw `timeout`.
- Tests (`Tests/LLMOpsAppTests/JudgeRunnerTests.swift`): a stub executable written to a temp dir (`#!/bin/sh`, echoes a fixed JSON with a fenced `result`) proves the happy path and that stdin received the digest (the stub copies stdin to a side file); a stub exiting 3 with stderr text proves `nonZeroExit`; a `sleep 5` stub with `timeout: 0.5` proves `timeout`; a bogus path proves `binaryMissing`.

**Persistence** (`Sources/LLMOps/AnalysisStore.swift`):

```swift
struct AnalysisRun: Codable, Equatable, Identifiable {
    let id: String              // ISO 8601 generatedAt, filesystem safe (colons replaced by "-")
    let generatedAt: Date
    let profile: String?
    let periodDays: Int
    let sessionCount: Int
    let model: String
    let costUSD: Double?
    let report: JudgeReport?
    let rawText: String
}
final class AnalysisStore {
    init(directory: URL)        // default: Application Support/LLMOps/analysis
    func save(_ run: AnalysisRun) throws
    func loadLatest() -> AnalysisRun?
}
```

One file per run, `<id>.json`. Tested with a temp directory: save then loadLatest round trips; two saves return the newer one.

**Settings.** `LLMOpsSettings` gains `judgeBinaryPath` (default `~/.local/bin/claude` expanded) and `judgeModel` (default `sonnet`). `SettingsView` gets a `judge` section with the two text fields, following the existing field style.

**State and view** (`Sources/LLMOps/AnalysisView.swift`, `AnalysisState`):

- `AnalysisState: ObservableObject` holds `latest: AnalysisRun?`, `isRunning: Bool`, `error: String?`. `load(store:)` on appear. `run(sessions:profile:periodDays:settings:store:)` builds the digest on a detached task, calls `JudgeRunner`, saves the run, sets `latest`. Errors map to a mono string: `binaryMissing` says `claude binary not found at <path>, set it in settings`; `nonZeroExit` shows the status and the first 500 chars of stderr; `timeout` says `judge timed out after 120s`.
- Layout: eyebrow `analysis`, headline `judge`, then `FilterBar` (same shared component, the run uses the currently filtered sessions), then a row with `PrimaryButton("run analysis")` (disabled while running, label `running...` then) and a source line `src: <model>, n=<sessions> sessions, <Nd>, cost <usd>, <date>` for the latest run. Empty state `// no analysis yet, run one`.
- Result: an `EvidenceCard` with the verdict in body font, then one `EvidenceCard` per finding: severity `TagPill` (high in magenta, medium in cyan text, low dim), title in headline 14, evidence in mono 11 dim, suggestion in body. If `report` is nil, one card with `rawText` in mono 11.
- Errors render in an `EvidenceCard` in mono 11, magenta text.

### S4. Out of scope

Scheduled or automatic runs, comparing two runs, sending prompts or transcripts to the judge, per-session judging, streaming output, choosing a different profile's config dir for the judge.

## Task breakdown

Each task: red test first, `swift test` green from `LLMOps/`, no em dashes, no `.shadow`, English only, files limited to the task list, final message lists changed files.

### Batch 1 (core, no UI)

**Task 1: Period and shared filter model** (`Sources/LLMOps/HistoryFilter.swift`, `Sources/LLMOps/AppModel.swift`, `Tests/LLMOpsAppTests/HistoryFilterTests.swift`, `Tests/LLMOpsAppTests/AppModelTests.swift`)

- Add `Period`, `period`, `dayCount`, `apply(to:now:)` with the exclusivity rules from S1. Move `filter` to `AppModel`, add `profileSessions`, make `visibleSessions` apply it. `HistoryState` loses `filter`. `HistoryView` compiles by reading `model.filter` (minimal edit; the bar is replaced in Task 4).
- Tests: `.d7` keeps a session from 6 days ago and drops one from 8 days ago; explicit `from` overrides the preset lower bound; setting `period` clears dates; `dayCount(.all)` from a 45 day old earliest session is 45; `AppModel.visibleSessions` honors both profile and filter.

**Task 2: New aggregates** (`Sources/LLMOpsCore/Aggregates.swift`, `Tests/LLMOpsCoreTests/CostAndAggregatesTests.swift`)

- `ToolUsage`, `UsageShape`, `perTool`, `perHour`, `shape` per S2.
- Tests: perTool counts, errors and lower median over three durations with one nil; sort order; perHour has 24 entries and buckets a 13:30 UTC turn into index 13 with a UTC calendar; shape ratios and the zero guards.

**Task 3: Digest and report parser** (`Sources/LLMOpsCore/AnalysisDigest.swift`, `Sources/LLMOpsCore/JudgeReport.swift`, `Tests/LLMOpsCoreTests/AnalysisDigestTests.swift`)

- Per S3 digest and parser.
- Tests: build over a 3 session fixture gives correct topByCost order, topByErrors excludes zero error sessions, titles truncated to 80, no `userPrompt` text appears in the encoded JSON (assert the fixture's prompt string is absent); 200 session fixture encodes under 20 KB; parser accepts plain JSON, fenced JSON, and returns nil on prose.

### Batch 2 (app plumbing)

**Task 4: FilterBar and analytics wiring** (`Sources/LLMOps/FilterBar.swift`, `Sources/LLMOps/HistoryView.swift`, `Sources/LLMOps/AnalyticsView.swift`, `Sources/LLMOps/AnalyticsViewModel.swift`, `Tests/LLMOpsAppTests/AnalyticsViewModelTests.swift`)

- Extract the bar, add period pills, place it in both screens, thread `days` into `build`, add `perTool`/`perHour`/`shape` to the snapshot, refresh on filter change, unfiltered source line on the window card.
- Tests: `build(days: 7)` yields 7 `perDay` entries; snapshot carries the three new fields.

**Task 5: New analytics cards** (`Sources/LLMOps/AnalyticsView.swift`)

- The three cards and the cost annotations per S2. View only; the gate is `swift build` plus the existing tests, and a grep that the three eyebrow strings exist.

**Task 6: Judge runner, store, settings** (`Sources/LLMOps/JudgeRunner.swift`, `Sources/LLMOps/JudgePrompt.swift`, `Sources/LLMOps/AnalysisStore.swift`, `Sources/LLMOps/LLMOpsSettings.swift`, `Sources/LLMOps/SettingsView.swift`, `Tests/LLMOpsAppTests/JudgeRunnerTests.swift`, `Tests/LLMOpsAppTests/AnalysisStoreTests.swift`, `Tests/LLMOpsAppTests/SoundAndSettingsTests.swift`)

- Per S3 runner, prompt, store, settings, judge section in Settings.
- Tests listed in S3 plus settings defaults and round trip.

### Batch 3 (screen)

**Task 7: Analysis view and route** (`Sources/LLMOps/AnalysisView.swift`, `Sources/LLMOps/AppModel.swift`, `Sources/LLMOps/LLMOpsApp.swift`, `Tests/LLMOpsAppTests/AnalysisStateTests.swift`)

- `Route.analysis`, `AnalysisState`, `AnalysisView` per S3.
- Tests: `AnalysisState.run` with an injected runner closure returning a fixed `JudgeRunResult` saves to a temp store and sets `latest`; a throwing runner sets `error` with the mapped message and leaves `latest` untouched; `Route.allCases` contains `analysis` between `analytics` and `settings`.

**Task 8: Acceptance** (orchestrator + owner)

- `swift build && swift test` green from `LLMOps/`. `swift run LLMOps`: pick `7d`, Analytics daily chart shows 7 bars and the tools card lists real tool names; History honors the same pills. Open `analysis`, run it, a report with findings appears, the source line shows a cost, and `ls ~/.claude/projects` has no new session directory afterwards. Restart the app: the last run is still shown.

## Execution protocol (agy)

Same as the v1 spec: `agy:agy-executor`, `Gemini 3.8 Flash (Medium)`, throwaway clone per task on `main`, briefs with relative paths only, host validation (`git diff | git apply`, `swift build && swift test` from `LLMOps/`, em dash grep, `.shadow` grep, `git status` shows only the task's files), review by `general-purpose`, adversarial flip before commit, one commit per task, orchestrator implements after a second agy failure on the same task.

Files to read first in every brief: `Sources/LLMOpsCore/Transcript.swift`, `Sources/LLMOpsCore/Aggregates.swift`, `Sources/LLMOps/HistoryFilter.swift`, `Sources/LLMOps/AppModel.swift`, `Sources/LLMOps/Theme.swift`, `Sources/LLMOps/Components.swift`, and this spec.
