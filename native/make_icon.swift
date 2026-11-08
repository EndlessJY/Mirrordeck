import AppKit
import Foundation

// 幕台 Mirrordeck icon: a phone whose glowing screen is mirrored onto the
// display behind it, on a deep indigo tile (macOS icon grid, 1024 px).
let size: CGFloat = 1024
guard CommandLine.arguments.count == 2 else { fatalError("output PNG path required") }
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.clear(CGRect(x: 0, y: 0, width: size, height: size))

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func linear(_ colors: [CGColor], from: CGPoint, to: CGPoint, in path: CGPath) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [])
    context.restoreGState()
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Tile with a soft drop shadow, as in Apple's icon grid (824 pt body).
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = rounded(tileRect, 186)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
context.addPath(tile)
context.setFillColor(color(0x1b1a3d))
context.fillPath()
context.restoreGState()
linear([color(0x3a37a0), color(0x1d1b52), color(0x100f2c)],
       from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100), in: tile)
// Faint glow behind the devices.
context.saveGState()
context.addPath(tile)
context.clip()
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                      colors: [color(0x8b7bff, 0.45), color(0x8b7bff, 0)] as CFArray,
                      locations: [0, 1])!
context.drawRadialGradient(glow, startCenter: CGPoint(x: 560, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 560, y: 560), endRadius: 420, options: [])
context.restoreGState()
// Inner hairline for a crisp edge.
context.addPath(rounded(tileRect.insetBy(dx: 2, dy: 2), 184))
context.setStrokeColor(color(0xffffff, 0.12))
context.setLineWidth(3)
context.strokePath()

// Display behind: outline with the mirrored picture.
let display = CGRect(x: 238, y: 410, width: 548, height: 352)
let displayPath = rounded(display, 44)
context.addPath(displayPath)
context.setFillColor(color(0x0c0b22, 0.75))
context.fillPath()
linear([color(0x6e6af6, 0.55), color(0xb06cf2, 0.35)],
       from: CGPoint(x: display.minX, y: display.maxY), to: CGPoint(x: display.maxX, y: display.minY),
       in: rounded(display.insetBy(dx: 26, dy: 26), 22))
context.addPath(displayPath)
context.setStrokeColor(color(0xe9e8ff, 0.9))
context.setLineWidth(18)
context.strokePath()
// Stand.
context.setFillColor(color(0xe9e8ff, 0.9))
context.addPath(rounded(CGRect(x: 470, y: 352, width: 84, height: 50), 10))
context.fillPath()
context.addPath(rounded(CGRect(x: 404, y: 328, width: 216, height: 30), 15))
context.fillPath()

// Phone in front, bright screen.
let phone = CGRect(x: 548, y: 218, width: 236, height: 432)
let phonePath = rounded(phone, 50)
context.saveGState()
context.setShadow(offset: CGSize(width: -10, height: -18), blur: 40, color: color(0x05041a, 0.65))
context.addPath(phonePath)
context.setFillColor(color(0x121133))
context.fillPath()
context.restoreGState()
let screen = phone.insetBy(dx: 16, dy: 16)
linear([color(0x7d78ff), color(0x9a6bff), color(0xd07cf0)],
       from: CGPoint(x: screen.minX, y: screen.maxY), to: CGPoint(x: screen.maxX, y: screen.minY),
       in: rounded(screen, 36))
// Diagonal sheen on the screen.
context.saveGState()
context.addPath(rounded(screen, 36))
context.clip()
context.move(to: CGPoint(x: screen.minX, y: screen.maxY - 90))
context.addLine(to: CGPoint(x: screen.minX + 120, y: screen.maxY))
context.addLine(to: CGPoint(x: screen.minX + 230, y: screen.maxY))
context.addLine(to: CGPoint(x: screen.minX, y: screen.maxY - 250))
context.closePath()
context.setFillColor(color(0xffffff, 0.16))
context.fillPath()
context.restoreGState()
// Camera dot and frame.
context.setFillColor(color(0x121133))
context.fillEllipse(in: CGRect(x: phone.midX - 11, y: phone.maxY - 44, width: 22, height: 22))
context.addPath(phonePath)
context.setStrokeColor(color(0xf2f1ff))
context.setLineWidth(10)
context.strokePath()

NSGraphicsContext.restoreGraphicsState()
let path = CommandLine.arguments[1]
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
