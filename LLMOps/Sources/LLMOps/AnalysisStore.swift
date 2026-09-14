import Foundation
import LLMOpsCore

public struct AnalysisRun: Codable, Equatable, Identifiable {
    public let id: String
    public let generatedAt: Date
    public let profile: String?
    public let periodDays: Int
    public let sessionCount: Int
    public let model: String
    public let costUSD: Double?
    public let report: JudgeReport?
    public let rawText: String

    public init(
        id: String? = nil,
        generatedAt: Date,
        profile: String?,
        periodDays: Int,
        sessionCount: Int,
        model: String,
        costUSD: Double?,
        report: JudgeReport?,
        rawText: String
    ) {
        let formatter = ISO8601DateFormatter()
        self.id = id ?? formatter.string(from: generatedAt).replacingOccurrences(of: ":", with: "-")
        self.generatedAt = generatedAt
        self.profile = profile
        self.periodDays = periodDays
        self.sessionCount = sessionCount
        self.model = model
        self.costUSD = costUSD
        self.report = report
        self.rawText = rawText
    }
}

public final class AnalysisStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("LLMOps/analysis")
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/LLMOps/analysis")
    }

    public func save(_ run: AnalysisRun) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(run.id).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        try data.write(to: fileURL, options: .atomic)
    }

    public func loadLatest() -> AnalysisRun? {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return nil
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        let jsonFiles = files.filter { $0.pathExtension == "json" }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var runs: [AnalysisRun] = []
        for file in jsonFiles {
            guard let data = try? Data(contentsOf: file) else { continue }
            if let run = try? decoder.decode(AnalysisRun.self, from: data) {
                runs.append(run)
            }
        }
        return runs.max(by: { $0.generatedAt < $1.generatedAt })
    }
}
