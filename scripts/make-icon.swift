import AppKit
// make-icon <out.png> — draw the nofi app icon: the handoff's large pulse ("Pulse · large",
// fine state) and its green quality dot on a dark macOS app-icon tile.
//   swift scripts/make-icon.swift Resources/nofi.png
// Apple's 1024 grid: the tile is 824x824, inset 100, with a soft drop shadow. The outline is
// a superellipse (continuous curvature), which is what the system icons use.
let S = 1024.0, tile = 824.0, inset = (S - tile) / 2

func squircle(_ r: NSRect, n: Double = 5.0, steps: Int = 720) -> NSBezierPath {
    let p = NSBezierPath()
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = NSPoint(x: r.midX + r.width / 2 * copysign(pow(abs(c), 2 / n), c),
                            y: r.midY + r.height / 2 * copysign(pow(abs(s), 2 / n), s))
        i == 0 ? p.move(to: point) : p.line(to: point)
    }
    p.close()
    return p
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext
let body = NSRect(x: inset, y: inset, width: tile, height: tile)
let path = squircle(body)

// Shadow pass: Apple's template uses a ~28pt blur, 12pt downward offset.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.set()
NSColor.black.setFill()
path.fill()
NSGraphicsContext.restoreGraphicsState()

// Tile: the dark menu bar ink, lifting slightly toward the top.
let top = NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1)
let bottom = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
NSGraphicsContext.saveGraphicsState()
path.addClip()
NSGradient(starting: bottom, ending: top)!.draw(in: body, angle: 90)
NSGraphicsContext.restoreGraphicsState()

// Glyph in its 18x14 design space (y-down, as in the handoff SVG), centered on its ink bounds.
let stroke = 1.7, ink = CGRect(x: 1 - stroke / 2, y: 3 - stroke / 2, width: 18.3 - (1 - stroke / 2), height: 14.3 - (3 - stroke / 2))
let scale = 560 / ink.width
context.saveGState()
context.translateBy(x: S / 2 - ink.midX * scale, y: S / 2 + ink.midY * scale)
context.scaleBy(x: scale, y: -scale)
context.setLineWidth(stroke)
context.setLineCap(.round)
context.setLineJoin(.round)
context.setStrokeColor(NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).cgColor)
context.move(to: CGPoint(x: 1, y: 8))
[(5.5, 8), (7.5, 3), (10, 12.5), (11.8, 8), (15, 8)].forEach { context.addLine(to: CGPoint(x: $0.0, y: $0.1)) }
context.strokePath()
context.restoreGState()

// Quality dot r 2.7 at (15.6, 11.6) with a 1.5 knockout ring. The ring is cut by redrawing
// the tile gradient inside it, so it reads as a gap in the trace, not a darker disk.
func device(_ x: Double, _ y: Double) -> NSPoint {
    NSPoint(x: S / 2 - ink.midX * scale + x * scale, y: S / 2 + ink.midY * scale - y * scale)
}
let dot = device(15.6, 11.6)
func disk(_ radius: Double) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: dot.x - radius * scale, y: dot.y - radius * scale, width: 2 * radius * scale, height: 2 * radius * scale))
}
NSGraphicsContext.saveGraphicsState()
disk(3.45).addClip()
NSGradient(starting: bottom, ending: top)!.draw(in: body, angle: 90)
NSGraphicsContext.restoreGraphicsState()
NSColor(srgbRed: 0.196, green: 0.843, blue: 0.294, alpha: 1).setFill()
disk(1.95).fill()

// Hairline inner stroke so the tile edge holds against a dark Dock.
NSColor(white: 1, alpha: 0.08).setStroke()
path.lineWidth = 2
path.stroke()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
