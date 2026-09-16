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

## Amendments (2026-09-14, after execution)

- Gate on this machine is `LLMOps/test.sh` (native build system plus the CommandLineTools frameworks dir), not a bare `swift test`, which dies with "Unknown error parsing property list". Same for `swift build --build-system native`. Every brief carries this note.
- `HistoryFilter` gained an explicit `init` that infers `period = .all` when `from` or `to` is passed, so call sites that build a filter with dates keep their meaning.
- `JudgePrompt.system` describes the schema with double quoted keys; the first draft used single quotes and would have invited invalid JSON. The runner args test escapes quotes in its stub for the same reason.
- Real run of `claude -p --no-session-persistence --tools "" --model sonnet` with a sample digest: valid JSON, 5 findings, `total_cost_usd` 0.086, no new directory under `~/.claude/projects`.
- Tasks 1 to 7 landed as one commit each on `llmops-analysis` (17e291d to cef1d98), 166 tests in 15 suites. Task 8 (acceptance in the running app) is pending the owner relaunching the bundle.

## S5. System report tab (approved 2026-09-14)

Owner request: a `system` screen with CPU, RAM, the processes consuming the most, and battery.

**Data** (`Sources/LLMOpsCore/SystemSampler.swift`, no dependency, no process spawn):

```swift
public struct MemorySample: Equatable, Sendable { public let total, used, wired, compressed, free: UInt64 }  // bytes
public struct ProcessSample: Identifiable, Equatable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32; public let name: String; public let cpuPercent: Double; public let rssBytes: UInt64; public let isAI: Bool
}
public struct BatterySample: Equatable, Sendable {
    public let percent: Int; public let isCharging: Bool; public let isPluggedIn: Bool
    public let minutesRemaining: Int?; public let cycleCount: Int?; public let healthPercent: Int?
}
public struct SystemSample: Equatable, Sendable {
    public let at: Date; public let cpuPercent: Double; public let memory: MemorySample
    public let topByCPU: [ProcessSample]; public let topByMemory: [ProcessSample]; public let battery: BatterySample?
}

/// Raw readings, one struct per tick, so the delta math is pure and testable.
public struct RawReading: Equatable, Sendable {
    public let at: Date
    public let cpuTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)   // host_processor_info summed over cores
    public let memory: MemorySample
    public let processes: [RawProcess]   // proc_listallpids + proc_pidinfo(PROC_PIDTASKINFO) + proc_name
    public let battery: BatterySample?   // IOPSCopyPowerSourcesInfo
}
public struct RawProcess: Equatable, Sendable { public let pid: Int32; public let name: String; public let cpuTimeNs: UInt64; public let rssBytes: UInt64 }

public protocol SystemProbe: Sendable { func read(now: Date) -> RawReading }
public struct MachProbe: SystemProbe { public init() }

public enum SystemSampler {
    /// Pure: cpuPercent from tick deltas, per process cpu from cpuTimeNs delta over wall time
    /// (a process absent from `previous` gets 0). topByCPU / topByMemory are the first `top`
    /// after sorting desc, ties by pid asc. isAI = name (lowercased) matches one of
    /// ["claude", "codex", "agy", "ccm", "llmops", "codeisland-bridge"] as prefix or equals "node" with a parent that matches: parent
    /// lookup is out of scope for v1, so "node" is not tagged.
    public static func sample(previous: RawReading?, current: RawReading, top: Int) -> SystemSample
    public static func isAIProcess(name: String) -> Bool
}
```

`HistoryFormat.bytes(_:)` formats `UInt64` as `1.2 GB` / `340 MB` / `12 KB` (1024 based, one decimal above 10).

**Screen** (`Sources/LLMOps/SystemView.swift`, `SystemState`): `Route.system` between `analysis` and `settings`. `SystemState: ObservableObject` holds `latest: SystemSample?`, `cpuHistory: [Double]` and `memoryHistory: [Double]` (ring of 30 samples), `sortBy: cpu | memory`, `previous: RawReading?`; `start(probe:interval:)` schedules a `Timer` every 2 s on the main run loop and `stop()` invalidates it; the view calls them on appear / disappear. Layout: hero cyan `MetricLine` with CPU percent and a 30 point bar sparkline (same style as the 5 h window card); magenta card with used / total RAM and its sparkline plus a mono line `wired <x>, compressed <y>, free <z>`; `top processes` card with pills `cpu` / `memory`, a mono table pid / name / cpu % / rss, rows with `isAI` get a `TagPill(text: "ai", active: true)`; `battery` card: percent as `MetricLine`, state line (`charging`, `on battery, 2h 10m left`, `plugged in, full`), cycles and health when present, `// no battery` when nil. Nothing persisted.

