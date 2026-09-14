# LLMOps for macOS: design spec and task plan

Status: approved by the owner on 2026-09-13. Source of truth for the `LLMOps/` package on branch `llmops`. Deviations from the original plan file are listed under "Amendments".

## Context

`~/dev/LLMOps` was produced by agy from `docs/plans/2026-09-13-activity-history-llmops.md`. Audit result: the React/Tauri app reads the wrong file (`~/.claude/history.jsonl`, which has no tokens), fabricates every metric it cannot find, and adds 3 hardcoded panels, a fake MCP server and a fake CLI outside the plan. Roughly 40% adherent, 0% real.

The owner's actual goal: a **native macOS desktop app** that (1) shows real Claude Code telemetry (tokens, cache, cost, tool calls, subscription window) and (2) replaces the two CodeIsland features they use: live session status and permission approval, plus sounds. A dedicated tab for the Afya agent (Claude running inside Zed with `CLAUDE_CONFIG_DIR=~/.claude-zed`).

Decisions locked in the brainstorm:

- Swift/SwiftUI, not Tauri. Reason: reuse, not "not for sale". `~/dev/learning/CodeIsland` (fork of `wxtsky/CodeIsland`, branch `main`, 1 commit ahead of upstream, 2 dirty files: `ConfigInstaller.swift`, `UpdateChecker.swift`) already has in Swift: `HookServer` (619 lines), pure reducer `reduceEvent` in `CodeIslandCore/SessionSnapshot.swift:761`, `ClaudeUsageScanner` (5h window, dedupe on `message.id`, incremental per-file `consumedBytes`), `JSONLTailer`, `SoundManager` + 6 `.wav`.
- New executable target `LLMOps` inside the fork repo on branch `llmops`, depending on `CodeIslandCore`. `AppState.swift` (4922 lines), mascots, ESP32, iOS/Watch, remote SSH, Sparkle, Yams: not included.
- v1 covers Claude Code only. Codex and agy rails are v2.
- Features v1: live sessions + permissions + questions, sounds, history feed with filters and tool-call trace, analytics (tokens, cost estimate, 5h window). Dropped: prompt diff, replay, jump-to-terminal, notch UI.
- Design system: `~/dev/lp/skill-issue-lp/DESIGN.md` ("Skill Issue" / Cold Manifesto). Flat, no shadows, magenta `#9D7AE8` for action and cost, cyan `#4EC9E8` for exactly one hero number per screen, JetBrains Mono for every label/number/log line, Space Grotesk headlines, IBM Plex Sans body, 6px/14px radii, 1px `#2C2738` hairline. No em dashes in any rendered copy.
- Executor: agy (Gemini) via `agy:agy-executor`, Claude orchestrates, validates on host, reviews, commits. `~/dev/LLMOps` gets archived after v1 runs.

## Spec

### S1. Data sources and model

Source of truth for history: `<configDir>/projects/<slug>/<sessionId>.jsonl` for each profile. Verified format (both `~/.claude` and `~/.claude-zed`):

- `type: assistant` lines carry `message.model`, `message.id`, `message.usage { input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens_details.thinking_tokens }`, and `message.content[]` with `text`, `thinking`, `tool_use { id, name, input }` blocks.
- `type: user` lines carry the prompt text or `tool_result { tool_use_id, content, is_error }`.
- Continuation lines of one API response repeat `message.id`: usage must be deduped on it (same rule as `ClaudeUsageScanner`).
- First lines carry `cwd`, `sessionId`, `version`, `entrypoint`.

Model exposed to the UI (in `LLMOpsCore`):

```swift
struct Profile: Identifiable, Codable { id: String; name: String; configDir: String; pathPrefixes: [String] }
struct Session: Identifiable { id: String; profile: String; project: String; cwd: String; model: String
                                startedAt: Date; lastActivity: Date; turns: [Turn]; usage: ClaudeUsageTotals; costUSD: Double }
struct Turn: Identifiable { id: String; ts: Date; model: String; userPrompt: String?; assistantText: String?
                             usage: ClaudeUsageTotals; toolCalls: [ToolCall] }
struct ToolCall: Identifiable { id: String; name: String; inputSummary: String; durationMs: Int?; isError: Bool }
```

