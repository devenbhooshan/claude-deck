// Renders the Claude Deck app icon: a fanned deck of session cards on Claude terracotta.
// Usage: swift make_icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt squircle centered on a 1024 canvas, with a soft drop shadow.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: NSColor.black.withAlphaComponent(0.28).cgColor)
rgb(0xC85F40).setFill()
platePath.fill()
ctx.restoreGState()

ctx.saveGState()
platePath.addClip()
NSGradient(colors: [rgb(0xEC9A74), rgb(0xD97757), rgb(0xB24E32)], atLocations: [0, 0.5, 1],
           colorSpace: .sRGB)!.draw(in: plate, angle: -90)
ctx.restoreGState()

let cardW: CGFloat = 420, cardH: CGFloat = 510
// Cards fan out like a hand: each rotates about a pivot below the deck.
let pivot = CGPoint(x: 512, y: 60)

func card(angle: CGFloat, lift: CGFloat = 0, fill: NSColor, shadow: CGFloat, body: (CGRect) -> Void = { _ in }) {
    ctx.saveGState()
    ctx.translateBy(x: pivot.x, y: pivot.y)
    ctx.rotate(by: angle * .pi / 180)
    let r = CGRect(x: -cardW / 2, y: 470 - pivot.y - cardH / 2 + 30 + lift, width: cardW, height: cardH)
    let path = NSBezierPath(roundedRect: r, xRadius: 54, yRadius: 54)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(shadow).cgColor)
    fill.setFill()
    path.fill()
    ctx.restoreGState()
    body(r)
    ctx.restoreGState()
}

func bar(_ r: CGRect, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
}

// Four-pointed sparkle built from concave curves.
func sparkle(center c: CGPoint, radius R: CGFloat, waist: CGFloat, color: NSColor) {
    let p = NSBezierPath()
    let pts = [CGPoint(x: c.x, y: c.y + R), CGPoint(x: c.x + R, y: c.y), CGPoint(x: c.x, y: c.y - R), CGPoint(x: c.x - R, y: c.y)]
    p.move(to: pts[0])
    for i in 0..<4 {
        let next = pts[(i + 1) % 4]
        p.curve(to: next, controlPoint1: CGPoint(x: c.x + (pts[i].x - c.x) * waist, y: c.y + (pts[i].y - c.y) * waist),
                controlPoint2: CGPoint(x: c.x + (next.x - c.x) * waist, y: c.y + (next.y - c.y) * waist))
    }
    p.close()
    color.setFill()
    p.fill()
}

let cream = rgb(0xFFF8F1)
card(angle: 14, lift: -40, fill: rgb(0xF3CDB8), shadow: 0.2)
card(angle: -14, lift: -40, fill: rgb(0xF8DDCC), shadow: 0.2)
card(angle: 0, fill: cream, shadow: 0.32) { r in
    // Status dot: a session waiting on you.
    rgb(0x3FB37F).setFill()
    NSBezierPath(ovalIn: CGRect(x: r.maxX - 104, y: r.maxY - 104, width: 52, height: 52)).fill()
    sparkle(center: CGPoint(x: r.midX, y: r.midY + 70), radius: 112, waist: 0.2, color: rgb(0xD97757))
    // Transcript lines.
    let line = rgb(0xEBD3C2)
    bar(CGRect(x: r.minX + 68, y: r.minY + 134, width: 284, height: 28), line)
    bar(CGRect(x: r.minX + 68, y: r.minY + 82, width: 188, height: 28), line)
}

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
