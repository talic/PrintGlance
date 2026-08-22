#!/usr/bin/env swift
import AppKit
import Foundation

/// Tahoe jails icons whose canvas-edge alpha is ≤252. Fill every pixel opaque
/// before drawing the glyph. Do not pre-round; the system applies the squircle.

enum IconFail: String, Error {
    case args = "usage: render-appicon.swift <AppIcon.icns>"
    case bitmap
    case png
    case iconutil
    case opaque
}

let field = NSColor(srgbRed: 0x24 / 255, green: 0x22 / 255, blue: 0x20 / 255, alpha: 1)
let glyph = NSColor(srgbRed: 0xF2 / 255, green: 0xED / 255, blue: 0xE6 / 255, alpha: 1)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

func render(px: Int) throws -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw IconFail.bitmap }
    rep.size = NSSize(width: px, height: px)

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw IconFail.bitmap }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.translateBy(x: 0, y: CGFloat(px))
    cg.scaleBy(x: 1, y: -1)

    field.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: px, height: px)).fill()

    let s = CGFloat(px) / 1024
    func r(_ v: CGFloat) -> CGFloat { v * s }

    glyph.setFill()
    NSBezierPath(roundedRect: NSRect(x: r(322), y: r(168), width: r(380), height: r(220)), xRadius: r(36), yRadius: r(36)).fill()
    NSBezierPath(roundedRect: NSRect(x: r(192), y: r(372), width: r(640), height: r(312)), xRadius: r(64), yRadius: r(64)).fill()
    let nozzle = NSBezierPath()
    nozzle.move(to: NSPoint(x: r(272), y: r(684)))
    nozzle.line(to: NSPoint(x: r(752), y: r(684)))
    nozzle.line(to: NSPoint(x: r(572), y: r(872)))
    nozzle.line(to: NSPoint(x: r(452), y: r(872)))
    nozzle.close()
    nozzle.fill()

    NSGraphicsContext.restoreGraphicsState()
    try assertOpaque(rep)
    return rep
}

func assertOpaque(_ rep: NSBitmapImageRep) throws {
    let w = rep.pixelsWide
    let h = rep.pixelsHigh
    guard let data = rep.bitmapData else { throw IconFail.opaque }
    let spp = rep.samplesPerPixel
    let bpr = rep.bytesPerRow
    func alpha(_ x: Int, _ y: Int) -> UInt8 {
        data[y * bpr + x * spp + 3]
    }
    for x in 0..<w {
        if alpha(x, 0) <= 252 || alpha(x, h - 1) <= 252 { throw IconFail.opaque }
    }
    for y in 0..<h {
        if alpha(0, y) <= 252 || alpha(w - 1, y) <= 252 { throw IconFail.opaque }
    }
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let png = rep.representation(using: .png, properties: [:]) else { throw IconFail.png }
    try png.write(to: url)
}

do {
    guard CommandLine.arguments.count == 2 else { throw IconFail.args }
    let icnsURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let fm = FileManager.default
    try fm.createDirectory(at: icnsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let iconset = icnsURL.deletingLastPathComponent().appendingPathComponent("AppIcon.iconset")
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

    var preview: NSBitmapImageRep?
    for item in sizes {
        let rep = try render(px: item.px)
        if item.px == 1024 { preview = rep }
        try writePNG(rep, to: iconset.appendingPathComponent("\(item.name).png"))
    }

    if let preview {
        try writePNG(preview, to: icnsURL.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png"))
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0, fm.fileExists(atPath: icnsURL.path) else { throw IconFail.iconutil }
    try? fm.removeItem(at: iconset)
} catch {
    fputs("render-appicon: \(error)\n", stderr)
    exit(1)
}