`ToolCall` is the span. Flat list, no nesting (subagents are separate JSONL files). `durationMs` = `tool_result` timestamp minus `tool_use` timestamp, nil when the result never arrived. `costUSD` from a single editable price table keyed by model id, labeled "estimate" everywhere it is shown. Anything absent from the JSONL (API latency, eval scores) is never displayed.

### S2. Live monitor

- Server binds `SocketPath.path` (`/tmp/codeisland-<uid>.sock`, env override `CODEISLAND_SOCKET_PATH`). The 12 hooks already in `~/.claude/settings.json` (symlinked from `~/.claude-zed/settings.json`) keep pointing at `~/.codeisland/codeisland-hook.sh` -> `codeisland-bridge`. Zero config change. Running the original CodeIsland at the same time is not supported in v1.
- `HookServer` is copied into the app target and decoupled: `AppState` replaced by a `HookSink` protocol (`handle(event)`, `permissionRequested(event, reply)`, `questionAsked(event, reply)`, `peerDisconnected(sessionId)`); `SettingsManager.shared` calls replaced by a `HookServerConfig` struct (`autoApproveTools`, `excludedCwdSubstrings`); webhook forwarding, Codex app-server, terminal detection removed.
- `LiveStore` (`@Observable`, `@MainActor`) implements `HookSink`, delegates to `reduceEvent(sessions:event:maxHistory:)` and executes the returned `SideEffect`s it cares about (`playSound`, `removeSession`). It tags each session with a profile by matching `cwd` against `Profile.pathPrefixes`, falling back to the first profile.
- Permission flow: `PermissionRequest` keeps the `NWConnection` open; store publishes `PendingPermission { id, sessionId, toolName, toolDescription, reply: (Decision) -> Void }`. UI Allow (primary magenta) / Deny (ghost). If no click within 110 s the store replies `deny` so Claude Code falls back to its terminal prompt before the bridge's 120 s deadline. `AskUserQuestion` / `Notification` with `QuestionPayload.from(event:)` follows the same path with option buttons; reply JSON matches what `HookServer.swift` already emits.
- Session end: `SessionEnd` or peer disconnect marks the session ended; it leaves the live list after 60 s.
- Sounds: `SoundManager.swift` and the six `8bit_*.wav` copied verbatim except `SettingsKey` references, which move to `LLMOpsSettings`. Per-event toggles, boot sound and quiet hours preserved.

### S3. Profiles and the Afya tab

- A profile is one `CLAUDE_CONFIG_DIR`. Defaults on first launch: `pessoal` -> `~/.claude`, `afya` -> `~/.claude-zed` with `pathPrefixes: ["~/dev/afya"]`. Editable in Settings, persisted in `UserDefaults` as JSON.
- History scanner loops over every profile's `projects/`. Live events resolve profile by `cwd` prefix. Any Claude Code process working under `~/dev/afya` (Zed or terminal) lands in the Afya tab; that is the intended semantics ("Afya work", not "Zed process").
- The Afya tab is the same three views filtered by `profile == afya`. Its hero cyan number is estimated cost for the current ISO week. No third accent color; the mono `tag-pill` reading `afya` marks it.
- Nothing is written outside `~/Library/Application Support/LLMOps` and `UserDefaults`. No export, no webhook, no network in v1.

### S4. Screens and navigation

Single window, `NavigationSplitView`. Sidebar in terminal style: `~ $ llmops` prompt on top, then a profile switcher (`all`, `pessoal`, `afya`) rendered as tag-pills, then four destinations as mono labels: `live`, `history`, `analytics`, `settings`.

