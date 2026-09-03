import AppKit

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)

// Rounded-square gradient background (navy -> purple)
let bg = NSBezierPath(roundedRect: rect, xRadius: CGFloat(size) * 0.223, yRadius: CGFloat(size) * 0.223)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.12, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.11, blue: 0.30, alpha: 1)
])!
gradient.draw(in: bg, angle: -90)

// Inner ring backdrop
let cx = CGFloat(size) / 2
let outer = CGFloat(size) * 0.40
let inner = CGFloat(size) * 0.30
let ring = NSBezierPath(ovalIn: NSRect(x: cx - outer, y: cx - outer, width: outer * 2, height: outer * 2))
let hole = NSBezierPath(ovalIn: NSRect(x: cx - inner, y: cx - inner, width: inner * 2, height: inner * 2))
ring.append(hole)
ring.windingRule = .evenOdd
NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.11, alpha: 1).setFill()
ring.fill()

// Brave-orange globe
let globeD = CGFloat(size) * 0.56
let globe = NSBezierPath(ovalIn: NSRect(x: cx - globeD / 2, y: cx - globeD / 2, width: globeD, height: globeD))
NSColor(calibratedRed: 0.984, green: 0.329, blue: 0.169, alpha: 1).setFill()
globe.fill()

// Equator + meridian
NSColor.white.withAlphaComponent(0.92).setStroke()
let meridian = NSBezierPath()
meridian.move(to: NSPoint(x: cx, y: cx - globeD / 2))
meridian.line(to: NSPoint(x: cx, y: cx + globeD / 2))
meridian.lineWidth = CGFloat(size) * 0.030
meridian.stroke()

let equator = NSBezierPath(ovalIn: NSRect(x: cx - globeD / 2, y: cx - globeD * 0.18,
                                          width: globeD, height: globeD * 0.36))
equator.lineWidth = CGFloat(size) * 0.030
equator.stroke()

// Highlight
let gloss = NSBezierPath(ovalIn: NSRect(x: cx - globeD * 0.24, y: cx + globeD * 0.12,
                                        width: globeD * 0.34, height: globeD * 0.34))
NSColor.white.withAlphaComponent(0.18).setFill()
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