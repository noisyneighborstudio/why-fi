import Foundation

/// One popover chart column: the worst reply in a group of consecutive slots.
public struct ChartBucket: Equatable, Sendable {
    public let worstMilliseconds: Double?
    public let hasLoss: Bool
    public let hasOutage: Bool

    /// Groups the newest `slots` samples into columns, newest on the right; missing history is empty.
    public static func buckets(samples: [NetworkSample], slots: Int = 300, perBucket: Int = 3) -> [ChartBucket?] {
        let window = Array(samples.suffix(slots))
        let outage = LossRuns.outageIndices(in: window)
        let padding = slots - window.count
        return stride(from: 0, to: slots, by: perBucket).map { start in
            let indices = (start..<start + perBucket).map { $0 - padding }.filter { $0 >= 0 }
            guard !indices.isEmpty else { return nil }
            return ChartBucket(
                worstMilliseconds: indices.compactMap { window[$0].rttMilliseconds }.max(),
                hasLoss: indices.contains { window[$0].outcome == .lost },
                hasOutage: indices.contains { outage.contains($0) }
            )
        }
    }
}

public enum Verdict {
    /// One plain sentence from measured facts only; there is no stored baseline to compare against.
    public static func text(state: MonitorState, stats: WindowStats) -> String {
        switch state.mode {
        case .dead:
            return String(localized: "No replies for \(Formatting.duration(state.outageSeconds)).")
        case .gatewayOnly:
            return String(localized: "Router answers, internet doesn't. The problem is upstream of your router.")
        case .fine, .congested:
            let median = Formatting.milliseconds(stats.p50Milliseconds)
            let loss = stats.lossCount == 0 ? String(localized: "no loss") : String(format: String(localized: "%.1f%% loss"), stats.lossPercent)
            let summary = state.mode == .fine
                ? String(localized: "Healthy: \(median) median, \(loss).")
                : String(localized: "Slow: \(median) median, \(loss).")
            guard state.mode == .congested, let router = stats.gatewayP50Milliseconds else { return summary }
            return router > Thresholds.normalMilliseconds
                ? summary + " " + String(localized: "The link to your router is slow.")
                : summary + " " + String(localized: "Router is fine; the slowdown is upstream.")
        }
    }
}
