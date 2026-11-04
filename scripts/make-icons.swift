// Draws the MyMusic app icons and writes them into the asset catalogs.
// Usage: swift scripts/make-icons.swift        (from the repo root)
import AppKit

let violet = NSColor(srgbRed: 0.53, green: 0.31, blue: 1.00, alpha: 1)
let blue = NSColor(srgbRed: 0.16, green: 0.42, blue: 1.00, alpha: 1)
let deep = NSColor(srgbRed: 0.20, green: 0.12, blue: 0.55, alpha: 1)

/// The artwork inside `rect`: gradient, vinyl grooves, music note.
func drawArt(in rect: CGRect, cornerRadius: CGFloat, ctx: CGContext) {
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // diagonal gradient, lighter at the top
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [violet.cgColor, blue.cgColor, deep.cgColor] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // soft highlight in the top-left
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.85), startRadius: 0,
                           endCenter: CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.85), endRadius: rect.width * 0.75, options: [])

    // vinyl grooves behind the note
    let center = CGPoint(x: rect.midX, y: rect.midY)
    ctx.setLineWidth(rect.width * 0.008)
    for (i, r) in stride(from: 0.20, through: 0.46, by: 0.045).enumerated() {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(i % 2 == 0 ? 0.10 : 0.06).cgColor)
        ctx.addEllipse(in: CGRect(x: center.x - rect.width * r, y: center.y - rect.width * r, width: rect.width * r * 2, height: rect.width * r * 2))
        ctx.strokePath()
    }

    // the note (SF Symbol), white with a soft shadow
    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.50, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = note.size
        let origin = CGPoint(x: rect.midX - size.width / 2 - rect.width * 0.015, y: rect.midY - size.height / 2)
        ctx.setShadow(offset: CGSize(width: 0, height: -rect.width * 0.012), blur: rect.width * 0.03,
                      color: NSColor.black.withAlphaComponent(0.30).cgColor)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        note.draw(in: CGRect(origin: origin, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
    ctx.restoreGState()
}

func render(_ size: Int, mac: Bool) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if mac {
        // macOS shape: 824/1024 rounded square with a drop shadow
        let inset = s * 100 / 1024
        let rect = CGRect(x: inset, y: inset * 1.1, width: s - inset * 2, height: s - inset * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(deep.cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        drawArt(in: rect, cornerRadius: rect.width * 0.2237, ctx: ctx)
    } else {
        // iOS masks the corners itself; no transparency allowed
        drawArt(in: CGRect(x: 0, y: 0, width: s, height: s), cornerRadius: 0, ctx: ctx)
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: path))
}

// iOS: one 1024 image
write(render(1024, mac: false), "iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
write(Data("""
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
""".utf8), "iOS/Assets.xcassets/AppIcon.appiconset/Contents.json")

// macOS: all sizes
var images: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale, name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        write(render(px, mac: true), "Mac/Assets.xcassets/AppIcon.appiconset/\(name)")
        images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(pt)x\#(pt)"}"#)
    }
}
write(Data(#"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#.utf8),
      "Mac/Assets.xcassets/AppIcon.appiconset/Contents.json")
write(Data(#"{"info":{"author":"xcode","version":1}}"#.utf8), "Mac/Assets.xcassets/Contents.json")

// web player: favicon + home-screen icon
write(render(180, mac: false), "web/static/apple-touch-icon.png")
write(render(64, mac: true), "web/static/icon.png")
print("icons written")
