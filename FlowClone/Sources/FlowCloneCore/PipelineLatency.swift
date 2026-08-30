import Foundation

/// Text-free performance metadata for one completed dictation. No transcript,
/// audio, app name, or surrounding context is represented by this type.
public struct PipelineLatencySample: Codable, Equatable, Sendable {
    public enum Engine: String, Codable, Equatable, Sendable {
        case apple
        case ollama
        case local
    }

    public let timestamp: Date
    public let asrMs: Int
    public let cleanupMs: Int
    public let injectionMs: Int
    public let totalMs: Int
    public let engine: Engine
    public let wordCount: Int

    public init(timestamp: Date, asrMs: Int, cleanupMs: Int, injectionMs: Int,
                totalMs: Int, engine: Engine, wordCount: Int) {
        self.timestamp = timestamp
        self.asrMs = max(0, asrMs)
        self.cleanupMs = max(0, cleanupMs)
        self.injectionMs = max(0, injectionMs)
        self.totalMs = max(0, totalMs)
        self.engine = engine
        self.wordCount = max(0, wordCount)
    }
}

public struct PipelineLatencySummary: Equatable, Sendable {
    public enum Stage: Equatable, Sendable { case recognition, cleanup, insertion }

    public let medianTotalMs: Int
    public let p95TotalMs: Int
    public let averageASRMs: Int
    public let averageCleanupMs: Int
    public let averageInjectionMs: Int
    public let slowestStage: Stage
    public let unusuallySlowCount: Int
    public let slowThresholdMs: Int
}

public enum PipelineLatencyAnalyzer {
    public static func summarize(_ samples: [PipelineLatencySample]) -> PipelineLatencySummary? {
        guard !samples.isEmpty else { return nil }
        let totals = samples.map(\.totalMs).sorted()
        let midpoint = totals.count / 2
        let median = totals.count.isMultiple(of: 2)
            ? (totals[midpoint - 1] + totals[midpoint]) / 2
            : totals[midpoint]
        let p95Index = max(0, Int(ceil(Double(totals.count) * 0.95)) - 1)
        let p95 = totals[min(p95Index, totals.count - 1)]
        let asr = average(samples.map(\.asrMs))
        let cleanup = average(samples.map(\.cleanupMs))
        let injection = average(samples.map(\.injectionMs))
        let slowest: PipelineLatencySummary.Stage
        if cleanup >= asr && cleanup >= injection {
            slowest = .cleanup
        } else if asr >= injection {
            slowest = .recognition
        } else {
            slowest = .insertion
        }
        // A genuinely slow sample is either over two seconds or 60% slower
        // than this user's recent median. This is stable with small histories
        // and doesn't label the ordinary p95 tail as an incident by definition.
        let slowThreshold = max(2_000, Int(Double(median) * 1.6))
        let slowCount = totals.filter { $0 > slowThreshold }.count
        return PipelineLatencySummary(
            medianTotalMs: median,
            p95TotalMs: p95,
            averageASRMs: asr,
            averageCleanupMs: cleanup,
            averageInjectionMs: injection,
            slowestStage: slowest,
            unusuallySlowCount: slowCount,
            slowThresholdMs: slowThreshold)
    }

    private static func average(_ values: [Int]) -> Int {
        values.reduce(0, +) / max(values.count, 1)
    }
}

public enum PipelineLatencyHistory {
    public static func appending(_ sample: PipelineLatencySample,
                                 to existing: [PipelineLatencySample],
                                 writeSucceeded: Bool = true,
                                 cap: Int = 50) -> [PipelineLatencySample] {
        guard writeSucceeded else { return existing }
        guard cap > 0 else { return [] }
        return Array((existing + [sample]).suffix(cap))
    }
}

public enum PipelineStageTiming {
    /// Early streaming can paste while cleanup is still running. Keep those
    /// milliseconds in insertion without counting them in both stages.
    public static func cleanupOnly(totalCleanupIntervalMs: Int,
                                   streamedInjectionMs: Int) -> Int {
        max(0, totalCleanupIntervalMs - streamedInjectionMs)
    }
}