- **Live**: pending permission/question cards pinned at top (surface card, tool name + description in mono, Allow/Deny). Below, one card per active session: title (`SessionSnapshot.displayTitle`), project basename, status dot (idle/processing/running/waitingApproval/waitingQuestion), current tool, last user prompt (2 lines max), elapsed since `startTime`, subagent count. Empty state: `// no active sessions`.
- **History**: filter bar (profile pills, project picker, model picker, date range, search over prompt text) + list of sessions (newest first) showing project, model, turns, total tokens, cache read ratio, cost estimate, start time. Clicking opens an inspector: session header with the four token totals as labeled metrics, then turns in order, each expandable to show prompt, response text and the tool-call list as horizontal duration bars (the trace).
- **Analytics**: hero metric card (cyan) = output tokens in the last 5 h with the `ClaudeUsageScanner` sparkline; second metric card (magenta) = cost estimate for today. Then Swift Charts: tokens per day (last 30 days, stacked input/output/cache), tokens by project (top 8), tokens by model, cache read ratio over time. Every card carries a source line (`src: ~/.claude/projects, n=<sessions>`), per the No Bare Number rule.
- **Settings**: profiles table (name, config dir, path prefixes, add/remove), sounds (enable, per-event, boot, quiet hours with previews), auto-approve tool list, excluded cwd substrings.

Design tokens live in one file (`Theme.swift`): `Color` and `Font` statics from DESIGN.md, `EvidenceCard`, `TagPill`, `PrimaryButton`, `GhostButton`, `MetricLine` view modifiers. Fonts bundled as SwiftPM resources under `Sources/LLMOps/Resources/Fonts/` (OFL) and registered at launch with `CTFontManagerRegisterFontsForURL` (no Info.plist dependency, works under `swift run` too). No `.shadow()` anywhere; a test greps the target for `.shadow(` and fails if found.

### S5. Testing and build

- `LLMOpsCore` is a library target with XCTest coverage (`Tests/LLMOpsCoreTests`), following the fixture style of `Tests/CodeIslandCoreTests/ClaudeUsageScannerTests.swift` (temp dir, synthesized JSONL lines).
- `HookServer` gets an integration test: bind a temp socket via `CODEISLAND_SOCKET_PATH`, connect with a `NWConnection` client, send a `PermissionRequest` payload, assert the JSON reply after the store decides, and assert the 110 s timeout path using an injected clock.
- `swift build` and `swift test` must pass for the whole package (existing CodeIsland tests included) on every commit. Gate command: `swift test 2>&1 | tail -5`.
- `build-llmops.sh` (derived from `build.sh`, macOS only) produces `.build/release/LLMOps.app` with `Info.plist` and icon; `open` it as the final acceptance.
- Manual acceptance checklist (owner, after Task 12): start the app, run `claude` in a terminal, see the session appear, trigger a permission, approve from the app, hear the sound; open Zed Afya agent, confirm it shows under `afya`; History lists today's sessions with non-zero tokens matching `ccusage`-style totals within dedupe tolerance; Analytics 5 h number matches CodeIsland's for the same moment.

## Task breakdown

Each task is one agy dispatch (roughly 1 to 3 h of executor work), TDD, one signed commit on branch `llmops` in `~/dev/learning/CodeIsland`. Done criteria are host-verified, never taken from agy's narration. Dependencies flow top to bottom; tasks inside a batch are independent of each other except where noted.

agy quota is about 4 to 5 heavy dispatches per 5 h window, so the 12 tasks are grouped in 3 batches. Task 0 is done by the orchestrator, not agy, to fix the skeleton before any executor touches it.

### Task 0 (orchestrator): branch and skeleton

- 0.1 `git stash` or commit the two dirty files on `main` (owner decides), `git checkout -b llmops`.
- 0.2 `Package.swift`: add `.target(name: "LLMOpsCore", dependencies: ["CodeIslandCore"], path: "Sources/LLMOpsCore")`, `.executableTarget(name: "LLMOps", dependencies: ["LLMOpsCore", "CodeIslandCore"], path: "Sources/LLMOps", resources: [.copy("Resources")])`, `.testTarget(name: "LLMOpsCoreTests", ...)`, `.testTarget(name: "LLMOpsAppTests", dependencies: ["LLMOps"])`.
- 0.3 `Sources/LLMOps/LLMOpsApp.swift`: `@main App` with an empty `NavigationSplitView`, `Sources/LLMOps/Resources/Fonts/` with the 3 font families (OFL, downloaded once), `FontRegistrar.swift` calling `CTFontManagerRegisterFontsForURL` at launch.
- 0.4 `Sources/LLMOps/Info.plist` (`LSUIElement` false, bundle id `dev.samdev.llmops`), `build-llmops.sh`.
- Done: `swift build` green, `swift test` green (existing suites), `swift run LLMOps` opens a window titled `llmops` rendering `~ $ llmops` in JetBrains Mono. Commit `chore(llmops): scaffold LLMOps target`.

