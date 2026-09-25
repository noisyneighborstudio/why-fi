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

        let outageLabel = state.showsOutageDuration ? outageText(state.outageSeconds, isStatus: isStatus, color: palette.red) : nil
        let visibleSamples = Array(samples.suffix(columns))
        let sampleOffset = columns - visibleSamples.count
        let latestIndex = visibleSamples.count - 1

        // Gapless columns read as one skyline; only the bad seconds carry color.
        for (index, sample) in visibleSamples.enumerated() {
            guard let rtt = sample.rttMilliseconds else { continue }
            let barHeight = max(1, CGFloat(RTTScale.barHeight(milliseconds: rtt, maxHeight: maxBarHeight)))
            let color = sample.outcome == .late ? palette.amber : palette.ink
            // The newest column blinks so a frozen app is distinguishable from a dead link.
            (index == latestIndex && !state.pulseOn ? color.withAlphaComponent(0.35) : color).setFill()
            CGRect(x: originX + CGFloat(sampleOffset + index) * slotWidth, y: baseline, width: slotWidth, height: barHeight).fill()
        }

        // Contiguous loss merges into one slab. Three seconds or more is an outage: red when
        // nothing answers, amber when the gateway still does and only the internet is gone.
        let outageColor = state.mode == .gatewayOnly ? palette.amber : palette.red
        for run in LossRuns.contiguous(in: visibleSamples) {
            (run.length >= 3 ? outageColor : palette.amber).setFill()
            let x = originX + CGFloat(sampleOffset + run.start) * slotWidth
            CGRect(x: x, y: railBottom, width: CGFloat(run.length) * slotWidth - pixel, height: baseline - railBottom - 1).fill()
        }

        if let outageLabel {
            let labelSize = outageLabel.size()
            outageLabel.draw(at: CGPoint(x: max(2, size.width - labelSize.width - 2), y: max(5, size.height - labelSize.height - 1)))
        }
    }

    private static func outageText(_ seconds: Int, isStatus: Bool, color: NSColor) -> NSAttributedString {
        let label = String(format: "%d:%02d", seconds / 60, seconds % 60)
        let font = NSFont.monospacedDigitSystemFont(ofSize: isStatus ? 8.5 : 13, weight: .semibold)
        return NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
    }
}
