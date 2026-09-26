import SwiftUI

/// Colors shared by the popover and the widgets.
public struct NofiTheme {
    public let ink, sub, tile, bar, axis, threshold, normal, orange, orangeText, red, green, blue: Color

    public init(dark: Bool) {
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

    public func stateColor(_ mode: MonitorMode) -> Color {
        switch mode {
        case .fine: return green
        case .congested, .gatewayOnly: return orange
        case .dead: return red
        }
    }
}

public enum LatencyChart {
    /// Linear scale's top; the popover's top label reads this.
    public static let maximum: Double = 2_500
    /// Room above the plot for loss dots.
    public static let plotTop: CGFloat = 8

    public enum Scale: Sendable {
        /// The popover: reads absolute differences, but hides healthy replies.
        case linear
        /// The menu bar's scale: healthy replies stay visible, and 1 s sits at the same height.
        case log
    }

    public static func y(_ milliseconds: Double, height: CGFloat, scale: Scale = .linear) -> CGFloat {
        let plot = height - plotTop - 4
        let fraction = scale == .linear ? min(milliseconds, maximum) / maximum : RTTScale.fraction(milliseconds: milliseconds)
        return plotTop + plot - CGFloat(fraction) * plot
    }
}

/// Five minutes as 100 three-second columns: the worst reply per column, dots for loss.
public struct LatencyChartCanvas: View {
    let samples: [NetworkSample]
    let theme: NofiTheme
    let scale: LatencyChart.Scale

    public init(samples: [NetworkSample], theme: NofiTheme, scale: LatencyChart.Scale = .linear) {
        self.samples = samples
        self.theme = theme
        self.scale = scale
    }

    public var body: some View {
        let buckets = ChartBucket.buckets(samples: samples)
        Canvas { context, size in
            func y(_ milliseconds: Double) -> CGFloat { LatencyChart.y(milliseconds, height: size.height, scale: scale) }
            context.fill(Path(CGRect(x: 0, y: y(Thresholds.normalMilliseconds), width: size.width, height: y(0) - y(Thresholds.normalMilliseconds))), with: .color(theme.normal))
            let slot = size.width / CGFloat(buckets.count)
            let gap = min(1, slot / 3)
            for (index, bucket) in buckets.enumerated() {
                guard let bucket else { continue }
                let x = CGFloat(index) * slot
                if let worst = bucket.worstMilliseconds {
                    let color = worst > Thresholds.lateMilliseconds ? theme.orange : theme.bar
                    context.fill(Path(CGRect(x: x, y: y(worst), width: slot - gap, height: y(0) - y(worst))), with: .color(color))
                }
                if bucket.hasLoss {
                    context.fill(Path(CGRect(x: x, y: 0, width: slot - gap, height: 2)), with: .color(bucket.hasOutage ? theme.red : theme.orange))
                }
            }
            context.fill(Path(CGRect(x: 0, y: y(0), width: size.width, height: 1)), with: .color(theme.axis))
            var limit = Path()
            limit.move(to: CGPoint(x: 0, y: y(Thresholds.lateMilliseconds)))
            limit.addLine(to: CGPoint(x: size.width, y: y(Thresholds.lateMilliseconds)))
            context.stroke(limit, with: .color(theme.threshold), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }
}

public enum WidgetLayout: Sendable {
    case small
    case medium
}

/// Widget body, drawn from a snapshot. Lives here so the fixture renderer can draw it too.
public struct WidgetContentView: View {
    let snapshot: WidgetSnapshot?
    let isStale: Bool
    let layout: WidgetLayout
    let theme: NofiTheme

    public init(snapshot: WidgetSnapshot?, isStale: Bool, layout: WidgetLayout, theme: NofiTheme) {
        self.snapshot = snapshot
        self.isStale = isStale
        self.layout = layout
        self.theme = theme
    }

    public var body: some View {
        if let snapshot, !isStale {
            live(snapshot)
        } else {
            unavailable
        }
    }

    private func live(_ snapshot: WidgetSnapshot) -> some View {
        let state = snapshot.state
        let summary = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(theme.stateColor(state.mode)).frame(width: 7, height: 7)
                Text(Self.name(state.mode)).font(.system(size: 13, weight: .semibold)).foregroundColor(theme.ink)
            }
            Spacer(minLength: 4)
            headline(state)
            Text(detail(state)).font(.system(size: 11)).foregroundColor(theme.sub).lineLimit(1)
            Spacer(minLength: 4)
            (Text("Updated ") + Text(snapshot.capturedAt, style: .time))
                .font(.system(size: 10))
                .foregroundColor(theme.sub)
                .lineLimit(1)
        }
        return Group {
            switch layout {
            case .small:
                VStack(alignment: .leading, spacing: 6) {
                    summary
                    LatencyChartCanvas(samples: snapshot.samples, theme: theme, scale: .log).frame(height: 30)
                }
            case .medium:
                HStack(spacing: 14) {
                    summary.frame(width: 118, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        LatencyChartCanvas(samples: snapshot.samples, theme: theme, scale: .log)
                        HStack {
                            Text("5m ago")
                            Spacer()
                            Text("1s limit").foregroundColor(theme.orangeText)
                            Spacer()
                            Text("now")
                        }
                        .font(.system(size: 9))
                        .foregroundColor(theme.sub)
                    }
                }
            }
        }
    }

    private func headline(_ state: MonitorState) -> some View {
        let (text, color): (String, Color)
        switch state.mode {
        case .dead: (text, color) = (Formatting.duration(state.outageSeconds), theme.red)
        case .gatewayOnly: (text, color) = (String(localized: "LAN only"), theme.orangeText)
        case .fine, .congested:
            let median = state.stats.p50Milliseconds
            (text, color) = (Formatting.milliseconds(median), (median ?? 0) > Thresholds.normalMilliseconds ? theme.orangeText : theme.ink)
        }
        return Text(text)
            .font(.system(size: layout == .small ? 26 : 28, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func detail(_ state: MonitorState) -> String {
        switch state.mode {
        case .dead: return String(localized: "no replies")
        case .gatewayOnly: return String(localized: "router answers")
        case .fine, .congested:
            return state.stats.lossCount == 0
                ? String(localized: "median, no loss")
                : String(format: String(localized: "median, %.1f%% loss"), state.stats.lossPercent)
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(theme.sub).frame(width: 7, height: 7)
                Text("No recent data").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.ink)
            }
            Spacer(minLength: 0)
            Text(snapshot == nil ? "Open nofi to start monitoring." : "nofi isn't running, so this can't update.")
                .font(.system(size: 11))
                .foregroundColor(theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            if let snapshot {
                (Text("Last update ") + Text(snapshot.capturedAt, style: .time))
                .font(.system(size: 10))
                .foregroundColor(theme.sub)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    public static func name(_ mode: MonitorMode) -> LocalizedStringKey {
        switch mode {
        case .fine: return "Fine"
        case .congested: return "Congested"
        case .gatewayOnly: return "Gateway only"
        case .dead: return "Dead"
        }
    }
}
