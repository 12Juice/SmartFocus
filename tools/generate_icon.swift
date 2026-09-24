// Generates the 1024x1024 app icon source PNG (CoreGraphics, no GUI session needed).
// Usage: swift tools/generate_icon.swift <output.png>

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let size = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let s = CGFloat(size)

// macOS-style squircle plate
let plate = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
    cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil
)

ctx.saveGState()
ctx.addPath(plate)
ctx.clip()

// Diagonal gradient: light blue (top-left) -> violet (bottom-right)
let colors = [
    CGColor(red: 0.13, green: 0.35, blue: 0.98, alpha: 1),
    CGColor(red: 0.60, green: 0.20, blue: 0.98, alpha: 1)
] as CFArray
let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

// White lightning bolt with a soft shadow
let points: [(CGFloat, CGFloat)] = [
    (0.585, 0.045), (0.235, 0.565), (0.462, 0.565), (0.375, 0.955),
    (0.795, 0.405), (0.545, 0.405), (0.685, 0.045)
]
let bolt = CGMutablePath()
bolt.move(to: CGPoint(x: points[0].0 * s, y: points[0].1 * s))
for p in points.dropFirst() {
    bolt.addLine(to: CGPoint(x: p.0 * s, y: p.1 * s))
}
bolt.closeSubpath()

ctx.setShadow(offset: .zero, blur: s * 0.03, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(bolt)
ctx.fillPath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("failed to render image") }
let url = URL(fileURLWithPath: output) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("failed to create destination")
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("icon written to \(output)")
