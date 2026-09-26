import Foundation

public enum SampleOutcome: String, CaseIterable, Codable, Sendable {
    case ok
    case late
    case lost
}

/// One probe slot: the internet reply, and the gateway reply sent in the same slot.
public struct NetworkSample: Equatable, Codable, Sendable {
    public let rttMilliseconds: Double?
    public let outcome: SampleOutcome
    public let gatewayMilliseconds: Double?

    public init(rttMilliseconds: Double?, outcome: SampleOutcome, gatewayMilliseconds: Double? = nil) {
        self.rttMilliseconds = rttMilliseconds
        self.outcome = outcome
        self.gatewayMilliseconds = gatewayMilliseconds
    }

    public static func ok(_ milliseconds: Double, gateway: Double? = nil) -> NetworkSample {
        NetworkSample(rttMilliseconds: milliseconds, outcome: .ok, gatewayMilliseconds: gateway)
    }

    public static func late(_ milliseconds: Double, gateway: Double? = nil) -> NetworkSample {
        NetworkSample(rttMilliseconds: milliseconds, outcome: .late, gatewayMilliseconds: gateway)
    }

    public static func lost(gateway: Double? = nil) -> NetworkSample {
        NetworkSample(rttMilliseconds: nil, outcome: .lost, gatewayMilliseconds: gateway)
    }

    public static let lost = lost()

    /// On time if the reply beat the next probe; late if it came after, which is when `ping` prints a timeout.
    public static func classify(milliseconds: Double?, interval: TimeInterval, gateway: Double? = nil) -> NetworkSample {
        guard let milliseconds else { return .lost(gateway: gateway) }
        return milliseconds <= interval * 1_000 ? .ok(milliseconds, gateway: gateway) : .late(milliseconds, gateway: gateway)
    }
}

public enum Thresholds {
    /// Late: the reply took longer than the one-second probe interval.
    public static let lateMilliseconds: Double = 1_000
    /// Upper edge of a healthy internet round trip; drives the green band and orange stats.
    public static let normalMilliseconds: Double = 150
    /// A loss run this long is an outage.
    public static let outageSeconds = 3
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

/// Menu bar bar height: log from 2 ms to the late threshold fills the lower 8pt,
/// late to 3 s fills the top 6pt, so the threshold hairline sits at a fixed height.
public enum RTTScale {
    public static let height: CGFloat = 14
    public static let thresholdHeight: CGFloat = 8

    public static func barHeight(milliseconds: Double) -> CGFloat {
        max(1, (CGFloat(fraction(milliseconds: milliseconds)) * height * 2).rounded() / 2)
    }

    /// Position on the same scale as a fraction of full height, 0 to 1.
    public static func fraction(milliseconds: Double) -> Double {
        let late = Thresholds.lateMilliseconds
        let threshold = Double(thresholdHeight / height)
        return milliseconds <= late
            ? log10(max(milliseconds, 2) / 2) / log10(late / 2) * threshold
            : threshold + log10(min(milliseconds, 3_000) / late) / log10(3) * (1 - threshold)
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

    /// Indices of lost samples that belong to a run long enough to be an outage.
    public static func outageIndices(in samples: [NetworkSample]) -> Set<Int> {
        Set(contiguous(in: samples).filter { $0.length >= Thresholds.outageSeconds }.flatMap { $0.start..<$0.end })
    }
}

public struct WindowStats: Equatable, Sendable {
    public let sampleCount: Int
    public let lossCount: Int
    public let lossPercent: Double
    public let p50Milliseconds: Double?
    public let p90Milliseconds: Double?
    public let p95Milliseconds: Double?
    public let gatewayP50Milliseconds: Double?
    public let longestLossRun: Int
    public let activeLossRun: Int

    public init(samples: [NetworkSample]) {
        sampleCount = samples.count
        lossCount = samples.filter { $0.outcome == .lost }.count
        lossPercent = samples.isEmpty ? 0 : Double(lossCount) / Double(samples.count) * 100

        let latencies = samples.compactMap(\.rttMilliseconds).sorted()
        p50Milliseconds = Self.percentile(latencies, 0.50)
        p90Milliseconds = Self.percentile(latencies, 0.90)
        p95Milliseconds = Self.percentile(latencies, 0.95)
        gatewayP50Milliseconds = Self.percentile(samples.compactMap(\.gatewayMilliseconds).sorted(), 0.50)

        longestLossRun = LossRuns.contiguous(in: samples).map(\.length).max() ?? 0
        activeLossRun = samples.reversed().prefix { $0.outcome == .lost }.count
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let position = percentile * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}

public enum MonitorMode: String, CaseIterable, Codable, Sendable {
    case fine
    case congested
    case gatewayOnly = "gateway-only"
    case dead

    /// Worse states outrank better ones when refresh budget is scarce.
    public var severity: Int {
        switch self {
        case .fine: return 0
        case .congested: return 1
        case .gatewayOnly: return 2
        case .dead: return 3
        }
    }
}

public struct MonitorState: Equatable, Sendable {
    public let mode: MonitorMode
    public let stats: WindowStats
    public let hasData: Bool

    public init(mode: MonitorMode, stats: WindowStats, hasData: Bool = true) {
        self.mode = mode
        self.stats = stats
        self.hasData = hasData
    }

    public static let initial = MonitorState(mode: .fine, stats: WindowStats(samples: []), hasData: false)

    /// One slot is one second, so the trailing loss run is the outage duration.
    public static func evaluate(samples: [NetworkSample], gatewayReachable: Bool?) -> MonitorState {
        let stats = WindowStats(samples: samples)
        let mode: MonitorMode
        if stats.activeLossRun >= Thresholds.outageSeconds {
            mode = gatewayReachable == true ? .gatewayOnly : .dead
        } else if stats.p50Milliseconds.map({ $0 > Thresholds.normalMilliseconds }) == true
            || stats.p90Milliseconds.map({ $0 > 800 }) == true
            || stats.lossPercent > 2 {
            mode = .congested
        } else {
            mode = .fine
        }
        return MonitorState(mode: mode, stats: stats, hasData: !samples.isEmpty)
    }

    public var outageSeconds: Int { stats.activeLossRun }
}

public enum DisplayMode: String, CaseIterable, Sendable {
    case auto
    case compact
    case expanded

    /// Auto stays icon-only while fine and widens for every other state.
    public func isExpanded(for mode: MonitorMode) -> Bool {
        self == .expanded || (self == .auto && mode != .fine)
    }
}

public enum Formatting {
    public static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 1_000 ? "\(Int(value.rounded()))ms" : String(format: "%.1fs", value / 1_000)
    }

    public static func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
