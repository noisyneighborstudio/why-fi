import AppKit
import Foundation

public enum StripRenderer {
    /// 60 slots of 1.5pt (3px at 2x) plus 1pt padding each side.
    public static let statusSize = CGSize(width: 92, height: 22)
    public static let popoverSize = CGSize(width: 440, height: 94)

    public static func image(
        samples: [NetworkSample],
        state: MonitorState,
        size: CGSize = statusSize,
        windowSeconds: Int = 60,
        scale: CGFloat = 2,
        palette: RendererPalette = .menuBar
    ) -> NSImage {
        let safeScale = max(scale, 1)
        let pixelsWide = max(1, Int((size.width * safeScale).rounded()))
        let pixelsHigh = max(1, Int((size.height * safeScale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }

        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)

        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return image
        }

        // bitmap.size is in points, so the context already maps points to pixels.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        draw(
            samples: samples,
            state: state,
            size: size,
            windowSeconds: max(windowSeconds, 1),
            palette: palette
        )
        NSGraphicsContext.restoreGraphicsState()
        return image
    }

    public static func writePNG(
        samples: [NetworkSample],
        state: MonitorState,
        to url: URL,
        size: CGSize = statusSize,
        windowSeconds: Int = 60,
        scale: CGFloat = 2,
        palette: RendererPalette = .menuBar
    ) throws {
        let image = image(
            samples: samples,
            state: state,
            size: size,
            windowSeconds: windowSeconds,
            scale: scale,
            palette: palette
        )
        guard let representation = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let data = representation.representation(using: .png, properties: [:]) else {
            throw RendererError.couldNotEncodePNG
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public enum RendererError: Error {
        case couldNotEncodePNG
    }

    private static func draw(
        samples: [NetworkSample],
        state: MonitorState,
        size: CGSize,
        windowSeconds: Int,
        palette: RendererPalette
    ) {
        palette.background.setFill()
        CGRect(origin: .zero, size: size).fill()

        // Snap to the 2x pixel grid; fractional slots smear every bar edge.
        let pixel: CGFloat = 0.5
        let isStatus = size.height <= statusSize.height
        let horizontalPadding: CGFloat = isStatus ? 1 : 4
        let baseline: CGFloat = isStatus ? 5.5 : 10
        let railBottom: CGFloat = isStatus ? 1.5 : 3
        let maxBarHeight = max(1, Int(size.height - baseline - 2))
        let columns = windowSeconds
        let available = size.width - horizontalPadding * 2
        let slotWidth = max(pixel * 2, (available / CGFloat(columns) / pixel).rounded(.down) * pixel)
        let originX = horizontalPadding + ((available - slotWidth * CGFloat(columns)) / 2 / pixel).rounded(.down) * pixel
        let barWidth = slotWidth - pixel
        let stripEnd = originX + slotWidth * CGFloat(columns) - pixel

        let outageLabel = state.showsOutageDuration ? outageText(state.outageSeconds, isStatus: isStatus, color: palette.red) : nil
        let labelOrigin = outageLabel.map {
            CGPoint(x: max(2, size.width - $0.size().width - 2), y: max(5, size.height - $0.size().height - 1))
        }

        let referenceY = baseline + CGFloat(RTTScale.barHeight(milliseconds: 200, maxHeight: maxBarHeight))
        let referenceEnd = labelOrigin.map { min(stripEnd, $0.x - 1) } ?? stripEnd
        palette.hairline.setFill()
        CGRect(x: originX, y: referenceY, width: max(0, referenceEnd - originX), height: pixel).fill()

        let visibleSamples = Array(samples.suffix(columns))
        let sampleOffset = columns - visibleSamples.count
        let ink = color(for: state.tone, palette: palette)
        let latestIndex = visibleSamples.count - 1

        for (index, sample) in visibleSamples.enumerated() {
            guard sample.outcome != .lost, let rtt = sample.rttMilliseconds else { continue }
            let barX = originX + CGFloat(sampleOffset + index) * slotWidth
            let barHeight = max(1, CGFloat(RTTScale.barHeight(milliseconds: rtt, maxHeight: maxBarHeight)))
            let rect = CGRect(x: barX, y: baseline, width: barWidth, height: barHeight)
            // The newest column blinks so a frozen app is distinguishable from a dead link.
            let barColor = index == latestIndex && !state.pulseOn ? ink.withAlphaComponent(0.35) : ink

            if sample.outcome == .late {
                // Too narrow to outline; a dim body under a solid cap reads as hollow.
                barColor.withAlphaComponent(0.3).setFill()
                rect.fill()
                barColor.setFill()
                CGRect(x: barX, y: rect.maxY - 1, width: barWidth, height: 1).fill()
            } else {
                barColor.setFill()
                rect.fill()
            }
        }

        // Contiguous loss merges into one slab so run length reads directly.
        let railColor = state.tone == .red ? palette.red : (state.tone == .amber ? palette.amber : palette.rail)
        railColor.setFill()
        for run in LossRuns.contiguous(in: visibleSamples) {
            let x = originX + CGFloat(sampleOffset + run.start) * slotWidth
            CGRect(x: x, y: railBottom, width: CGFloat(run.length) * slotWidth - pixel, height: baseline - railBottom - 1).fill()
        }

        if state.mode == .gatewayOnly {
            drawGatewayMarker(
                x: originX,
                y: baseline - 0.5,
                color: palette.amber,
                lineWidth: isStatus ? 0.7 : 1
            )
        }

        if let outageLabel, let labelOrigin {
            outageLabel.draw(at: labelOrigin)
        }
    }

    private static func drawGatewayMarker(x: CGFloat, y: CGFloat, color: NSColor, lineWidth: CGFloat) {
        color.setStroke()
        let marker = NSBezierPath()
        marker.lineWidth = lineWidth
        marker.move(to: CGPoint(x: x, y: y))
        marker.line(to: CGPoint(x: x + 3, y: y))
        marker.line(to: CGPoint(x: x + 3, y: y + 2.5))
        marker.move(to: CGPoint(x: x + 4.5, y: y))
        marker.line(to: CGPoint(x: x + 7.5, y: y))
        marker.line(to: CGPoint(x: x + 7.5, y: y + 2.5))
        marker.stroke()
    }

    private static func outageText(_ seconds: Int, isStatus: Bool, color: NSColor) -> NSAttributedString {
        let label = String(format: "%d:%02d", seconds / 60, seconds % 60)
        let font = NSFont.monospacedDigitSystemFont(ofSize: isStatus ? 8.5 : 13, weight: .semibold)
        return NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
    }

    private static func color(for tone: RenderTone, palette: RendererPalette) -> NSColor {
        switch tone {
        case .monochrome: return palette.ink
        case .amber: return palette.amber
        case .red: return palette.red
        }
    }
}
