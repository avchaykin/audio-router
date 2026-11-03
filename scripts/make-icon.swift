// Renders Resources/AppIcon.icns in the MIDI Filter icon style. Run from the repo root:
//   swift scripts/make-icon.swift            (add --preview <file.png> to also write a 1024 px PNG)
import AppKit

let out = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Same canvas as MIDI Filter: navy gradient squircle.
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.42, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.16, alpha: 1)])!
        .draw(in: bg, angle: -90)

    // Effect chain: three slots, the signal snaking down through them (teal → green → yellow).
    let colors: [NSColor] = [.systemTeal, .systemGreen, .systemYellow]
    let h = rect.height * 0.075
    let w = rect.width * 0.58
    let x0 = rect.midX - w / 2
    let ys = (0..<3).map { rect.midY + rect.height * 0.16 - CGFloat($0) * rect.height * 0.16 }
    let link = h * 0.42   // connector thickness

    func connector(x: CGFloat, from top: CGFloat, to bottom: CGFloat, _ a: NSColor, _ b: NSColor) {
        let r = NSRect(x: x - link / 2, y: bottom + h / 2, width: link, height: top - bottom)
        NSGradient(colors: [b, a])!.draw(in: NSBezierPath(roundedRect: r, xRadius: link / 2, yRadius: link / 2), angle: 90)
    }
    connector(x: x0 + w - h / 2, from: ys[0], to: ys[1], colors[0], colors[1])
    connector(x: x0 + h / 2, from: ys[1], to: ys[2], colors[1], colors[2])

    for (i, c) in colors.enumerated() {
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: x0, y: ys[i], width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }
    // Signal in (top-left) and out (bottom-right).
    let dot = h * 0.9
    colors[0].setFill()
    NSBezierPath(ovalIn: NSRect(x: x0 - dot * 1.6, y: ys[0] + (h - dot) / 2, width: dot, height: dot)).fill()
    colors[2].setFill()
    NSBezierPath(ovalIn: NSRect(x: x0 + w + dot * 0.6, y: ys[2] + (h - dot) / 2, width: dot, height: dot)).fill()

    // White strip at the bottom (where MIDI Filter has its keyboard) with an audio waveform.
    let stripH = rect.height * 0.16
    let strip = NSRect(x: rect.minX + rect.width * 0.14, y: rect.minY + rect.height * 0.1,
                       width: rect.width * 0.72, height: stripH)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: strip, xRadius: stripH * 0.12, yRadius: stripH * 0.12).fill()
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
    let bars = 19
    let pitch = strip.width * 0.86 / CGFloat(bars)
    let barW = pitch * 0.52
    let left = strip.midX - pitch * CGFloat(bars) / 2 + (pitch - barW) / 2
    for i in 0..<bars {
        let t = CGFloat(i) / CGFloat(bars - 1)
        // envelope × wobble: reads as audio, symmetric around the centre line
        let env = sin(t * .pi)
        let amp = max(0.12, env * (0.55 + 0.45 * abs(sin(t * 13.0 + 0.6))))
        let bh = max(barW, stripH * 0.74 * amp)
        let r = NSRect(x: left + CGFloat(i) * pitch, y: strip.midY - bh / 2, width: barW, height: bh)
        NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    try! render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", out.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: out)
print("Wrote Resources/AppIcon.icns")
