import AppKit
import Foundation

public enum SampleOutcome: String, CaseIterable, Codable, Sendable {
    case ok
    case late
    case lost
}

public struct NetworkSample: Equatable, Sendable {
    public let rttMilliseconds: Double?
    public let outcome: SampleOutcome

    public init(rttMilliseconds: Double?, outcome: SampleOutcome) {
        self.rttMilliseconds = rttMilliseconds
        self.outcome = outcome
    }

    public static func ok(_ milliseconds: Double) -> NetworkSample {
        NetworkSample(rttMilliseconds: milliseconds, outcome: .ok)
    }

    public static func late(_ milliseconds: Double) -> NetworkSample {
        NetworkSample(rttMilliseconds: milliseconds, outcome: .late)
    }

    public static let lost = NetworkSample(rttMilliseconds: nil, outcome: .lost)

    /// On time if the reply beat the next probe; late if it came after, which is when `ping` prints a timeout.
    public static func classify(milliseconds: Double, interval: TimeInterval) -> NetworkSample {
        milliseconds <= interval * 1_000 ? .ok(milliseconds) : .late(milliseconds)
    }
}

public struct SampleRingBuffer: Sendable {
    public let capacity: Int
    private var storage: [NetworkSample?]
    private var nextIndex: Int = 0
    private var storedCount: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "A sample ring buffer needs a positive capacity")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    public var count: Int { storedCount }

    public mutating func append(_ sample: NetworkSample) {
        storage[nextIndex] = sample
        nextIndex = (nextIndex + 1) % capacity
        storedCount = min(storedCount + 1, capacity)
    }

    /// Corrects an already-appended slot; offset 0 is the newest.
    public mutating func replace(fromEnd offset: Int, with sample: NetworkSample) {
        guard offset >= 0, offset < storedCount else { return }
        storage[(nextIndex - 1 - offset + capacity) % capacity] = sample
    }

    public var samples: [NetworkSample] {
        guard storedCount > 0 else { return [] }
        let start = storedCount == capacity ? nextIndex : 0
        return (0..<storedCount).compactMap { offset in
            storage[(start + offset) % capacity]
        }
    }
}

public enum RTTScale {
    public static let floorMilliseconds: Double = 10
    public static let ceilingMilliseconds: Double = 3_000

    public static func normalized(milliseconds: Double) -> Double {
        let clamped = min(max(milliseconds, floorMilliseconds), ceilingMilliseconds)
        let numerator = log10(clamped / floorMilliseconds)
        let denominator = log10(ceilingMilliseconds / floorMilliseconds)
        return min(max(numerator / denominator, 0), 1)
    }

    public static func barHeight(milliseconds: Double, maxHeight: Int) -> Int {
        guard maxHeight > 0 else { return 0 }
        return Int((normalized(milliseconds: milliseconds) * Double(maxHeight)).rounded())
    }
}

public struct LossRun: Equatable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var length: Int { end - start }
}

public enum LossRuns {
    public static func contiguous(in samples: [NetworkSample]) -> [LossRun] {
        var runs: [LossRun] = []
        var start: Int?

        for (index, sample) in samples.enumerated() {
            if sample.outcome == .lost {
                if start == nil { start = index }
            } else if let runStart = start {
                runs.append(LossRun(start: runStart, end: index))
                start = nil
            }
        }

        if let start {
            runs.append(LossRun(start: start, end: samples.count))
        }
        return runs
    }
}

public struct WindowStats: Equatable, Sendable {
    public let sampleCount: Int
    public let lossCount: Int
    public let lateCount: Int
    public let lossPercent: Double
    public let p50Milliseconds: Double?
    public let p90Milliseconds: Double?
    public let p95Milliseconds: Double?
    public let maxMilliseconds: Double?
    public let longestLossRun: Int
    public let activeLossRun: Int

