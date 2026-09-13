import Foundation
import CodeIslandCore
import LLMOpsCore

struct HistoryFilter: Equatable {
    var project: String? = nil        // exact match on Session.project
    var model: String? = nil          // exact match on Session.model
    var from: Date? = nil             // inclusive, on startedAt
    var to: Date? = nil               // inclusive, on startedAt
    var search: String = ""           // case-insensitive substring over every turn's userPrompt and the session title

    func apply(to sessions: [Session]) -> [Session] {
        sessions.filter { session in
            if let project, session.project != project {
                return false
            }
            if let model, session.model != model {
                return false
            }
            if let from, session.startedAt < from {
                return false
            }
            if let to, session.startedAt > to {
                return false
            }
            if !search.isEmpty {
                let query = search.lowercased()
                let titleMatch = session.title?.lowercased().contains(query) ?? false
                let promptMatch = session.turns.contains { turn in
                    turn.userPrompt?.lowercased().contains(query) ?? false
                }
                if !titleMatch && !promptMatch {
                    return false
                }
            }
            return true
        }
    }

    static func projects(in sessions: [Session]) -> [String] {
        Array(Set(sessions.map(\.project))).sorted()
    }

    static func models(in sessions: [Session]) -> [String] {
        Array(Set(sessions.compactMap(\.model))).sorted()
    }
}

/// Per-view state holder (ObservableObject, see toolchain rule).
final class HistoryState: ObservableObject {
    @Published var filter = HistoryFilter()
    @Published var selectedSessionId: String? = nil
    @Published var expandedTurnIds: Set<String> = []
}

enum HistoryFormat {
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            let val = Double(n) / 1_000_000.0
            let rounded = (val * 10.0).rounded() / 10.0
            return String(format: "%.1fM", rounded)
        } else if n >= 10_000 {
            let val = Double(n) / 1000.0
            let rounded = (val * 10.0).rounded() / 10.0
            return String(format: "%.1fK", rounded)
        } else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US")
            return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
        }
    }

    static func cacheRatio(_ u: ClaudeUsageTotals) -> String {
        let denom = u.inputTokens + u.cacheReadTokens + u.cacheCreationTokens
        guard denom > 0 else { return "0%" }
        let ratio = Double(u.cacheReadTokens) / Double(denom)
        let percent = Int((ratio * 100.0).rounded())
        return "\(percent)%"
    }

    static func usd(_ v: Double) -> String {
        if v < 1.0 {
            return String(format: "$%.4f", v)
        } else {
            return String(format: "$%.2f", v)
        }
    }

    static func duration(ms: Int?) -> String {
        guard let ms else { return "n/a" }
        if ms < 1000 {
            return "\(ms)ms"
        } else if ms < 60_000 {
            let seconds = Double(ms) / 1000.0
            let rounded = (seconds * 10.0).rounded() / 10.0
            return String(format: "%.1fs", rounded)
        } else {
            let totalSeconds = ms / 1000
            let minutes = totalSeconds / 60
            let secs = totalSeconds % 60
            return "\(minutes)m \(String(format: "%02d", secs))s"
        }
    }
}

enum HistoryDateFormatter {
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func formatDateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

