import AppKit

/// Menu bar colors. Resolved from the status button's appearance, not the app's.
public struct StatusPalette {
    public let fg, bar, grid, orange, orangeText, red, green: NSColor

    public init(dark: Bool) {
        func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255, blue: CGFloat(value & 0xff) / 255, alpha: alpha)
        }
        let ink: UInt32 = dark ? 0xF5F5F7 : 0x1D1D1F
        fg = hex(ink)
        bar = hex(ink, dark ? 0.5 : 0.42)
        grid = hex(ink, dark ? 0.2 : 0.18)
        orange = hex(dark ? 0xFF9F0A : 0xE27100)
        orangeText = hex(dark ? 0xFFA826 : 0xA34A00)
        red = hex(dark ? 0xFF5A50 : 0xC8161E)
        green = hex(dark ? 0x32D74B : 0x1E8E3E)
    }
}

public enum StatusRenderer {
    public static let height: CGFloat = 22
    public static let columns = 30
    static let padding: CGFloat = 6
    static let gap: CGFloat = 6
    static let glyphWidth: CGFloat = 18
    static let sparklineWidth: CGFloat = 89
    static let sparklineX = padding + glyphWidth + gap
    static let baseline: CGFloat = 18
    static let labelFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

    /// `reveal` runs from 0 (icon only) to 1 (graph and label); in between, the item is
    /// partway wide, the graph and label fade in as they are uncovered, and the glyph crossfades.
    public static func image(samples: [NetworkSample], state: MonitorState, reveal: CGFloat, dark: Bool, scale: CGFloat = 2) -> NSImage {
        let palette = StatusPalette(dark: dark)
        let reveal = min(max(reveal, 0), 1)
        let label = labelText(state: state, palette: palette)
        let compact = padding + glyphWidth + padding
        // Whole pixels keep every frame crisp.
        let width = ((compact + (expandedWidth(label: label) - compact) * reveal) * scale).rounded() / scale
        let size = CGSize(width: width, height: height)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }
        bitmap.size = size
        guard let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else { return NSImage(size: size) }
        // bitmap.size is in points, so the context already maps points to pixels.
        // Flip to y-down so the handoff's SVG coordinates apply unchanged.
        let context = bitmapContext.cgContext
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // Transparency layers keep each layer's knockouts from clearing the other.
        func layer(_ alpha: CGFloat, _ draw: () -> Void) {
            guard alpha > 0 else { return }
            context.saveGState()
            context.setAlpha(alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            draw()
            context.endTransparencyLayer()
            context.restoreGState()
        }
        layer(1 - reveal) { drawGlyph(in: context, state: state, expanded: false, palette: palette) }
        layer(reveal) {
            drawGlyph(in: context, state: state, expanded: true, palette: palette)
            // Graph and label ride the right edge, so the label and newest bars show first
            // and older history slides out from behind the glyph.
            context.clip(to: CGRect(x: sparklineX, y: 0, width: max(0, width - sparklineX), height: height))
            context.translateBy(x: width - expandedWidth(label: label), y: 0)
            drawSparkline(in: context, samples: Array(samples.suffix(columns)), palette: palette)
            let labelSize = label.size()
            label.draw(at: CGPoint(x: sparklineX + sparklineWidth + gap, y: ((height - labelSize.height) / 2).rounded()))
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    public static func accessibilityLabel(for state: MonitorState) -> String {
        guard state.hasData else { return String(localized: "Network monitor waiting for first probe") }
        let median = state.stats.p50Milliseconds.map { Int($0.rounded()) } ?? 0
        switch state.mode {
        case .fine: return String(localized: "Network fine, \(median) milliseconds")
        case .congested:
            return state.stats.lossCount > 0
                ? String(localized: "Network congested, \(median) milliseconds, packet loss")
                : String(localized: "Network congested, \(median) milliseconds")
        case .dead: return String(localized: "Network down for \(state.outageSeconds) seconds")
        case .gatewayOnly: return String(localized: "Router reachable, internet unreachable")
        }
    }

    private static func expandedWidth(label: NSAttributedString) -> CGFloat {
        // Reserve five digits so the item doesn't shift as the number changes.
        let field = max(label.size().width, NSAttributedString(string: "00000", attributes: [.font: labelFont]).size().width)
        return (sparklineX + sparklineWidth + gap + field + padding).rounded(.up)
    }

    private static func labelText(state: MonitorState, palette: StatusPalette) -> NSAttributedString {
        let (text, color): (String, NSColor)
        switch state.mode {
        case .fine: (text, color) = (Formatting.milliseconds(state.stats.p50Milliseconds), palette.fg)
        case .congested: (text, color) = (Formatting.milliseconds(state.stats.p50Milliseconds), palette.orangeText)
        case .dead: (text, color) = (Formatting.duration(state.outageSeconds), palette.red)
        case .gatewayOnly: (text, color) = (String(localized: "LAN only"), palette.orangeText)
        }
        return NSAttributedString(string: text, attributes: [.font: labelFont, .foregroundColor: color, .kern: -0.2])
    }

    private static func drawGlyph(in context: CGContext, state: MonitorState, expanded: Bool, palette: StatusPalette) {
        var opacity: [CGFloat] = [1, 1, 1] // inner arc and dot, middle arc, outer arc
        var badge: NSColor?
        var slash = false
        switch state.mode {
        case .fine: badge = expanded ? nil : palette.green
        case .congested: badge = palette.orange
        case .gatewayOnly: opacity = [1, 0.28, 0.28]; badge = palette.orange
        case .dead:
            opacity = [0.35, 0.35, 0.35]
            // Slash plus badge is too busy at 18pt; icon-only carries it with a red dot.
            if expanded { slash = true } else { badge = palette.red }
        }
        if !state.hasData { opacity = [0.35, 0.35, 0.35]; badge = nil; slash = false }

        context.saveGState()
        context.translateBy(x: padding, y: (height - 14) / 2)
        let center = CGPoint(x: 9, y: 12.5)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        for (radius, alpha) in zip([4.0, 7.5, 11.0], opacity) {
            context.setStrokeColor(palette.fg.withAlphaComponent(alpha).cgColor)
            context.addArc(center: center, radius: radius, startAngle: -.pi * 3 / 4, endAngle: -.pi / 4, clockwise: false)
            context.strokePath()
        }
        context.setFillColor(palette.fg.withAlphaComponent(opacity[0]).cgColor)
        context.fillEllipse(in: CGRect(x: center.x - 1.4, y: center.y - 1.4, width: 2.8, height: 2.8))

        // Knockouts clear to transparent so the menu bar shows through, whatever its color.
        if slash {
            context.move(to: CGPoint(x: 2, y: 0.8))
            context.addLine(to: CGPoint(x: 16, y: 13.6))
            context.setBlendMode(.clear)
            context.setLineWidth(3.8)
            context.strokePath()
            context.setBlendMode(.normal)
            context.move(to: CGPoint(x: 2, y: 0.8))
            context.addLine(to: CGPoint(x: 16, y: 13.6))
            context.setStrokeColor(palette.red.cgColor)
            context.setLineWidth(1.7)
            context.strokePath()
        }
        if let badge {
            // r 2.7 with a centered 1.5pt ring: knock out to 3.45, fill to 1.95.
            let badgeCenter = CGPoint(x: 15.6, y: 11.6)
            context.setBlendMode(.clear)
            context.fillEllipse(in: CGRect(x: badgeCenter.x - 3.45, y: badgeCenter.y - 3.45, width: 6.9, height: 6.9))
            context.setBlendMode(.normal)
            context.setFillColor(badge.cgColor)
            context.fillEllipse(in: CGRect(x: badgeCenter.x - 1.95, y: badgeCenter.y - 1.95, width: 3.9, height: 3.9))
        }
        context.restoreGState()
    }

    private static func drawSparkline(in context: CGContext, samples: [NetworkSample], palette: StatusPalette) {
        context.setFillColor(palette.grid.cgColor)
        context.fill(CGRect(x: sparklineX, y: baseline - RTTScale.thresholdHeight - 1, width: sparklineWidth, height: 1))

        let outage = LossRuns.outageIndices(in: samples)
        let offset = columns - samples.count
        for (index, sample) in samples.enumerated() {
            let x = sparklineX + CGFloat(offset + index) * 3
            func bar(_ milliseconds: Double, _ color: NSColor) {
                let barHeight = RTTScale.barHeight(milliseconds: milliseconds)
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: x, y: baseline - barHeight, width: 2, height: barHeight))
            }
            func mark(_ color: NSColor, top: Bool) {
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: x, y: top ? baseline - RTTScale.height : baseline - 2, width: 2, height: 2))
            }
            if let rtt = sample.rttMilliseconds {
                bar(rtt, sample.outcome == .late ? palette.orange : palette.bar)
            } else if let gateway = sample.gatewayMilliseconds {
                // The router answered this second but the internet didn't.
                bar(gateway, palette.bar)
                mark(palette.orange, top: true)
            } else if outage.contains(index) {
                mark(palette.red, top: false)
            } else {
                mark(palette.orange, top: true)
            }
        }
    }
}