    public init(samples: [NetworkSample]) {
        sampleCount = samples.count
        lossCount = samples.reduce(into: 0) { count, sample in
            if sample.outcome == .lost { count += 1 }
        }
        lateCount = samples.filter { $0.outcome == .late }.count
        lossPercent = samples.isEmpty ? 0 : Double(lossCount) / Double(samples.count) * 100

        let latencies = samples.compactMap(\.rttMilliseconds).sorted()
        p50Milliseconds = Self.percentile(latencies, percentile: 0.50)
        p90Milliseconds = Self.percentile(latencies, percentile: 0.90)
        p95Milliseconds = Self.percentile(latencies, percentile: 0.95)
        maxMilliseconds = latencies.last

        longestLossRun = LossRuns.contiguous(in: samples).map(\.length).max() ?? 0
        var active = 0
        for sample in samples.reversed() {
            guard sample.outcome == .lost else { break }
            active += 1
        }
        activeLossRun = active
    }

    private static func percentile(_ sorted: [Double], percentile: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let position = percentile * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }
}

public enum MonitorMode: String, CaseIterable, Sendable {
    case fine
    case congested
    case gatewayOnly = "gateway-only"
    case dead
}

public enum RenderTone: String, Sendable {
    case monochrome
    case amber
    case red
}

public struct MonitorState: Equatable, Sendable {
    public let mode: MonitorMode
    public let stats: WindowStats
    public let outageSeconds: Int
    public let pulseOn: Bool
    public let hasData: Bool
    public let gatewayReachable: Bool?

    public init(
        mode: MonitorMode,
        stats: WindowStats,
        outageSeconds: Int = 0,
        pulseOn: Bool = false,
        hasData: Bool = true,
        gatewayReachable: Bool? = nil
    ) {
        self.mode = mode
        self.stats = stats
        self.outageSeconds = outageSeconds
        self.pulseOn = pulseOn
        self.hasData = hasData
        self.gatewayReachable = gatewayReachable
    }

    public static let initial = MonitorState(
        mode: .fine,
        stats: WindowStats(samples: []),
        hasData: false
    )

    /// One slot is one second, so the trailing loss run is the outage duration.
    public static func evaluate(samples: [NetworkSample], gatewayReachable: Bool?, pulseOn: Bool) -> MonitorState {
        let stats = WindowStats(samples: samples)
        let mode: MonitorMode
        if stats.activeLossRun >= 3 {
            mode = gatewayReachable == true ? .gatewayOnly : .dead
        } else if stats.p90Milliseconds.map({ $0 > 800 }) == true || stats.lossPercent > 2 {
            mode = .congested
        } else {
            mode = .fine
        }
        return MonitorState(
            mode: mode,
            stats: stats,
            outageSeconds: stats.activeLossRun,
            pulseOn: pulseOn,
            gatewayReachable: gatewayReachable
        )
    }

    public var activeLossRun: Int { stats.activeLossRun }

    public var tone: RenderTone {
        if stats.activeLossRun >= 3 { return .red }
        if stats.p90Milliseconds.map({ $0 > 800 }) == true || stats.lossPercent > 2 || mode == .gatewayOnly {
            return .amber
        }
        return .monochrome
    }

    public var showsOutageDuration: Bool {
        mode == .dead && outageSeconds >= 5
    }
}

public struct RendererPalette {
    public let ink: NSColor
    public let hairline: NSColor
    public let rail: NSColor
    public let amber: NSColor
    public let red: NSColor
    public let background: NSColor

    public init(
        ink: NSColor,
        hairline: NSColor,
        rail: NSColor,
        amber: NSColor,
        red: NSColor,
        background: NSColor = .clear
    ) {
        self.ink = ink
        self.hairline = hairline
        self.rail = rail
        self.amber = amber
        self.red = red
        self.background = background
    }

    public static var menuBar: RendererPalette {
        let ink = NSColor.labelColor
        return RendererPalette(
            ink: ink.withAlphaComponent(0.88),
            hairline: ink.withAlphaComponent(0.25),
            rail: ink.withAlphaComponent(0.74),
            amber: .systemOrange,
            red: .systemRed
        )
    }

}