### Batch 1 (Core, no UI)

**Task 1: Profile model and resolver** (`Sources/LLMOpsCore/Profile.swift`)
- 1.1 `Profile` struct, `Codable`, `~` expansion in `configDir` and `pathPrefixes`.
- 1.2 `ProfileStore`: load/save `[Profile]` from `UserDefaults` key `llmops.profiles.v1`; `defaults()` returns `pessoal` + `afya` as in S3.
- 1.3 `ProfileResolver.resolve(cwd:) -> Profile`: longest matching prefix wins; fallback first profile.
- Done: tests for expansion, longest-prefix, fallback, round-trip encoding. `swift test --filter LLMOpsCoreTests.ProfileTests` green.

**Task 2: TranscriptScanner** (`Sources/LLMOpsCore/TranscriptScanner.swift`)
- 2.1 `parseLine(_:) -> TranscriptLine?` for `assistant`, `user`, and metadata lines; reuse `ClaudeUsageScanner.parseAssistantUsage` for usage.
- 2.2 `buildSession(lines:profile:) -> Session`: groups into `Turn`s (a turn starts at each non-tool-result `user` line), dedupes usage on `message.id`, pairs `tool_use.id` with `tool_result.tool_use_id` for `durationMs` and `isError`, `inputSummary` via `HookEvent`-style rules (Bash: command, Read/Edit/Write: basename, others: first 80 chars of JSON).
- 2.3 `scan(profiles:cache:) -> [Session]` walking `<configDir>/projects/**/*.jsonl`, incremental per-file byte offsets like `ClaudeUsageScanner.FileCache`, skipping files unchanged by `mtime` + size.
- Done: tests with synthesized JSONL covering dedupe, tool pairing, missing tool_result, two profiles, incremental rescan reading only appended bytes (assert via consumed byte count). Bench test: 2,000 synthetic sessions scan under 2 s.

**Task 3: Cost and aggregates** (`Sources/LLMOpsCore/CostTable.swift`, `Aggregates.swift`)
- 3.1 `CostTable`: `[modelId: (inputPerM, outputPerM, cacheWritePerM, cacheReadPerM)]` with Claude 5 family, Haiku 4.5, and a wildcard fallback; `cost(for: ClaudeUsageTotals, model:) -> Double`. Table lives in one file with a header comment saying it is an estimate to maintain by hand.
- 3.2 `Aggregates`: `perDay(sessions, days: 30)`, `perProject(top: 8)`, `perModel`, `cacheReadRatio(perDay)`, `weekCost(profile:)`, `todayCost`.
- 3.3 `WindowUsage.snapshot(profiles:)`: calls `ClaudeUsageScanner.scan(claudeHome:now:cache:)` per profile and sums.
- Done: tests with fixed sessions asserting each aggregate; unknown model falls to wildcard and is flagged `isEstimateFallback`.

**Task 4: LiveStore** (`Sources/LLMOpsCore/LiveStore.swift`, `HookSink.swift`, `PendingPermission.swift`)
- 4.1 `HookSink` protocol as in S2. `Decision` enum `allow | deny | answer(String)`.
- 4.2 `LiveStore`: `sessions: [String: SessionSnapshot]`, `pending: [PendingPermission]`, `profileOf: [sessionId: String]`; `handle(event)` calls `reduceEvent` then applies effects; `peerDisconnected` marks ended; ended sessions purged after 60 s (injected clock).
- 4.3 Permission timeout 110 s with injected `Clock`; `resolve(id:decision:)` calls the reply exactly once (second call ignored).
- 4.4 `SoundEvents` output: store exposes `onSound: (String) -> Void` fed by `SideEffect.playSound` and by `PermissionRequest`.
- Done: tests for status transitions on SessionStart/PreToolUse/PostToolUse/Stop, permission resolve once, timeout deny, purge after 60 s, profile tagging by cwd, sound callback fired.

