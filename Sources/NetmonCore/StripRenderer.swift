import AppKit
import Foundation

public enum StripRenderer {
    public static let statusSize = CGSize(width: 72, height: 22)
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

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let context = graphicsContext.cgContext
        context.saveGState()
        context.scaleBy(x: safeScale, y: safeScale)
        draw(
            samples: samples,
            state: state,
            size: size,
            windowSeconds: max(windowSeconds, 1),
            palette: palette
        )
        context.restoreGState()
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
        palette: RendererPalette = .fixture
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
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

        let horizontalPadding: CGFloat = size.width <= statusSize.width ? 1.5 : 4
        let baseline: CGFloat = size.height <= statusSize.height ? 5.5 : 10
        let railBottom: CGFloat = size.height <= statusSize.height ? 1.5 : 3
        let maxBarHeight = max(1, Int(size.height - baseline - 2))
        let referenceY = baseline + CGFloat(RTTScale.barHeight(milliseconds: 200, maxHeight: maxBarHeight))

        palette.hairline.setStroke()
        let reference = NSBezierPath()
        reference.lineWidth = size.height <= statusSize.height ? 0.5 : 0.75
        reference.move(to: CGPoint(x: horizontalPadding, y: referenceY))
        reference.line(to: CGPoint(x: size.width - horizontalPadding, y: referenceY))
        reference.stroke()

        let columns = max(windowSeconds, 1)
        let slotWidth = (size.width - horizontalPadding * 2) / CGFloat(columns)
        let visibleSamples = Array(samples.suffix(columns))
        let sampleOffset = columns - visibleSamples.count
        let ink = color(for: state.tone, palette: palette)
        let latestIndex = visibleSamples.count - 1

        for (index, sample) in visibleSamples.enumerated() {
            let column = sampleOffset + index
            let x = horizontalPadding + CGFloat(column) * slotWidth
            let barWidth = max(size.height <= statusSize.height ? 0.65 : 1.2, slotWidth * 0.72)
            let barX = x + (slotWidth - barWidth) / 2

            guard sample.outcome != .lost, let rtt = sample.rttMilliseconds else { continue }
            let barHeight = max(size.height <= statusSize.height ? 1.0 : 1.5, CGFloat(RTTScale.barHeight(milliseconds: rtt, maxHeight: maxBarHeight)))
            let rect = CGRect(x: barX, y: baseline, width: barWidth, height: barHeight)
            let isLatest = index == latestIndex
            let barColor = isLatest && state.pulseOn ? ink.withAlphaComponent(1) : ink

            if sample.outcome == .late {
                barColor.setStroke()
                let path = NSBezierPath(rect: rect.insetBy(dx: 0.15, dy: 0.15))
                path.lineWidth = size.height <= statusSize.height ? 0.7 : 1
                path.stroke()
            } else {
                barColor.setFill()
                NSBezierPath(rect: rect).fill()
            }
        }

        drawLossRail(
            samples: visibleSamples,
            sampleOffset: sampleOffset,
            columns: columns,
            slotWidth: slotWidth,
            horizontalPadding: horizontalPadding,
            baseline: baseline,
            railBottom: railBottom,
            color: state.tone == .red ? palette.red : (state.tone == .amber ? palette.amber : palette.rail)
        )

        if state.mode == .gatewayOnly {
            drawGatewayMarker(
                x: horizontalPadding + 1,
                y: baseline - 0.5,
                color: palette.amber,
                lineWidth: size.height <= statusSize.height ? 0.7 : 1
            )
        }

        if state.showsOutageDuration {
            drawOutageDuration(state.outageSeconds, in: size, color: palette.red)
        }
    }

    private static func drawLossRail(
        samples: [NetworkSample],
        sampleOffset: Int,
        columns: Int,
        slotWidth: CGFloat,
        horizontalPadding: CGFloat,
        baseline: CGFloat,
        railBottom: CGFloat,
        color: NSColor
    ) {
        guard !samples.isEmpty else { return }
        let runs = LossRuns.contiguous(in: samples)
        for run in runs {
            let startColumn = sampleOffset + run.start
            let endColumn = sampleOffset + run.end
            let xStart = horizontalPadding + CGFloat(startColumn) * slotWidth
            let xEnd = horizontalPadding + CGFloat(endColumn) * slotWidth
            color.setFill()

            if run.length >= 2 {
                NSBezierPath(rect: CGRect(x: xStart, y: railBottom, width: max(slotWidth, xEnd - xStart), height: max(1, baseline - railBottom - 1))).fill()
            } else {
                let centerX = (xStart + xEnd) / 2
                let tick = NSBezierPath()
                tick.lineWidth = max(0.7, slotWidth * 0.55)
                tick.move(to: CGPoint(x: centerX, y: baseline - 0.5))
                tick.line(to: CGPoint(x: centerX, y: railBottom))
                tick.stroke()
            }
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

    private static func drawOutageDuration(_ seconds: Int, in size: CGSize, color: NSColor) {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        let label = String(format: "%d:%02d", minutes, remainingSeconds)
        let font = NSFont.monospacedDigitSystemFont(ofSize: size.height <= statusSize.height ? 8.5 : 13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let point = CGPoint(x: max(2, size.width - textSize.width - 2), y: max(5, size.height - textSize.height - 1))
        (label as NSString).draw(at: point, withAttributes: attributes)
    }

    private static func color(for tone: RenderTone, palette: RendererPalette) -> NSColor {
        switch tone {
        case .monochrome: return palette.ink
        case .amber: return palette.amber
        case .red: return palette.red
        }
    }
}
