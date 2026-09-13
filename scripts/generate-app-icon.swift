import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func render(size: Int) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Unable to create app icon context") }

    let s = CGFloat(size)
    let inset = s * 0.045
    let backgroundRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let backgroundPath = CGPath(
        roundedRect: backgroundRect,
        cornerWidth: s * 0.22,
        cornerHeight: s * 0.22,
        transform: nil
    )
    context.addPath(backgroundPath)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(0.19, 0.28, 0.76), color(0.43, 0.22, 0.78)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )
    context.resetClip()

    context.addPath(backgroundPath)
    context.setStrokeColor(color(1, 1, 1, 0.18))
    context.setLineWidth(max(1, s * 0.012))
    context.strokePath()

    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: s * 0.50, y: s * 0.82))
    shield.addCurve(
        to: CGPoint(x: s * 0.25, y: s * 0.69),
        control1: CGPoint(x: s * 0.39, y: s * 0.78),
        control2: CGPoint(x: s * 0.30, y: s * 0.73)
    )
    shield.addCurve(
        to: CGPoint(x: s * 0.34, y: s * 0.33),
        control1: CGPoint(x: s * 0.25, y: s * 0.58),
        control2: CGPoint(x: s * 0.28, y: s * 0.43)
    )
    shield.addCurve(
        to: CGPoint(x: s * 0.50, y: s * 0.18),
        control1: CGPoint(x: s * 0.39, y: s * 0.23),
        control2: CGPoint(x: s * 0.46, y: s * 0.19)
    )
    shield.addCurve(
        to: CGPoint(x: s * 0.66, y: s * 0.33),
        control1: CGPoint(x: s * 0.54, y: s * 0.19),
        control2: CGPoint(x: s * 0.61, y: s * 0.23)
    )
    shield.addCurve(
        to: CGPoint(x: s * 0.75, y: s * 0.69),
        control1: CGPoint(x: s * 0.72, y: s * 0.43),
        control2: CGPoint(x: s * 0.75, y: s * 0.58)
    )
    shield.addCurve(
        to: CGPoint(x: s * 0.50, y: s * 0.82),
        control1: CGPoint(x: s * 0.70, y: s * 0.73),
        control2: CGPoint(x: s * 0.61, y: s * 0.78)
    )
    shield.closeSubpath()
    context.addPath(shield)
    context.setFillColor(color(1, 1, 1, 0.96))
    context.fillPath()

    let check = CGMutablePath()
    check.move(to: CGPoint(x: s * 0.37, y: s * 0.49))
    check.addLine(to: CGPoint(x: s * 0.46, y: s * 0.39))
    check.addLine(to: CGPoint(x: s * 0.65, y: s * 0.59))
    context.addPath(check)
    context.setStrokeColor(color(0.26, 0.27, 0.73))
    context.setLineWidth(max(2, s * 0.075))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { fatalError("Unable to create PNG destination") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write PNG") }
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in variants {
    writePNG(render(size: size), to: output.appendingPathComponent(name))
}
