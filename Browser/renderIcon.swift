// MiniBrowser (c) 2026 Trendzza. All rights reserved.
// Free forever, non-commercial — see LICENSE.
import AppKit

// MiniBrowser v2 icon — AI-designed mark
// A bold "M" monogram formed from three overlapping browser "window / tab" bars,
// floating on a deep-space gradient. Color story: aurora teal -> indigo -> violet,
// deliberately distinct from Brave's orange to avoid brand confusion.

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let cx = CGFloat(size) / 2

// ---- Background: deep rounded square with diagonal aurora gradient ----
let bg = NSBezierPath(roundedRect: rect, xRadius: CGFloat(size) * 0.223, yRadius: CGFloat(size) * 0.223)
let bgGradient = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.16, alpha: 1), 0.0),
    (NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.30, alpha: 1), 0.55),
    (NSColor(calibratedRed: 0.20, green: 0.10, blue: 0.34, alpha: 1), 1.0))
bgGradient?.draw(in: bg, angle: -135)
bg.addClip()

// ---- Subtle radial glow behind the mark ----
let glow = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.98, blue: 0.95, alpha: 0.20),
    NSColor.clear
])!
glow.draw(fromCenter: NSPoint(x: cx, y: cx), radius: CGFloat(size) * 0.04,
          toCenter: NSPoint(x: cx, y: cx), radius: CGFloat(size) * 0.52, options: [.drawsBeforeStartingLocation])

// ---- The "M" mark: three overlapping browser-window bars ----
// Each bar: a rounded rectangle with an extended chrome "tab" at its top,
// tipped -8° for a dynamic, modern feel.

func windowBar(width: CGFloat, topY: CGFloat, height: CGFloat) -> NSBezierPath {
    let r: CGFloat = 46
    let left = cx - width / 2
    let bottom = topY - height
    let p = NSBezierPath()
    p.move(to: NSPoint(x: left, y: bottom))
    p.line(to: NSPoint(x: left, y: topY - r))
    p.curve(to: NSPoint(x: left + r, y: topY),
            controlPoint1: NSPoint(x: left, y: topY - r * 0.3),
            controlPoint2: NSPoint(x: left + r * 0.3, y: topY))
    p.line(to: NSPoint(x: left + width - r, y: topY))
    p.curve(to: NSPoint(x: left + width, y: topY - r),
            controlPoint1: NSPoint(x: left + width - r * 0.3, y: topY),
            controlPoint2: NSPoint(x: left + width, y: topY - r * 0.3))
    p.line(to: NSPoint(x: left + width, y: bottom))
    p.close()
    return p
}

// Geometry of a stylized M formed by 3 overlapping bars
let barW = CGFloat(size) * 0.27
let barH = CGFloat(size) * 0.60
let xLeft  = cx - barW * 0.92
let xMid   = cx - barW * 0.46
let xRight = cx + barW * 0.10

let bars: [(NSBezierPath, NSColor, CGFloat)] = [
    (windowBar(width: barW, topY: cx + barH * 0.46, height: barH * 1.30), NSColor(calibratedRed: 0.20, green: 0.90, blue: 0.88, alpha: 1), 0.0),
    (windowBar(width: barW * 0.92, topY: cx + barH * 0.30, height: barH * 1.50), NSColor(calibratedRed: 0.38, green: 0.52, blue: 1.00, alpha: 1), 0.0),
    (windowBar(width: barW, topY: cx + barH * 0.44, height: barH * 1.34), NSColor(calibratedRed: 0.78, green: 0.40, blue: 1.00, alpha: 1), 0.0)
]

// Pre-transform each bar by -8° around center, and offset X to form the M

for (index, entry) in bars.enumerated() {
    let (path, color, _) = entry
    let p = path.copy() as! NSBezierPath

    // Horizontal offset to separate the three strokes into an "M"
    let shift: CGFloat
    switch index {
    case 0: shift = -barW * 1.12   // left stroke
    case 1: shift = 0              // center apex
    default: shift = barW * 1.12   // right stroke
    }
    let xform = AffineTransform(translationByX: shift, byY: 0)
    p.transform(using: xform)

    let sheen = NSGradient(colors: [
        color.blended(withFraction: 0.28, of: .white) ?? color,
        color,
        color.blended(withFraction: 0.25, of: .black) ?? color
    ])!
    sheen.draw(in: p, angle: 25)

    NSColor.white.withAlphaComponent(0.5).setStroke()
    p.lineWidth = 5.5
    p.stroke()

    // Window-chrome dots on the title bar so it reads as a browser window
    let dotR: CGFloat = 8
    let dy = p.bounds.maxY - p.bounds.height * 0.16
    for dx in [p.bounds.minX + 20, p.bounds.minX + 46] {
        let dot = NSBezierPath(ovalIn: NSRect(x: dx, y: dy, width: dotR * 2, height: dotR * 2))
        NSColor.white.withAlphaComponent(0.88).setFill()
        dot.fill()
    }
}

// ---- Top gloss highlight ----
let gloss = NSBezierPath()
gloss.appendOval(in: NSRect(x: cx - barW * 0.9, y: cx + barH * 0.52, width: barW * 1.8, height: barH * 0.9))
NSColor.white.withAlphaComponent(0.06).setFill()
gloss.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render png")
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try! png.write(to: out)
print("wrote", out.path)
