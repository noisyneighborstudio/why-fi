import Foundation

/// What the menu bar app hands the widget: the last five minutes, and the state at capture.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let mode: MonitorMode
    public let samples: [NetworkSample]

    public init(capturedAt: Date, mode: MonitorMode, samples: [NetworkSample]) {
        self.capturedAt = capturedAt
        self.mode = mode
        self.samples = samples
    }

    /// The widget stops showing data this long after capture, so a quit app never looks healthy.
    public static let staleAfter: TimeInterval = 600

    public var staleAt: Date { capturedAt.addingTimeInterval(Self.staleAfter) }
    public var stats: WindowStats { WindowStats(samples: samples) }
    /// State stats use the same one-minute window as the menu bar item.
    public var state: MonitorState { MonitorState(mode: mode, stats: WindowStats(samples: Array(samples.suffix(60)))) }
}

public enum NofiWidget {
    public static let kind = "NetworkQuality"
    /// Team-prefixed, so Developer ID builds use it without a provisioning profile.
    public static let appGroup = "P8ZBH5878Q.studio.noisyneighbor.nofi"
}

/// The snapshot file in the shared app-group container.
public struct SnapshotStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Nil when the process isn't entitled to the group (ad-hoc builds).
    public init?() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NofiWidget.appGroup) else { return nil }
        url = container.appendingPathComponent("snapshot.json")
    }

    public func write(_ snapshot: WidgetSnapshot) throws {
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    public func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

/// When to publish: WidgetKit rations reloads, so refresh on a state change (at most once a
/// minute, so flapping can't drain the budget) and otherwise every five minutes.
public struct WidgetRefreshPolicy: Sendable {
    public static let interval: TimeInterval = 300
    public static let minimumSpacing: TimeInterval = 60

    private var lastMode: MonitorMode?
    private var lastReload: Date?

    public init() {}

    public mutating func shouldPublish(mode: MonitorMode, now: Date) -> Bool {
        let elapsed = lastReload.map { now.timeIntervalSince($0) } ?? .infinity
        guard elapsed >= Self.interval || (mode != lastMode && elapsed >= Self.minimumSpacing) else { return false }
        lastMode = mode
        lastReload = now
        return true
    }
}