### Batch 2 (server, sounds, shell)

**Task 5: HookServer port** (`Sources/LLMOps/HookServer.swift`, `Tests/LLMOpsAppTests/HookServerTests.swift`)
- 5.1 Copy `Sources/CodeIsland/HookServer.swift`; replace `appState` with `sink: HookSink`, `SettingsManager.shared.*` with `HookServerConfig`; delete webhook, Codex app-server, plugin `_ppid` handling, remote host branches.
- 5.2 Keep: umask 0o077, socket cleanup on start/stop, max payload guard, `receiveAll`, `PermissionRequest` connection hold, reply JSON strings.
- 5.3 Integration test via `CODEISLAND_SOCKET_PATH` temp socket: SessionStart round trip returns `{}` fast; PermissionRequest waits and returns allow after `store.resolve`.
- Done: test green; `swift run LLMOps` with `claude` running in a terminal shows events in the console log (`os_log` category `HookServer`).

**Task 6: SoundManager port and settings** (`Sources/LLMOps/SoundManager.swift`, `LLMOpsSettings.swift`, `Resources/*.wav`)
- 6.1 Copy `SoundManager.swift` and the 6 `.wav`; `SettingsKey.sound*` -> `LLMOpsSettings.Key`; strings in English.
- 6.2 `LLMOpsSettings`: `UserDefaults`-backed `@Observable` with sounds, quiet hours, `autoApproveTools`, `excludedCwdSubstrings`.
- 6.3 Wire `LiveStore.onSound` -> `SoundManager.handleEvent`.
- Done: unit test for `isInQuietHours` boundaries (copied), settings round trip; manual: boot sound plays on launch when enabled.

**Task 7: Theme and app shell** (`Sources/LLMOps/Theme.swift`, `Components.swift`, `Sidebar.swift`, `AppModel.swift`)
- 7.1 `Theme`: colors and fonts from DESIGN.md as statics; `Font.display/headline/body/label/metric` using the bundled families with system fallbacks.
- 7.2 Components: `EvidenceCard`, `TagPill`, `PrimaryButton`, `GhostButton`, `MetricLine(value:label:)`, `SourceLine(text:)`, `StatusDot(status:)`.
- 7.3 `AppModel`: owns `ProfileStore`, `LiveStore`, `HookServer`, `TranscriptScanner` cache, rescans on a 30 s timer and on `SessionEnd`; exposes `selectedProfile: String?` (`nil` = all).
- 7.4 Sidebar per S4; four empty destination views wired.
- Done: `Tests/LLMOpsAppTests/ThemeTests.swift` asserts hex values match DESIGN.md and a source scan of `Sources/LLMOps` finds no `.shadow(` and no em dash (U+2014) or en dash (U+2013) in string literals. `swift run` shows the sidebar with all four routes.

**Task 8: Live view** (`Sources/LLMOps/LiveView.swift`, `PermissionCard.swift`, `SessionCard.swift`)
- 8.1 Permission and question cards per S4, Allow/Deny/option buttons call `store.resolve`.
- 8.2 Session cards per S4, filtered by `selectedProfile`.
- 8.3 Empty state copy `// no active sessions`.
- Done: `LiveViewModelTests` asserts filtering and ordering (pending first, then by lastActivity). Manual: approve a real `Bash` permission from the app.

### Batch 3 (history, analytics, settings, acceptance)

**Task 9: History view and inspector** (`HistoryView.swift`, `HistoryFilter.swift`, `SessionInspector.swift`, `ToolTraceView.swift`)
- 9.1 `HistoryFilter` (pure): profile, project, model, date range, search over `userPrompt`; unit tested.
- 9.2 List rows per S4; inspector with metric lines and turns; `ToolTraceView` draws duration bars scaled to the longest call, error bars in magenta-deep, missing duration as a hairline outline.
- Done: filter tests green; manual: open today's session, see the tool calls of this planning session.

