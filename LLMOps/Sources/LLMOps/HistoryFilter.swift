import Foundation
import CodeIslandCore
import LLMOpsCore

enum Period: String, CaseIterable, Equatable {
    case d7, d30, d90, all

    var label: String {
        switch self {
        case .d7: return "7d"
        case .d30: return "30d"
        case .d90: return "90d"
        case .all: return "all"
        }
    }
}

struct HistoryFilter: Equatable {
    var period: Period = .d30
    var project: String? = nil        // exact match on Session.project
    var model: String? = nil          // exact match on Session.model
    var from: Date? = nil             // inclusive, on startedAt
    var to: Date? = nil               // inclusive, on startedAt
    var search: String = ""           // case-insensitive substring over every turn's userPrompt and the session title
    var calendar: Calendar = .autoupdatingCurrent

    init(
        period: Period? = nil,
        project: String? = nil,
        model: String? = nil,
        from: Date? = nil,
        to: Date? = nil,
        search: String = "",
        calendar: Calendar = .autoupdatingCurrent
    ) {
        if let period {
            self.period = period
        } else if from != nil || to != nil {
            self.period = .all
        } else {
            self.period = .d30
        }
        self.project = project
        self.model = model
        self.from = from
        self.to = to
        self.search = search
        self.calendar = calendar
    }

    /// Selecting a preset clears the explicit date range.
    mutating func select(period: Period) {
        self.period = period
        self.from = nil
        self.to = nil
    }

    /// Setting an explicit date switches the preset to .all.
    mutating func setFrom(_ date: Date?) {
        self.from = date
        self.period = .all
    }

    mutating func setTo(_ date: Date?) {
        self.to = date
        self.period = .all
    }

    /// Days the daily chart should cover. 7, 30, 90, or for .all the number of
    /// calendar days from `earliest` (start of day) to `now` (start of day) inclusive,
    /// minimum 1. `earliest` nil means 1.
    func dayCount(now: Date, earliest: Date?) -> Int {
        switch period {
        case .d7:
            return 7
        case .d30:
            return 30
        case .d90:
            return 90
        case .all:
            guard let earliest else { return 1 }
            let startOfNow = calendar.startOfDay(for: now)
            let startOfEarliest = calendar.startOfDay(for: earliest)
            if startOfEarliest > startOfNow {
                return 1
            }
            let diff = calendar.dateComponents([.day], from: startOfEarliest, to: startOfNow).day ?? 0
            return max(1, diff + 1)
        }
    }

    /// Existing filtering plus the preset lower bound: when `from` is nil and
    /// period != .all, sessions whose startedAt is before startOfDay(now) - (days - 1) days
    /// are dropped. `to` handling, project, model and search are unchanged.
    func apply(to sessions: [Session], now: Date = Date()) -> [Session] {
        let presetLowerBound: Date? = {
            guard from == nil && period != .all else { return nil }
            let days: Int
            switch period {
            case .d7: days = 7
            case .d30: days = 30
            case .d90: days = 90
            case .all: return nil
            }
            let startOfNow = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -(days - 1), to: startOfNow)
                ?? startOfNow.addingTimeInterval(-Double(days - 1) * 86400)
        }()

        return sessions.filter { session in
            if let project, session.project != project {
                return false
            }
            if let model, session.model != model {
                return false
            }
            if let from {
                if session.startedAt < from {
                    return false
                }
            } else if let presetLowerBound {
                if session.startedAt < presetLowerBound {
                    return false
                }
            }
            if let to {
                let startOfToDay = calendar.startOfDay(for: to)
                let endOfToDay = calendar.date(byAdding: .day, value: 1, to: startOfToDay) ?? startOfToDay.addingTimeInterval(86400)
                if session.startedAt >= endOfToDay {
                    return false
                }
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

