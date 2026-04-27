import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/AppIcon.iconset")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

struct IconVariant {
    let filename: String
    let size: CGFloat
}

let variants = [
    IconVariant(filename: "icon_16x16.png", size: 16),
    IconVariant(filename: "icon_16x16@2x.png", size: 32),
    IconVariant(filename: "icon_32x32.png", size: 32),
    IconVariant(filename: "icon_32x32@2x.png", size: 64),
    IconVariant(filename: "icon_128x128.png", size: 128),
    IconVariant(filename: "icon_128x128@2x.png", size: 256),
    IconVariant(filename: "icon_256x256.png", size: 256),
    IconVariant(filename: "icon_256x256@2x.png", size: 512),
    IconVariant(filename: "icon_512x512.png", size: 512),
    IconVariant(filename: "icon_512x512@2x.png", size: 1024)
]

for variant in variants {
    let image = NSImage(size: CGSize(width: variant.size, height: variant.size))
    image.lockFocus()
    drawIcon(size: variant.size)
    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(variant.filename)")
    }

    try data.write(to: outputDirectory.appendingPathComponent(variant.filename))
}

func drawIcon(size: CGFloat) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.scaleBy(x: size / 1024, y: size / 1024)

    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    NSColor.clear.setFill()
    canvas.fill()

    let background = NSBezierPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896), xRadius: 206, yRadius: 206)
    NSGradient(colors: [
        NSColor(red: 0.10, green: 0.38, blue: 0.92, alpha: 1),
        NSColor(red: 0.04, green: 0.64, blue: 0.78, alpha: 1)
    ])?.draw(in: background, angle: 45)

    NSColor.black.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: CGRect(x: 190, y: 126, width: 640, height: 770), xRadius: 58, yRadius: 58).fill()

    let page = NSBezierPath(roundedRect: CGRect(x: 176, y: 154, width: 640, height: 770), xRadius: 56, yRadius: 56)
    NSColor.white.setFill()
    page.fill()

    NSColor(red: 0.86, green: 0.91, blue: 0.98, alpha: 1).setStroke()
    page.lineWidth = 10
    page.stroke()

    let fold = NSBezierPath()
    fold.move(to: CGPoint(x: 642, y: 924))
    fold.line(to: CGPoint(x: 816, y: 750))
    fold.line(to: CGPoint(x: 642, y: 750))
    fold.close()
    NSColor(red: 0.90, green: 0.95, blue: 1.0, alpha: 1).setFill()
    fold.fill()

    NSColor(red: 0.55, green: 0.68, blue: 0.88, alpha: 1).setStroke()
    fold.lineWidth = 8
    fold.stroke()

    drawField(x: 286, y: 676, width: 360, height: 58, selected: false)
    drawField(x: 286, y: 566, width: 450, height: 70, selected: true)
    drawField(x: 286, y: 452, width: 250, height: 58, selected: false)
    drawCheckbox()
    drawSignature()

    context.restoreGState()
}

func drawField(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, selected: Bool) {
    let rect = CGRect(x: x, y: y, width: width, height: height)
    let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
    NSColor(red: 0.89, green: 0.95, blue: 1.0, alpha: 1).setFill()
    path.fill()
    (selected ? NSColor(red: 0.04, green: 0.45, blue: 1.0, alpha: 1) : NSColor(red: 0.54, green: 0.70, blue: 0.91, alpha: 1)).setStroke()
    path.lineWidth = selected ? 10 : 6
    path.stroke()

    NSColor(red: 0.30, green: 0.42, blue: 0.58, alpha: 0.34).setStroke()
    let line = NSBezierPath()
    line.move(to: CGPoint(x: x + 36, y: y + height / 2))
    line.line(to: CGPoint(x: x + width - 36, y: y + height / 2))
    line.lineWidth = 7
    line.stroke()
}

func drawCheckbox() {
    let box = CGRect(x: 286, y: 338, width: 78, height: 78)
    let path = NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16)
    NSColor(red: 0.91, green: 0.97, blue: 1.0, alpha: 1).setFill()
    path.fill()
    NSColor(red: 0.04, green: 0.45, blue: 1.0, alpha: 1).setStroke()
    path.lineWidth = 9
    path.stroke()

    let x = NSBezierPath()
    x.move(to: CGPoint(x: 306, y: 358))
    x.line(to: CGPoint(x: 344, y: 396))
    x.move(to: CGPoint(x: 344, y: 358))
    x.line(to: CGPoint(x: 306, y: 396))
    x.lineWidth = 10
    x.lineCapStyle = .round
    x.stroke()

    NSColor(red: 0.30, green: 0.42, blue: 0.58, alpha: 0.28).setStroke()
    let label = NSBezierPath()
    label.move(to: CGPoint(x: 396, y: 376))
    label.line(to: CGPoint(x: 688, y: 376))
    label.lineWidth = 9
    label.stroke()
}

func drawSignature() {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: 286, y: 244))
    path.curve(to: CGPoint(x: 390, y: 265), controlPoint1: CGPoint(x: 316, y: 214), controlPoint2: CGPoint(x: 350, y: 308))
    path.curve(to: CGPoint(x: 486, y: 252), controlPoint1: CGPoint(x: 426, y: 218), controlPoint2: CGPoint(x: 450, y: 286))
    path.curve(to: CGPoint(x: 612, y: 268), controlPoint1: CGPoint(x: 526, y: 214), controlPoint2: CGPoint(x: 566, y: 304))
    path.curve(to: CGPoint(x: 724, y: 250), controlPoint1: CGPoint(x: 650, y: 238), controlPoint2: CGPoint(x: 682, y: 246))
    NSColor(red: 0.09, green: 0.16, blue: 0.24, alpha: 0.72).setStroke()
    path.lineWidth = 13
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
}
