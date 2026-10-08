// Renders the ORBIS-style app icon: white squircle, black dot-matrix cloud, amber dot.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSColor(white: 0.996, alpha: 1).setFill()
tile.fill()
NSColor(white: 0, alpha: 0.10).setStroke()
tile.lineWidth = 4
tile.stroke()

// Same shape as DotCloud in StartPage.swift (unit space, y down).
let puffs: [(Double, Double, Double)] = [(0.31, 0.56, 0.165), (0.50, 0.42, 0.225), (0.71, 0.56, 0.155)]
let aspect = 0.6
func dome(_ dx: Double, _ dy: Double, _ r: Double) -> Double {
    let (u, v) = (dx / r, dy * aspect / r)
    let d2 = u * u + v * v
    return d2 < 1 ? (1 - d2).squareRoot() * 0.75 + (0.5 - 0.35 * v - 0.15 * u) * 0.25 : 0
}
let width = 640.0, height = width * aspect
let ox = (1024 - width) / 2, oy = (1024 - height) / 2 + 20
let cols = 30.0, step = 1 / cols
var y = step / aspect / 2
while y < 1 {
    var x = step / 2
    while x < 1 {
        var hs = puffs.map { dome(x - $0.0, y - $0.1, $0.2) }
        hs.append(dome(x - min(max(x, 0.15), 0.85), y - 0.72, 0.085) * 0.8)
        hs.sort(by: >)
        var h = hs[0]
        if hs[1] > 0, h - hs[1] < 0.035 { h *= 0.45 }
        if h > 0 {
            let s = width * step * 0.66 * (0.25 + 0.75 * h)
            NSColor(srgbRed: 0.039, green: 0.039, blue: 0.043, alpha: 0.2 + 0.8 * h).setFill()
            NSBezierPath(rect: NSRect(x: ox + x * width - s / 2, y: 1024 - (oy + y * height) - s / 2, width: s, height: s)).fill()
        }
        x += step
    }
    y += step / aspect
}
NSColor(srgbRed: 0.831, green: 0.525, blue: 0.039, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 690, y: 700, width: 80, height: 80)).fill()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
