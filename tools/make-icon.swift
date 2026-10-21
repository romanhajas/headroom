// make-icon.swift - draws Support/AppIcon.icns: a gauge ring on a graphite tile.
//
//   swift tools/make-icon.swift

import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let size: CGFloat = 1024

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func drawIcon() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // The tile, on the macOS icon grid, with a soft shadow.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    rgb(0x1E2024).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: rgb(0x34373D), ending: rgb(0x16171A))!.draw(in: tile, angle: -90)

    // The ring: a faint track, then about two thirds of it lit, clockwise from the top.
    let center = NSPoint(x: 512, y: 512), radius: CGFloat = 250, width: CGFloat = 92
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width
    rgb(0xFFFFFF, 0.10).setStroke()
    track.stroke()

    let lit = NSBezierPath()
    lit.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 245, clockwise: true)
    lit.lineWidth = width
    lit.lineCapStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = rgb(0xF2894E, 0.55)
    glow.shadowBlurRadius = 40
    glow.set()
    rgb(0xF2894E).setStroke()
    lit.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // A small dot in the middle, like the hub of a dial.
    rgb(0xF5F1EA).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let png = drawIcon().representation(using: .png, properties: [:])!
let work = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = work.appendingPathComponent("icon-1024.png")
try! png.write(to: master)

func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
}
for s in [16, 32, 128, 256, 512] {
    run("/usr/bin/sips", ["-z", "\(s)", "\(s)", master.path, "--out", iconset.appendingPathComponent("icon_\(s)x\(s).png").path])
    run("/usr/bin/sips", ["-z", "\(s * 2)", "\(s * 2)", master.path, "--out", iconset.appendingPathComponent("icon_\(s)x\(s)@2x.png").path])
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Support/AppIcon.icns").path])
try? FileManager.default.copyItem(at: master, to: root.appendingPathComponent("docs/icon.png"))
try? FileManager.default.removeItem(at: work)
print("wrote Support/AppIcon.icns")
