import NetmonCore
import SwiftUI

private struct PopoverTheme {
    let ink, sub, tile, bar, axis, threshold, normal, orange, orangeText, red, green, blue: Color

    init(dark: Bool) {
        func hex(_ value: UInt32, _ opacity: Double = 1) -> Color {
            Color(.sRGB, red: Double(value >> 16 & 0xff) / 255, green: Double(value >> 8 & 0xff) / 255, blue: Double(value & 0xff) / 255, opacity: opacity)
        }
        ink = hex(dark ? 0xF5F5F7 : 0x1D1D1F)
        sub = hex(dark ? 0xA1A1A6 : 0x5E5E63)
        tile = dark ? hex(0xFFFFFF, 0.06) : hex(0x000000, 0.045)
        bar = hex(dark ? 0xF5F5F7 : 0x1D1D1F, dark ? 0.42 : 0.34)
        axis = hex(dark ? 0xF5F5F7 : 0x1D1D1F, 0.25)
        threshold = dark ? hex(0xFF9F0A, 0.8) : hex(0xC25E00, 0.8)
        normal = dark ? hex(0x32D74B, 0.10) : hex(0x1E8E3E, 0.10)
        orange = hex(dark ? 0xFF9F0A : 0xE27100)
        orangeText = hex(dark ? 0xFFA826 : 0xA34A00)
        red = hex(dark ? 0xFF5A50 : 0xC8161E)
        green = hex(dark ? 0x32D74B : 0x1E8E3E)
        blue = hex(dark ? 0x0A84FF : 0x0071E3)
    }
}

struct PopoverView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var updateAvailability: UpdateAvailability
    @Environment(\.colorScheme) private var colorScheme

    private static let chartMaximum: Double = 2_500
    private static let mono = Font.system(size: 14, weight: .semibold, design: .monospaced)

    var body: some View {
        let theme = PopoverTheme(dark: colorScheme == .dark)
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

    private func header(theme: PopoverTheme, stats: WindowStats) -> some View {
        let (name, color): (LocalizedStringKey, Color) = switch model.state.mode {
        case .fine: ("Fine", theme.green)
        case .congested: ("Congested", theme.orange)
        case .gatewayOnly: ("Gateway only", theme.orange)
        case .dead: ("Dead", theme.red)
        }
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

    private func chart(theme: PopoverTheme) -> some View {
        let buckets = ChartBucket.buckets(samples: model.samples)
        let plotTop: CGFloat = 8
        let plotHeight: CGFloat = 100
        func y(_ milliseconds: Double) -> CGFloat {
            plotTop + plotHeight - CGFloat(min(milliseconds, Self.chartMaximum) / Self.chartMaximum) * plotHeight
        }
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                Canvas { context, size in
                    context.fill(Path(CGRect(x: 0, y: y(Thresholds.normalMilliseconds), width: size.width, height: y(0) - y(Thresholds.normalMilliseconds))), with: .color(theme.normal))
                    let slot = size.width / CGFloat(buckets.count)
                    for (index, bucket) in buckets.enumerated() {
                        guard let bucket else { continue }
                        let x = CGFloat(index) * slot
                        if let worst = bucket.worstMilliseconds {
                            let color = worst > Thresholds.lateMilliseconds ? theme.orange : theme.bar
                            context.fill(Path(CGRect(x: x, y: y(worst), width: slot - 1, height: y(0) - y(worst))), with: .color(color))
                        }
                        if bucket.hasLoss {
                            context.fill(Path(CGRect(x: x, y: 0, width: slot - 1, height: 2)), with: .color(bucket.hasOutage ? theme.red : theme.orange))
                        }
                    }
                    context.fill(Path(CGRect(x: 0, y: y(0), width: size.width, height: 1)), with: .color(theme.axis))
                    var limit = Path()
                    limit.move(to: CGPoint(x: 0, y: y(Thresholds.lateMilliseconds)))
                    limit.addLine(to: CGPoint(x: size.width, y: y(Thresholds.lateMilliseconds)))
                    context.stroke(limit, with: .color(theme.threshold), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                ZStack(alignment: .topLeading) {
                    Text(Formatting.milliseconds(Self.chartMaximum)).offset(y: 3)
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

    private func tiles(theme: PopoverTheme, stats: WindowStats) -> some View {
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

    private func pathSplit(theme: PopoverTheme, stats: WindowStats) -> some View {
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

    private func footer(theme: PopoverTheme) -> some View {
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