**Task 10: Analytics view** (`AnalyticsView.swift`, `Charts/*.swift`)
- 10.1 Hero card (cyan) 5 h output tokens with sparkline from `WindowUsage`; second card (magenta) today's cost estimate.
- 10.2 Four Swift Charts per S4, each in an `EvidenceCard` with `SourceLine`.
- 10.3 Chart colors: magenta series primary, cyan only on the hero sparkline, other series in `text-dim`/`text-mut` steps. No gradients.
- Done: `AnalyticsViewModelTests` asserts series shapes from fixed sessions; manual: numbers for the current 5 h match CodeIsland's panel within 1%.

**Task 11: Settings view** (`SettingsView.swift`)
- 11.1 Profiles editor bound to `ProfileStore` with add/remove and path prefix list.
- 11.2 Sounds section with per-event toggles and preview buttons; quiet hours.
- 11.3 Auto-approve tools and excluded cwd substrings.
- Done: changes persist across relaunch (test via `UserDefaults` suite injection); manual: add a prefix, see a live session move profile on its next event.

**Task 12: Afya end to end, bundle, acceptance** (orchestrator + owner)
- 12.1 First-launch defaults create the `afya` profile; History for `afya` lists the 12 JSONL under `~/.claude-zed/projects/-Users-samdev-dev-afya*`.
- 12.2 `./build-llmops.sh` produces `LLMOps.app`; launch from Finder; run the S5 manual checklist with the owner.
- 12.3 Archive `~/dev/LLMOps`: move the audit and this spec's pointer into `~/dev/learning/CodeIsland/docs/superpowers/specs/2026-09-13-llmops-mac-design.md`; delete or `mv ~/dev/LLMOps ~/dev/archive/LLMOps-tauri-2026-09-13`.
- Done: checklist signed off by the owner; tag `llmops-v1.0.0` on the branch; PR `llmops -> main` opened, never merged by the lane.

## Execution protocol (agy)

- Load `agy:agy-executor` for every dispatch. Pre-flight: `antigravity-usage` quota, run sandbox-disabled.
- Model: `Gemini 3.8 Flash (Medium)` (id `gemini-3.8-flash-medium`, confirmed verbatim in `agy models` on 2026-09-13) for every task. Flash is lighter on quota than 3.1 Pro, so batches may fit more than 4 dispatches per window; re-check `antigravity-usage` after each batch instead of assuming. Escalate a single task to `Gemini 3.8 Flash (High)` only after a red host validation on Medium; a second failure means the orchestrator implements it.
- Containment: throwaway clone per task (`git clone --no-hardlinks ~/dev/learning/CodeIsland "$SCRATCH/agy-taskN" && git checkout llmops`). Briefs name files by relative path only, never an absolute path. This repo is a git repo, which the lane requires.
- Brief template from `agy-executor/REFERENCE.md`: repo + branch, the task's subtasks and done criteria verbatim, files to read first (`Sources/CodeIslandCore/SessionSnapshot.swift`, `Sources/CodeIslandCore/ClaudeUsageScanner.swift`, `Sources/CodeIsland/HookServer.swift`, `Tests/CodeIslandCoreTests/ClaudeUsageScannerTests.swift`, `Sources/LLMOps/Theme.swift` for UI tasks), TDD order, gate `swift test`, constraints: English only, plain hyphen only, no commit, no files outside the task's list, final message lists changed files.
- Host validation per task: `git diff --stat` in the clone non-empty; copy diff back with `git diff | git apply` in the real worktree; `swift build && swift test`; `grep -rn $'—\|–' Sources/LLMOps*` empty; `git status` shows only expected files.
- Review gate: `swift` has no dedicated reviewer agent here; use `general-purpose` with the task contract, focusing on: reuse of `CodeIslandCore` instead of reimplementation, `@MainActor` correctness on `LiveStore`, reply-once guarantee on permissions, no `.shadow`.
- Adversarial self-check before each commit: flip one assertion-critical line (dedupe on `message.id`, timeout duration, prefix match) via Edit, confirm the new tests fail, revert via Edit. Never `git checkout -- <file>`.
- One signed commit per task, message in English, `Lesson:` trailer when a probe teaches something about agy on Swift.
- Second consecutive agy failure on a task: orchestrator implements it directly and records the decision.
- Batches: 1 = Tasks 1 to 4, 2 = Tasks 5 to 8, 3 = Tasks 9 to 11, then Task 12 with the owner. Expect one 5 h quota window per batch; on exhaustion commit what passed and report the reset time.

