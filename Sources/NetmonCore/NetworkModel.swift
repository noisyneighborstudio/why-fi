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
    public let bufferbloatDeltaMilliseconds: Double?

    public init(
        mode: MonitorMode,
        stats: WindowStats,
        outageSeconds: Int = 0,
        pulseOn: Bool = false,
        hasData: Bool = true,
        gatewayReachable: Bool? = nil,
        bufferbloatDeltaMilliseconds: Double? = nil
    ) {
        self.mode = mode
        self.stats = stats
        self.outageSeconds = outageSeconds
        self.pulseOn = pulseOn
        self.hasData = hasData
        self.gatewayReachable = gatewayReachable
        self.bufferbloatDeltaMilliseconds = bufferbloatDeltaMilliseconds
    }

    public static let initial = MonitorState(
        mode: .fine,
        stats: WindowStats(samples: []),
        hasData: false
    )

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

public struct ProbeMeasurement: Equatable, Sendable {
    public let transport: ProbeTransport
    public let sample: NetworkSample

    public init(transport: ProbeTransport, sample: NetworkSample) {
        self.transport = transport
        self.sample = sample
    }

    public static func classify(transport: ProbeTransport, milliseconds: Double?) -> ProbeMeasurement {
        let sample: NetworkSample
        if let milliseconds {
            sample = milliseconds >= 200 ? .late(milliseconds) : .ok(milliseconds)
        } else {
            sample = .lost
        }
        return ProbeMeasurement(transport: transport, sample: sample)
    }
}

public enum ProbeTransport: String, Sendable {
    case icmp
    case tcp
}

public struct EndpointProbe: Equatable, Sendable {
    public let address: String
    public let icmp: ProbeMeasurement
    public let tcp: ProbeMeasurement

    public init(address: String, icmp: ProbeMeasurement, tcp: ProbeMeasurement) {
        self.address = address
        self.icmp = icmp
        self.tcp = tcp
    }

    public var reachable: Bool {
        icmp.sample.outcome != .lost || tcp.sample.outcome != .lost
    }

    public var displaySample: NetworkSample {
        let available = [icmp.sample, tcp.sample].filter { $0.outcome != .lost }
        guard !available.isEmpty else { return .lost }
        let latency = available.compactMap(\.rttMilliseconds).max() ?? 0
        let isLate = available.contains { $0.outcome == .late }
        return isLate ? .late(latency) : .ok(latency)
    }
}

public struct ProbeSnapshot: Equatable, Sendable {
    public let publicEndpoint: EndpointProbe
    public let gatewayEndpoint: EndpointProbe?
    public let idleMilliseconds: Double?
    public let underLoadMilliseconds: Double?

    public init(
        publicEndpoint: EndpointProbe,
        gatewayEndpoint: EndpointProbe?,
        idleMilliseconds: Double? = nil,
        underLoadMilliseconds: Double? = nil
    ) {
        self.publicEndpoint = publicEndpoint
        self.gatewayEndpoint = gatewayEndpoint
        self.idleMilliseconds = idleMilliseconds
        self.underLoadMilliseconds = underLoadMilliseconds
    }

    public var publicSample: NetworkSample { publicEndpoint.displaySample }

    public var bufferbloatDeltaMilliseconds: Double? {
        guard let idleMilliseconds, let underLoadMilliseconds else { return nil }
        return underLoadMilliseconds - idleMilliseconds
    }
}

public struct MonitorStateMachine {
    private var outageStartedAt: Date?

    public init() {}

    public mutating func update(
        snapshot: ProbeSnapshot,
        samples: [NetworkSample],
        now: Date = Date(),
        pulseOn: Bool
    ) -> MonitorState {
        let publicReachable = snapshot.publicEndpoint.reachable
        let gatewayReachable = snapshot.gatewayEndpoint?.reachable

        let mode: MonitorMode
        if publicReachable {
            let stats = WindowStats(samples: samples)
            mode = (stats.p90Milliseconds.map { $0 > 800 } == true || stats.lossPercent > 2) ? .congested : .fine
        } else if gatewayReachable == true {
            mode = .gatewayOnly
        } else {
            mode = .dead
        }

        if publicReachable {
            outageStartedAt = nil
        } else if outageStartedAt == nil {
            outageStartedAt = now
        }

        let outageSeconds: Int
        if let outageStartedAt {
            outageSeconds = max(0, Int(now.timeIntervalSince(outageStartedAt).rounded(.down)))
        } else {
            outageSeconds = 0
        }

        return MonitorState(
            mode: mode,
            stats: WindowStats(samples: samples),
            outageSeconds: outageSeconds,
            pulseOn: pulseOn,
            hasData: true,
            gatewayReachable: gatewayReachable,
            bufferbloatDeltaMilliseconds: snapshot.bufferbloatDeltaMilliseconds
        )
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

    public static var fixture: RendererPalette {
        let ink = NSColor(calibratedWhite: 0.16, alpha: 0.94)
        return RendererPalette(
            ink: ink,
            hairline: NSColor(calibratedWhite: 0.16, alpha: 0.30),
            rail: ink,
            amber: NSColor(calibratedRed: 0.82, green: 0.45, blue: 0.03, alpha: 1),
            red: NSColor(calibratedRed: 0.78, green: 0.08, blue: 0.07, alpha: 1),
            background: .clear
        )
    }
}
