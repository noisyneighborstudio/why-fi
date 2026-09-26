import NetmonCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var updateAvailability: UpdateAvailability
    @Environment(\.colorScheme) private var colorScheme

    private static let mono = Font.system(size: 14, weight: .semibold, design: .monospaced)

    var body: some View {
        let theme = NofiTheme(dark: colorScheme == .dark)
        // The popover spans the full 5-minute buffer, so its numbers do too.
        let stats = WindowStats(samples: model.samples)
        VStack(alignment: .leading, spacing: 14) {
            header(theme: theme, stats: stats)
            chart(theme: theme)
            tiles(theme: theme, stats: stats)
            pathSplit(theme: theme, stats: stats)
            footer(theme: theme)
        }
        .padding(16)
        .frame(width: 360)
        .foregroundColor(theme.ink)
    }

    private func header(theme: NofiTheme, stats: WindowStats) -> some View {
        let name = WidgetContentView.name(model.state.mode)
        let color = theme.stateColor(model.state.mode)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(model.state.hasData ? name : "Waiting for first probe").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Last 5 min").font(.system(size: 11)).foregroundColor(theme.sub)
            }
            Text(model.failure ?? (model.state.hasData ? Verdict.text(state: model.state, stats: stats) : ""))
                .font(.system(size: 12))
                .foregroundColor(theme.sub)
                .padding(.leading, 15)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chart(theme: NofiTheme) -> some View {
        func y(_ milliseconds: Double) -> CGFloat { LatencyChart.y(milliseconds, height: 112) }
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                LatencyChartCanvas(samples: model.samples, theme: theme)
                ZStack(alignment: .topLeading) {
                    Text(Formatting.milliseconds(LatencyChart.maximum)).offset(y: 3)
                    Text("1s limit").foregroundColor(theme.orangeText).offset(y: y(Thresholds.lateMilliseconds) - 6)
                    Text("0").offset(y: y(0) - 12)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.sub)
                .fixedSize()
                .frame(width: 44, height: 112, alignment: .topLeading)
            }
            .frame(height: 112)
            HStack {
                Text("5m ago")
                Spacer()
                Text("now")
            }
            .font(.system(size: 10))
            .foregroundColor(theme.sub)
            .padding(.trailing, 50)
        }
    }

    private func tiles(theme: NofiTheme, stats: WindowStats) -> some View {
        func latencyColor(_ value: Double?) -> Color {
            (value ?? 0) > Thresholds.normalMilliseconds ? theme.orangeText : theme.ink
        }
        let items: [(LocalizedStringKey, String, Color)] = [
            ("Median", Formatting.milliseconds(stats.p50Milliseconds), latencyColor(stats.p50Milliseconds)),
            ("p95", Formatting.milliseconds(stats.p95Milliseconds), latencyColor(stats.p95Milliseconds)),
            ("Loss", String(format: "%.1f%%", stats.lossPercent), stats.lossPercent > 1 ? theme.orangeText : theme.ink),
            ("Longest out", "\(stats.longestLossRun)s", stats.longestLossRun >= Thresholds.outageSeconds ? theme.orangeText : theme.ink)
        ]
        return HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    Text(items[index].0).font(.system(size: 10)).foregroundColor(theme.sub)
                    Text(items[index].1).font(Self.mono).foregroundColor(items[index].2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.tile))
            }
        }
    }

    private func pathSplit(theme: NofiTheme, stats: WindowStats) -> some View {
        let router = stats.gatewayP50Milliseconds
        let upstream = zip(stats.p50Milliseconds, router).map { max(0, $0 - $1) }
        func row(_ title: LocalizedStringKey, _ value: String, bad: Bool) -> some View {
            HStack {
                Text(title).foregroundColor(theme.sub)
                Spacer()
                Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(bad ? theme.orangeText : theme.ink)
            }
            .font(.system(size: 12))
        }
        return VStack(spacing: 6) {
            row("Mac → Router", router.map { Formatting.milliseconds($0) } ?? String(localized: "no ping reply"), bad: (router ?? 0) > Thresholds.normalMilliseconds)
            row("Router → Internet", Formatting.milliseconds(upstream), bad: (upstream ?? 0) > Thresholds.normalMilliseconds)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(theme.tile))
    }

    private func footer(theme: NofiTheme) -> some View {
        VStack(spacing: 10) {
            Divider()
            HStack {
                Text("Menu bar").font(.system(size: 12)).foregroundColor(theme.sub)
                Spacer()
                Picker("Menu bar", selection: $model.displayMode) {
                    Text("Auto").tag(DisplayMode.auto)
                    Text("Icon").tag(DisplayMode.compact)
                    Text("Graph").tag(DisplayMode.expanded)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if updateAvailability.updater != nil {
                Button {
                    updateAvailability.checkForUpdates()
                } label: {
                    HStack {
                        if let version = updateAvailability.pendingVersion {
                            Circle().fill(theme.blue).frame(width: 6, height: 6)
                            Text("Update to \(version) available")
                                .foregroundColor(theme.blue)
                        } else {
                            Text("Check for Updates…")
                        }
                        Spacer()
                        Image(systemName: updateAvailability.pendingVersion == nil ? "arrow.clockwise" : "arrow.down.circle")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(updateAvailability.canCheckForUpdates ? theme.sub : theme.sub.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!updateAvailability.canCheckForUpdates)
            }
        }
    }
}

private func zip(_ first: Double?, _ second: Double?) -> (Double, Double)? {
    guard let first, let second else { return nil }
    return (first, second)
}
