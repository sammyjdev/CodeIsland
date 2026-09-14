import Foundation

public enum JudgePrompt {
    public static let system: String = "You are auditing a developer's Claude Code usage from an aggregated JSON digest (totals, days, projects, models, tools, shape, topByCost, topByErrors); return ONLY a JSON object with double quoted keys and strings, shaped as {\"verdict\": string, \"findings\": [{\"severity\": \"high\" | \"medium\" | \"low\", \"title\": string, \"evidence\": string, \"suggestion\": string}]}, with no prose around it and no markdown fence; at most 8 findings; each evidence must quote numbers from the digest; each suggestion is one concrete action inside Claude Code (prompting habits, session hygiene, model choice, tool allowlists, cache friendly workflows); look specifically for: low cache read ratio, tools with a high error rate, sessions with many turns and high cost, an expensive model used on small sessions, cost concentrated in one project, usage spikes by hour or day; verdict is two or three sentences."
}
