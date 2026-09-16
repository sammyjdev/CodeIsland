import Foundation

public struct WidgetQuota: Codable, Equatable, Sendable {
    public var provider: QuotaProviderID
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(provider: QuotaProviderID, label: String, usedPercent: Double, resetsAt: Date?) {
        self.provider = provider
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct TodaySummary: Codable, Equatable, Sendable {
    public var sessions: Int
    public var tokens: Int
    public var costUSD: Double

    public init(sessions: Int, tokens: Int, costUSD: Double) {
        self.sessions = sessions
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

public struct SystemSummary: Codable, Equatable, Sendable {
    public var cpuPercent: Double
    public var memoryUsedPercent: Double
    public var batteryPercent: Double?

    public init(cpuPercent: Double, memoryUsedPercent: Double, batteryPercent: Double?) {
        self.cpuPercent = cpuPercent
        self.memoryUsedPercent = memoryUsedPercent
        self.batteryPercent = batteryPercent
    }
}

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var writtenAt: Date
    public var quotas: [WidgetQuota]
    public var today: TodaySummary
    public var system: SystemSummary

    public init(writtenAt: Date, quotas: [WidgetQuota], today: TodaySummary, system: SystemSummary) {
        self.writtenAt = writtenAt
        self.quotas = quotas
        self.today = today
        self.system = system
    }
}

public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "snapshot.json"
    public static let widgetBundleID = "dev.samdev.llmops.widgets"

    /// ~/Library/Containers/<widgetBundleID>/Data/Library/Application Support, built from `home`.
    public static func defaultDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent(widgetBundleID)
            .appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
    }

    public let directory: URL

    public init(directory: URL = WidgetSnapshotStore.defaultDirectory()) {
        self.directory = directory
    }

    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    /// Creates the directory if needed, encodes with JSONEncoder (dateEncodingStrategy .iso8601),
    /// writes atomically. Throws on failure.
    public func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    /// nil when the file is missing or undecodable (never throws). JSONDecoder .iso8601.
    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