## Verification (end to end)

1. `cd ~/dev/learning/CodeIsland && swift test 2>&1 | tail -5` green, including pre-existing CodeIsland suites.
2. `swift run LLMOps`, then in another terminal `claude` inside `~/dev/axon`: session card appears under `pessoal` within 1 s of `SessionStart`; run a command needing permission; approve from the app; the terminal proceeds; approval sound plays.
3. Open Zed, send a prompt to the Afya agent: session appears under `afya`.
4. History > `afya`: 12 sessions from `~/.claude-zed/projects/-Users-samdev-dev-afya*` with non-zero `cache_read` totals; inspector shows tool calls with durations.
5. Analytics: 5 h output tokens equals the value CodeIsland shows (same scanner) within 1%; today's cost card shows the `estimate` label and the source line.
6. `./build-llmops.sh` yields `.build/release/LLMOps.app`; launch from Finder; hooks still resolve (`ls -l /tmp/codeisland-$(id -u).sock` owned by the app's pid).
7. `grep -rn $'—' Sources/LLMOps* Sources/LLMOpsCore*` returns nothing; `grep -rn '\.shadow(' Sources/LLMOps` returns nothing.

## Out of scope for v1

Codex and agy rails, jump-to-terminal, notch/floating window, prompt diff, replay, iPhone/Watch companion, ESP32, remote hosts, webhook export, Langfuse/LangSmith/LangWatch bridges, auto-update (Sparkle).

## Amendments (Task 0, 2026-09-13)

- **Nested package, not new targets in the parent.** LLMOps lives in `LLMOps/Package.swift` and depends on the parent through `.package(name: "CodeIsland", path: "..")`; the parent now declares the `CodeIslandCore` library product. Reason: this machine has CommandLineTools only (no Xcode.app), so the parent's XCTest suites and the Sparkle xcframework cannot build here, and `swift test` compiles every test target in a package.
- **swift-testing, not XCTest.** New tests use `import Testing`, `@Test`, `#expect`, `#require`. XCTest is not shipped with CommandLineTools. Fixture approach (temp dir, synthesized JSONL) is unchanged.
- **Gate is `LLMOps/test.sh`**, which encodes `--build-system native` plus the `-F` path to the CLT `Testing.framework`. `LLMOps/build.sh` produces `LLMOps/.build/release/LLMOps.app`. Every "swift test" mention above means `./test.sh` run inside `LLMOps/`.
- Paths in the task list map as: `Sources/LLMOpsCore/*` -> `LLMOps/Sources/LLMOpsCore/*`, `Sources/LLMOps/*` -> `LLMOps/Sources/LLMOps/*`, `Tests/LLMOps*` -> `LLMOps/Tests/LLMOps*`. Fonts ship in `LLMOps/Sources/LLMOps/Resources/Fonts/` (JetBrains Mono Regular/Medium/SemiBold/Bold, Space Grotesk Medium/Bold, IBM Plex Sans Regular/Medium/SemiBold, OFL licenses alongside).
- `FontRegistrar` registers the bundled TTFs via `CTFontManagerRegisterFontsForURL(..., .process, nil)` at app init.

## Amendments (Batch 2, 2026-09-13)

- **No SwiftUI macros.** The CommandLineTools toolchain ships `libObservationMacros` and `libSwiftMacros` only; `SwiftUIMacros` is absent, so `@State`, `@Bindable`, `@Environment(Observable)` and any other macro-backed SwiftUI wrapper fail to compile ("plugin for module 'SwiftUIMacros' not found"). Rules for every UI task: hold `@Observable` models as plain `let`/`var` references (reads are still tracked), build two-way bindings with `Binding(get:set:)`, and keep per-view local state in a small `ObservableObject` with `@Published` used through `@StateObject` (property wrappers that are not macros compile fine). `ThemeTests` source scan should grow a check for `@State ` and `@Bindable ` once Task 8 lands.
- **agy print timeout.** agy caps a print-mode turn at 5 minutes by default and returns partial output; `agy_run.py` now passes `--print-timeout` equal to its own `--timeout`. Tasks 2, 5 and 7 were cut by this before the fix (Task 5 produced nothing and was re-dispatched on Flash High).
- **Strict concurrency.** A nonisolated `deinit` cannot touch `@MainActor` state; long-lived models (AppModel) simply have no deinit, and tests stop timers explicitly.
- **Stale socket on SIGTERM.** `kill` does not run `HookServer.stop()`, so `/tmp/codeisland-<uid>.sock` survives the process; `start()` unlinks it on the next launch, and `codeisland-hook.sh` tolerates a refused connection, so hooks never block. A SIGTERM handler that calls `stop()` is a v1.1 nicety, not a blocker.
- **Bundle smoke (Task 12 prep, 2026-09-13):** `LLMOps/build.sh` produced an ad-hoc signed `LLMOps.app`; launched from the bundle it bound the socket with mode 0600, answered a synthetic `SessionStart` with `{}` and held a synthetic `PermissionRequest` open, as designed.
- **Real-data probe (2026-09-13, throwaway test, not committed):** `TranscriptScanner.scan` over the default profiles parsed 653 transcripts in 27 s; pessoal 367 sessions, afya 11 sessions / 541 turns / 1,471 tool calls / 649M cache-read tokens across 6 projects, all `claude-opus-5`. Follow-ups for v1.1: persist the scan cache to disk or parallelize per profile so History is not empty for the first ~30 s; verify why the newest afya JSONL (mtime today) surfaced with lastActivity 2026-09-11.
- **PR step needs a fork.** `origin` is `https://github.com/wxtsky/CodeIsland.git` (upstream, not owned by the owner). Task 12.3's "PR llmops -> main" requires the owner to create their own GitHub fork and add it as a remote; until then the branch stays local and gets the `llmops-v1.0.0` tag only.

## Independent review (2026-09-13, gpt-5.6-sol via codex read-only sandbox; GLM-5.3 via opencode read-only agent)

Both reviewers returned `fix-required` and converged on: Analytics ignoring the selected profile (HIGH in both), the S3 hero for a selected profile (ISO-week cost) not implemented, session status stuck in `waitingApproval` after the user decides, profiles never re-resolved after prefix edits, the History "to" date excluding its own day, two test suites racing on `CODEISLAND_SOCKET_PATH`, a doubled permission sound (the reducer already emits `.playSound` for every event), decorative cyan on Live status dots, and dead wrappers (`settingsDidChange`, `saveSettings`, `ProfilesDraft.commit`). SOL alone found: `AskUserQuestion` arriving as a `PermissionRequest` with `tool_name == "AskUserQuestion"` being treated as allow/deny, held connections never observing client disconnect, rescan ticks cancelling a scan slower than 30 s, and day/week aggregates attributed to `Session.startedAt` instead of per turn. GLM alone found: `tool_result` pairing only searching the last turn, and Analytics using a local 2-decimal `usd` instead of `HistoryFormat`.

Rejected: "MetricLine label must be mono" (DESIGN.md's No Bare Number Rule says the label is body-weight); umask restored before bind (chmod on `.ready` covers a millisecond window); byte-offset incremental parsing (Task 2 contract allowed full re-parse of a changed file; v1.1). Deferred: bundle icon (needs an asset), FakeClock duplication in tests.

Semantics corrected by the review: **peer disconnect** on a held hook connection means "the user answered in the terminal": drain that session's pending items and reset its status; it does not end the session (S2 said otherwise; this supersedes it). **Time buckets** are per `Turn.startedAt`, not per session, because Claude Code sessions are resumed across days (S4/Task 3 contract superseded). Bench in Task 2 runs 200 sessions under 4 s, not 2,000 under 2 s.

Fix tasks F1 (LiveStore), F2 (HookServer), F3 (app layer), F4 (Aggregates by turn), F5 (scanner pairing) dispatched to agy Gemini 3.8 Flash (Medium) with disjoint file sets.
