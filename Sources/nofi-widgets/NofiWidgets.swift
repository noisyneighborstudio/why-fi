import NetmonCore
import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let isStale: Bool
}

/// Reads the menu bar app's latest snapshot. The widget can't probe the network itself, so it
/// shows what nofi last measured and flips to "No recent data" once that goes stale.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: nil, isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = SnapshotStore()?.read()
        completion(SnapshotEntry(date: .now, snapshot: snapshot, isStale: snapshot.map { Date.now >= $0.staleAt } ?? true))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date.now
        guard let snapshot = SnapshotStore()?.read() else {
            completion(Timeline(entries: [SnapshotEntry(date: now, snapshot: nil, isStale: true)], policy: .after(now.addingTimeInterval(900))))
            return
        }
        var entries = [SnapshotEntry(date: now, snapshot: snapshot, isStale: now >= snapshot.staleAt)]
        if now < snapshot.staleAt {
            entries.append(SnapshotEntry(date: snapshot.staleAt, snapshot: snapshot, isStale: true))
        }
        // The app reloads on every publish; this only rechecks after nofi has gone quiet.
        completion(Timeline(entries: entries, policy: .after(max(now, snapshot.staleAt).addingTimeInterval(900))))
    }
}

struct NofiWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: SnapshotEntry

    var body: some View {
        WidgetContentView(
            snapshot: entry.snapshot,
            isStale: entry.isStale,
            layout: family == .systemMedium ? .medium : .small,
            theme: NofiTheme(dark: colorScheme == .dark)
        )
        .containerBackground(.background, for: .widget)
    }
}

struct NetworkQualityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NofiWidget.kind, provider: SnapshotProvider()) { NofiWidgetView(entry: $0) }
            .configurationDisplayName("Network Quality")
            .description("Latency and loss from the last five minutes, as measured by nofi.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct NofiWidgets: WidgetBundle {
    var body: some Widget {
        NetworkQualityWidget()
    }
}
