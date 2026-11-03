import AppKit
import SwiftUI

/// Window background for the light skin: scratched, brushed anodized aluminium.
/// The texture is rendered once with Core Graphics (deterministic seed) and drawn unscaled
/// from the top-left corner, so it looks identical on every redraw and in every window.
struct AluminumBackground: View {
    var body: some View {
        Color(white: 0.80)
            .overlay(alignment: .topLeading) {
                Image(nsImage: AluminumTexture.image)
                    .interpolation(.high)
            }
            .clipped()
    }
}

enum AluminumTexture {
    /// Large enough for the main window and Settings at any content size they use.
    static let size = CGSize(width: 1200, height: 1100)

    @MainActor static let image: NSImage = render(size: size, scale: 2)

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in 0..<1.
        mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
        mutating func range(_ r: ClosedRange<CGFloat>) -> CGFloat { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
    }

    static func render(size: CGSize, scale: CGFloat) -> NSImage {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: size) }

        // Work in points with the origin at the top-left.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        var rng = SplitMix64(state: 0xA1_000D_12ED)

        func color(_ white: CGFloat, _ alpha: CGFloat, tint: CGFloat = 0) -> CGColor {
            // slight cool tint, as anodized aluminium has
            CGColor(srgbRed: white - tint, green: white - tint * 0.4, blue: white + tint, alpha: alpha)
        }
        func linear(_ stops: [(CGColor, CGFloat)], from: CGPoint, to: CGPoint) {
            guard let g = CGGradient(colorsSpace: space, colors: stops.map(\.0) as CFArray,
                                     locations: stops.map(\.1)) else { return }
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        // 1. Base: soft vertical falloff, light from above.
        linear([(color(0.86, 1, tint: 0.008), 0), (color(0.78, 1, tint: 0.010), 0.55), (color(0.72, 1, tint: 0.012), 1)],
               from: .zero, to: CGPoint(x: 0, y: size.height))

        // 2. Brushed grain: many hairlines running left–right, each a slightly different shade.
        ctx.setLineCap(.butt)
        var y: CGFloat = 0
        while y < size.height {
            var x: CGFloat = -20
            while x < size.width {
                let len = rng.range(40...600)
                let bright = rng.unit() < 0.5
                ctx.setStrokeColor(bright ? color(1, rng.range(0.03...0.11)) : color(0, rng.range(0.02...0.07)))
                ctx.setLineWidth(rng.range(0.25...0.7))
                let dy = rng.range(-0.25...0.25)
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x + len, y: y + dy))
                ctx.strokePath()
                x += len + rng.range(-10...30)
            }
            y += rng.range(0.35...0.9)
        }

        // 3. Broad satin sheen across the plate.
        linear([(color(1, 0), 0), (color(1, 0.16), 0.38), (color(1, 0.04), 0.55), (color(1, 0.12), 0.72), (color(1, 0), 1)],
               from: CGPoint(x: 0, y: 0), to: CGPoint(x: size.width, y: size.height * 0.6))

        // 4. Scratches: a thin dark groove with a bright lip next to it. Mostly short, a few long ones,
        //    some gently curved.
        ctx.setLineCap(.round)
        for i in 0..<420 {
            let start = CGPoint(x: rng.range(-60...(size.width + 60)), y: rng.range(-60...(size.height + 60)))
            let short = rng.unit()
            let len = 6 + pow(short, 2.6) * (i % 9 == 0 ? 520 : 170)
            // directions cluster around a few "handling" angles plus random strays
            let base: CGFloat = [0.35, -0.5, 2.6, 1.3][i % 4]
            let angle = rng.unit() < 0.7 ? base + rng.range(-0.35...0.35) : rng.range(0...(2 * .pi))
            let end = CGPoint(x: start.x + cos(angle) * len, y: start.y + sin(angle) * len)
            let bend = rng.range(-0.12...0.12) * len
            let mid = CGPoint(x: (start.x + end.x) / 2 - sin(angle) * bend, y: (start.y + end.y) / 2 + cos(angle) * bend)
            let width = rng.range(0.3...(len > 150 ? 1.0 : 0.75))
            let depth = rng.range(0.35...1)

            func stroke(_ offset: CGFloat, _ c: CGColor, _ lw: CGFloat) {
                let ox = -sin(angle) * offset, oy = cos(angle) * offset
                ctx.setStrokeColor(c)
                ctx.setLineWidth(lw)
                ctx.move(to: CGPoint(x: start.x + ox, y: start.y + oy))
                ctx.addQuadCurve(to: CGPoint(x: end.x + ox, y: end.y + oy), control: CGPoint(x: mid.x + ox, y: mid.y + oy))
                ctx.strokePath()
            }
            stroke(0, color(0.25, 0.20 * depth), width)                 // groove
            stroke(width * 0.9, color(1, 0.55 * depth), width * 0.8)     // catching the light
        }

        // 5. Fine speckle (pitting in the anodized layer).
        for _ in 0..<9000 {
            let p = CGPoint(x: rng.range(0...size.width), y: rng.range(0...size.height))
            let r = rng.range(0.2...0.6)
            ctx.setFillColor(rng.unit() < 0.5 ? color(1, rng.range(0.1...0.35)) : color(0, rng.range(0.04...0.12)))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }

        // 6. Gentle vignette toward the edges.
        if let g = CGGradient(colorsSpace: space, colors: [color(0, 0), color(0, 0.10)] as CFArray, locations: [0.55, 1]) {
            let c = CGPoint(x: size.width * 0.4, y: size.height * 0.25)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: max(size.width, size.height) * 0.75,
                                   options: [.drawsAfterEndLocation])
        }

        guard let cg = ctx.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cg, size: size)
    }
}