**Tests**: `SystemSamplerTests` (core): cpu percent from two tick readings (idle delta 50 of 100 busy total gives 50.0), per process percent from cpuTimeNs delta over a 2 s wall interval, absent previous gives 0, top ordering and tie break, `isAIProcess` cases, `bytes` formatting. `SystemStateTests` (app): a fake probe returning scripted readings drives `start` with `interval: 0.01`, history caps at 30, `stop` halts updates, `Route.allCases` order.

Out of scope: disk, network, alerts, killing processes, persisting history, parent process lookup.
- S5 landed as two commits (109342a core, d2ccccf screen), 180 tests in 17 suites. Host added `mach_port_deallocate` for the `mach_host_self` port in `MachProbe.read`. Battery `cycleCount` and `healthPercent` stay nil in v1.

## S6. Quotas tab: usage limits of four subscriptions (approved 2026-09-14)

Owner request: monitor the usage limits of Claude (personal), Codex, Antigravity and Z.ai. This revises the v1 "no network" rule: the app now performs two read only GETs (Anthropic, Z.ai) with the user's own credentials, nothing else leaves the machine.

Sources, all verified live on 2026-09-14:

- Claude: OAuth access token from the Keychain item `Claude Code-credentials` (JSON, `claudeAiOauth.accessToken`, read through `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`), GET `https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer` and `anthropic-beta: oauth-2025-04-20`. Fields: `five_hour.utilization`, `five_hour.resets_at`, `seven_day.utilization`, `seven_day.resets_at`.
- Codex: newest `rollout-*.jsonl` under `~/.codex/sessions` whose last `"rate_limits"` has a non null `primary`: `primary.used_percent`, `primary.window_minutes`, `primary.resets_at` (epoch seconds), same for `secondary`, plus `plan_type`. Files whose rate_limits carry only `credits` (limit_id "premium") are skipped; at most 30 newest files are scanned.
- Antigravity: subprocess `antigravity-usage quota --json` (node script under nvm; PATH gets the script's directory prepended). `models[]` with `label`, `modelId`, `remainingPercentage` (0...1), `resetTime` (ISO 8601), `isAutocompleteOnly`; `email`.
- Z.ai: key from `~/.local/share/opencode/auth.json` at `["zai-coding-plan"]["key"]`, GET `https://api.z.ai/api/monitor/usage/quota/limit` with `Authorization: Bearer`. `data.level` and `data.limits[]` with `type` (`TOKENS_LIMIT` kept, others skipped), `unit` (3 = 5h, 6 = 7d), `percentage`, `nextResetTime` (epoch ms).

Core contract (`Sources/LLMOpsCore/Quotas.swift`):

```swift
public enum QuotaProviderID: String, CaseIterable, Sendable, Codable { case claude, codex, antigravity, zai }
public struct QuotaWindow: Equatable, Sendable, Codable { public let label: String; public let usedPercent: Double; public let resetsAt: Date? }
public struct QuotaSnapshot: Equatable, Sendable {
    public let provider: QuotaProviderID; public let windows: [QuotaWindow]; public let fetchedAt: Date; public let detail: String?
    public var worstUsedPercent: Double?   // max over windows
}
public enum QuotaError: Error, Equatable { case missingCredential(String); case network(String); case badPayload(String); case notFound(String); case subprocess(String) }
public protocol QuotaProvider: Sendable { var id: QuotaProviderID { get }; func fetch(now: Date) async throws -> QuotaSnapshot }
```

Parsers are pure and separately testable (`ClaudeQuotaParser`, `CodexQuotaParser`, `AntigravityQuotaParser`, `ZaiQuotaParser`); providers wrap them with injectable loaders (token loader, sessions directory, subprocess runner, URLSession).

Screen: `Route.quotas` between `system` and `settings`. `QuotaState` holds one `Result<QuotaSnapshot, Error>` per provider, refreshes every 300 s while the app runs (not only while visible, so the sidebar line stays current) and on a `refresh` button. Four `EvidenceCard`s in a 2x2 grid: provider name as eyebrow, one row per window with label, a horizontal bar (magenta below 80%, magentaBright at or above), `NN%` and `resets in 2h 10m`; detail line (plan, email) in mono dim; an error card shows the mapped error in magenta mono without hiding the other three. Antigravity lists only Gemini 3.x and Claude models (not autocomplete), and its hero number is the worst of them. Sidebar: under the route list, a mono line `claude 53  codex 82  agy 24  zai 22` with the 5 h (or worst) used percent, dim, `--` when unknown.

Settings: `antigravityUsagePath` (default: newest `~/.nvm/versions/node/*/bin/antigravity-usage`, else `/usr/local/bin/antigravity-usage`), `zaiAuthPath` (default `~/.local/share/opencode/auth.json`), both as text fields in a `quotas` card.

## S7. Notch popup for permission and question requests (approved 2026-09-14)

Owner request: stop activating the app on requests; show a popup at the notch, like the original CodeIsland, with the options.

- `NotchPanelController` (`Sources/LLMOps/NotchPanel.swift`, `@MainActor`): one borderless `NSPanel` with `.nonactivatingPanel`, `isFloatingPanel`, level `CGWindowLevelForKey(.mainMenuWindow) + 2`, `collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`, `hidesOnDeactivate false`, clear background, no shadow. Content: `NSHostingView` of `NotchPanelView(model:)`, a `VStack` of `PermissionCard`s for `model.live.pending` (max 3, oldest first) inside a surface colored rounded container 420 wide. Position: horizontally centered on the screen that has a notch (`safeAreaInsets.top > 0`), else `NSScreen.main`; top edge at `screen.frame.maxY - topInset`, where `topInset` is `safeAreaInsets.top` on notch screens and the menu bar height (`frame.maxY - visibleFrame.maxY`) otherwise. Re-positioned on `didChangeScreenParametersNotification`.
- Visibility follows `model.live.pending.isEmpty` through `withObservationTracking` re-armed on every change (same pattern as CodeIsland's `armSessionObservation`): `orderFrontRegardless` when non empty, `orderOut` when empty. Never `activate`s the app.
- Settings: `bringToFrontOnRequest: Bool` is replaced by `requestPresentation: RequestPresentation` (`enum: String { notch, front, none }`, key `llmops.live.requestPresentation`, default `notch`; a legacy stored `bringToFrontOnRequest == false` maps to `none` when no new key exists). `AppModel.presentRequest()` switches: `.notch` does nothing extra (the controller reacts to `pending`), `.front` calls `activator()`, `.none` nothing. Settings UI: a segmented picker `notch popup / bring app to front / nothing` in the `live` card replacing the toggle.
- Tests: `NotchPanelControllerTests` with an injected `LiveStore` (pending added via the store API): panel `isVisible` becomes true after a pending item, false after `resolve`; frame origin x equals the screen center minus half the width; the panel style mask contains `.nonactivatingPanel`. `LLMOpsSettings` tests for the enum default and the legacy mapping. `AppModelTests`: `.front` calls the injected activator, `.notch` and `.none` do not.

Out of scope: notch for metrics or sounds, per provider multiple accounts, quota alerts.
- S6 landed as 90cd1be (providers) and the quotas screen commit; S7 as 6f7d398. 202 tests in 20 suites. Sound report root cause (bf4c004): the test bundle played the real wavs through SoundManager fixtures; the app never played while disabled.

## S8. WidgetKit widgets: quotas, today, system (approved 2026-09-16)

Spike (2026-09-15 and 16), all without Xcode, CommandLineTools only:
- The appex builds with `swiftc -parse-as-library -application-extension -framework WidgetKit
  -framework SwiftUI -Xlinker -e -Xlinker _NSExtensionMain`. Without the `_NSExtensionMain` entry
  point the process exits 0 right after launch and chronod never gets widget descriptors (the widget
  gallery then lists the app with no widgets). Bundle laid out by hand, `NSExtensionPointIdentifier`
  `com.apple.widgetkit-extension`, ad-hoc `codesign`, appex entitlement `com.apple.security.app-sandbox`.
- Descriptors are fetched only when the widget gallery opens ("host requested: NotificationCenter");
  chronod restarts do not fetch them for non-Apple extensions. Bump `CFBundleVersion` on every build so
  the gallery refetches.
- Data path: with an ad-hoc signature (no Team ID) the sandboxed appex resolves the App Group container
  but the read is denied. It does read its own container, so the app (not sandboxed) writes
  `~/Library/Containers/<appex bundle id>/Data/Library/Application Support/snapshot.json` and the
  widget reads `FileManager.urls(for: .applicationSupportDirectory)` from inside the sandbox. No App
  Group entitlement anywhere.

### Contract
- LLMOpsCore: `WidgetSnapshot: Codable, Equatable` with `writtenAt: Date`, `quotas: [QuotaWindow]`
  keyed per provider (`provider: QuotaProviderID, label, usedPercent, resetsAt`), `today: TodaySummary`
  (`sessions: Int, tokens: Int, costUSD: Double`), `system: SystemSummary` (`cpuPercent, memoryUsedPercent,
  batteryPercent: Double?`). `WidgetSnapshotStore(directory: URL)`: `write(_:)` atomic, `read()` nil on
  missing or undecodable. Default directory is the appex container path above for bundle id
  `dev.samdev.llmops.widgets`.
- App: writes after every quota refresh, every LiveStore tick that changes today totals and every
  SystemSampler tick, then `WidgetCenter.shared.reloadAllTimelines()`.
- Appex target `LLMOpsWidgets` (executable product): three `StaticConfiguration` widgets, kinds
  `quotas`, `today`, `system`, families systemSmall and systemMedium, timeline policy
  `.after(now + 15 min)` as fallback, mono font, Theme tokens, no `.shadow`, no `.blur`, plain hyphen.
  Missing snapshot renders `no data, open LLMOps`.
- build.sh: compile the appex with the flags above, lay out `Contents/PlugIns/LLMOpsWidgets.appex`
  with its Info.plist (bundle id `dev.samdev.llmops.widgets`, `CFBundleVersion` = build timestamp),
  sign appex with the sandbox entitlement, then the app.

### Tasks (agy, one clone per task)
- W1: `WidgetSnapshot`, `TodaySummary`, `SystemSummary`, `WidgetSnapshotStore` + tests (core only).
- W2: app plumbing: snapshot builders from existing models, writers on the three triggers,
  `reloadAllTimelines`, AppModel tests with a fake store directory.
- W3: appex target with the three views, Info.plist, build.sh changes. Host validates by installing the
  bundle, opening the gallery and adding one widget.

### Out of scope
Interactive widgets, configurable intents, lock screen, Team ID signing, App Group.

## S9. Widgets v2: quotas per subscription, LLMOps identity (approved 2026-09-16)

Owner feedback on S8: the quotas widget must group by subscription (provider) and all three widgets
must look like LLMOps, not like a debug print. Design authority: `~/.claude/design-stack/impeccable.md`
(tinted neutrals, one locked accent, calm finish). The widgets mirror the app's `Theme` by hex because
the appex cannot import the app target.

### Shared chrome (`WidgetChrome`)
- Background `#0B0A0E` via `containerBackground(for: .widget)`; an inner 1 pt hairline `#2C2738`
  rounded 10 around the content, padding 10.
- Eyebrow top-left: widget name in mono 9, uppercase, tracking 1.2, `#9B93AD`.
- Footer bottom-right: `writtenAt` as `HH:mm` mono 9, `#857F99`.
- Text `#ECE8F2`, dim `#9B93AD`, muted `#857F99`, accent `#9D7AE8`, accent bright `#DDA8FF`,
  cyan `#4EC9E8`, track `#2C2738`. Monospaced system font everywhere. No gradient, no shadow, no
  blur, no emoji, plain hyphen only.
- Bars: `Capsule` track `#2C2738` height 4, fill `#9D7AE8` below 80 percent and `#DDA8FF` at or above.
- Empty state: eyebrow plus `no data` in dim and `open LLMOps` in muted, nothing else.

### Quotas
- Grouped by provider in `QuotaProviderID.allCases` order; providers without quotas are hidden.
- Small: one row per provider (max 5): provider name mono 10 `#DDA8FF` left, bar in the middle,
  worst `NN%` mono 10 right. Provider names: `claude`, `codex`, `agy`, `z.ai`, `openrouter`.
- Medium: two columns of provider blocks; each block: provider name, then one line per window with
  `label` (5h, 7d, credits...) dim, a bar, `NN%`, and `resets 2h 10m` muted when `resetsAt` is in the
  future (`WidgetFormat.resetsIn`), max 3 windows per provider.

### Today
- Small: eyebrow `today`; hero number = cost as `$12.34` mono 24 `#ECE8F2`; below, `N sessions`
  and `N tokens` (grouped) dim mono 10 on one line each.
- Medium: three stat tiles side by side (`cost`, `sessions`, `tokens`), each eyebrow-style label
  above a mono 20 value; a hairline separates tiles.

### System
- Small: three rows `cpu`, `mem`, `bat`, each with the label dim, a bar and the value; cpu bar is
  cyan, mem accent, bat accent bright; `bat -` and an empty track when nil.
- Medium: same rows with more width, plus the value in mono 14 on the right.

### Core helpers (testable, `WidgetFormat`)
- `resetsIn(_ date: Date?, now: Date) -> String?`: nil when date is nil or not after now; `"2h 10m"`,
  `"45m"`, `"3d 4h"` otherwise.
- `grouped(_ quotas: [WidgetQuota]) -> [(provider: QuotaProviderID, quotas: [WidgetQuota])]` in
  allCases order, empty providers dropped.
- `worstPercent(_ quotas: [WidgetQuota]) -> Double` = max usedPercent, 0 for empty.
- `providerName(_ id: QuotaProviderID) -> String` mapping antigravity to `agy`, others rawValue.
