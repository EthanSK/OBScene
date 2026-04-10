#!/usr/bin/env swift
//
// OBScene app icon generator.
//
// Renders the OBScene app icon at 1024x1024 using Core Graphics, then writes
// every size required for an `.iconset` bundle. Run with:
//
//   swift Resources/icon_source/generate_icon.swift
//
// Output is placed in `Resources/OBScene.iconset/` next to this script's
// parent dir. The design: a rounded-square macOS-style tile with a deep
// navy→violet gradient, a stylised monitor silhouette in the centre bearing
// a glowing red record dot, a subtle inner highlight, and a soft drop
// shadow inside the tile for depth.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

// MARK: - Config

let baseSize: CGFloat = 1024
let iconsetDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/OBScene.iconset")

try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// MARK: - Helpers

func makeContext(size: CGFloat) -> CGContext {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Flip coordinate system to match macOS top-left origin expectations for
    // our drawing code (easier math for the shapes).
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// MARK: - Drawing

func drawIcon(in ctx: CGContext, size: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // macOS Big Sur app icons use a ~22.37% corner radius (relative to the
    // full bleed). We keep a small inset so the tile doesn't touch the edges.
    let inset: CGFloat = size * 0.055
    let tileRect = rect.insetBy(dx: inset, dy: inset)
    let cornerRadius = tileRect.width * 0.2237

    // ----- Outer soft shadow (subtle ground for the tile) -----
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.012),
        blur: size * 0.05,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45)
    )
    let tilePath = CGPath(roundedRect: tileRect,
                          cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius,
                          transform: nil)
    ctx.addPath(tilePath)
    ctx.setFillColor(color(18, 14, 38))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip all subsequent drawing to the tile so gradients, highlights, etc.
    // stay inside the rounded rect.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // ----- Background gradient: deep navy → violet → magenta kiss -----
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        color(14, 10, 36),    // near-black navy top
        color(38, 18, 78),    // deep violet
        color(82, 22, 110),   // rich purple
        color(120, 28, 96)    // warm magenta-purple bottom
    ] as CFArray
    let bgLocations: [CGFloat] = [0.0, 0.45, 0.8, 1.0]
    let bgGradient = CGGradient(colorsSpace: colorSpace,
                                colors: bgColors,
                                locations: bgLocations)!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: tileRect.midX, y: tileRect.minY),
        end: CGPoint(x: tileRect.midX, y: tileRect.maxY),
        options: []
    )

    // ----- Diagonal glow sheen, subtle, top-left to centre -----
    let sheenColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.14),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray
    let sheenGradient = CGGradient(colorsSpace: colorSpace,
                                   colors: sheenColors,
                                   locations: [0.0, 1.0])!
    ctx.drawRadialGradient(
        sheenGradient,
        startCenter: CGPoint(x: tileRect.minX + tileRect.width * 0.2,
                             y: tileRect.minY + tileRect.height * 0.22),
        startRadius: 0,
        endCenter: CGPoint(x: tileRect.minX + tileRect.width * 0.2,
                           y: tileRect.minY + tileRect.height * 0.22),
        endRadius: tileRect.width * 0.75,
        options: []
    )

    // ----- Broadcast rings behind the monitor (soft, glowy) -----
    let centre = CGPoint(x: tileRect.midX, y: tileRect.midY + tileRect.height * 0.02)
    let ringColors = [
        CGColor(red: 1.0, green: 0.35, blue: 0.45, alpha: 0.32),
        CGColor(red: 1.0, green: 0.35, blue: 0.45, alpha: 0.0)
    ] as CFArray
    let ringGradient = CGGradient(colorsSpace: colorSpace,
                                  colors: ringColors,
                                  locations: [0.0, 1.0])!
    ctx.drawRadialGradient(
        ringGradient,
        startCenter: centre,
        startRadius: tileRect.width * 0.12,
        endCenter: centre,
        endRadius: tileRect.width * 0.48,
        options: []
    )

    // ----- The monitor -----
    let monitorWidth = tileRect.width * 0.58
    let monitorHeight = monitorWidth * 0.62
    let monitorRect = CGRect(
        x: centre.x - monitorWidth / 2,
        y: centre.y - monitorHeight / 2 - tileRect.height * 0.04,
        width: monitorWidth,
        height: monitorHeight
    )

    // Monitor outer bezel — rounded rect with a crisp gradient fill.
    let bezelRadius = monitorWidth * 0.08
    let bezelPath = CGPath(roundedRect: monitorRect,
                           cornerWidth: bezelRadius,
                           cornerHeight: bezelRadius,
                           transform: nil)

    // Soft outer glow for the monitor
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: size * 0.035,
        color: CGColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 0.55)
    )
    ctx.addPath(bezelPath)
    ctx.setFillColor(color(30, 22, 56))
    ctx.fillPath()
    ctx.restoreGState()

    // Bezel gradient fill (light top → dark bottom for a metallic feel)
    ctx.saveGState()
    ctx.addPath(bezelPath)
    ctx.clip()
    let bezelColors = [
        color(70, 58, 110),
        color(34, 24, 64),
        color(22, 14, 48)
    ] as CFArray
    let bezelGradient = CGGradient(colorsSpace: colorSpace,
                                   colors: bezelColors,
                                   locations: [0.0, 0.5, 1.0])!
    ctx.drawLinearGradient(
        bezelGradient,
        start: CGPoint(x: monitorRect.midX, y: monitorRect.minY),
        end: CGPoint(x: monitorRect.midX, y: monitorRect.maxY),
        options: []
    )
    ctx.restoreGState()

    // Inner screen
    let screenInset = monitorWidth * 0.045
    let screenRect = monitorRect.insetBy(dx: screenInset, dy: screenInset)
    let screenRadius = bezelRadius * 0.75
    let screenPath = CGPath(roundedRect: screenRect,
                            cornerWidth: screenRadius,
                            cornerHeight: screenRadius,
                            transform: nil)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()

    // Screen gradient — deep charcoal to hint of purple (like a dark OBS UI)
    let screenColors = [
        color(8, 6, 22),
        color(20, 12, 42)
    ] as CFArray
    let screenGradient = CGGradient(colorsSpace: colorSpace,
                                    colors: screenColors,
                                    locations: [0.0, 1.0])!
    ctx.drawLinearGradient(
        screenGradient,
        start: CGPoint(x: screenRect.midX, y: screenRect.minY),
        end: CGPoint(x: screenRect.midX, y: screenRect.maxY),
        options: []
    )

    // Faint horizontal scanline-like bands for broadcast vibe
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.025))
    let bandHeight = screenRect.height / 18
    var y = screenRect.minY
    while y < screenRect.maxY {
        ctx.fill(CGRect(x: screenRect.minX, y: y, width: screenRect.width, height: bandHeight * 0.4))
        y += bandHeight
    }

    // ----- "OB" monogram on the screen, subtle -----
    // We render it as filled text using Core Text via NSAttributedString+NSString
    // drawing (AppKit path) — simpler than manual glyph layout.
    let monogram = "OB"
    let font = NSFont.systemFont(ofSize: screenRect.height * 0.42, weight: .heavy)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.14),
        .paragraphStyle: paragraph,
        .kern: -screenRect.height * 0.012
    ]
    // AppKit draws in an NSGraphicsContext using flipped-y semantics matching
    // the current CG state. We've already flipped the context so we need to
    // unflip for text to read correctly.
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    let flippedScreenRect = CGRect(
        x: screenRect.minX,
        y: size - screenRect.maxY,
        width: screenRect.width,
        height: screenRect.height
    )
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    let textSize = (monogram as NSString).size(withAttributes: attrs)
    let textRect = CGRect(
        x: flippedScreenRect.midX - textSize.width / 2,
        y: flippedScreenRect.midY - textSize.height / 2,
        width: textSize.width,
        height: textSize.height
    )
    (monogram as NSString).draw(in: textRect, withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()

    // Inner top-edge highlight on the screen (glass reflection)
    let glassColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.08),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray
    let glassGradient = CGGradient(colorsSpace: colorSpace,
                                   colors: glassColors,
                                   locations: [0.0, 1.0])!
    ctx.drawLinearGradient(
        glassGradient,
        start: CGPoint(x: screenRect.midX, y: screenRect.minY),
        end: CGPoint(x: screenRect.midX, y: screenRect.minY + screenRect.height * 0.5),
        options: []
    )

    ctx.restoreGState() // end screen clip

    // ----- The record dot -----
    let dotRadius = monitorWidth * 0.09
    let dotCentre = CGPoint(
        x: monitorRect.maxX - monitorWidth * 0.18,
        y: monitorRect.minY + monitorHeight * 0.22
    )
    let dotRect = CGRect(
        x: dotCentre.x - dotRadius,
        y: dotCentre.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    )

    // Glow behind the dot
    ctx.saveGState()
    let glowColors = [
        CGColor(red: 1.0, green: 0.25, blue: 0.3, alpha: 0.85),
        CGColor(red: 1.0, green: 0.25, blue: 0.3, alpha: 0.0)
    ] as CFArray
    let glowGradient = CGGradient(colorsSpace: colorSpace,
                                  colors: glowColors,
                                  locations: [0.0, 1.0])!
    ctx.drawRadialGradient(
        glowGradient,
        startCenter: dotCentre,
        startRadius: 0,
        endCenter: dotCentre,
        endRadius: dotRadius * 3.2,
        options: []
    )
    ctx.restoreGState()

    // The solid dot with a radial highlight
    ctx.saveGState()
    ctx.addEllipse(in: dotRect)
    ctx.clip()
    let redColors = [
        color(255, 110, 120),
        color(235, 40, 60),
        color(160, 10, 30)
    ] as CFArray
    let redGradient = CGGradient(colorsSpace: colorSpace,
                                 colors: redColors,
                                 locations: [0.0, 0.5, 1.0])!
    ctx.drawRadialGradient(
        redGradient,
        startCenter: CGPoint(x: dotCentre.x - dotRadius * 0.3,
                             y: dotCentre.y - dotRadius * 0.35),
        startRadius: 0,
        endCenter: dotCentre,
        endRadius: dotRadius,
        options: []
    )
    ctx.restoreGState()

    // Tiny white highlight sparkle
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.8))
    let sparkleRect = CGRect(
        x: dotCentre.x - dotRadius * 0.45,
        y: dotCentre.y - dotRadius * 0.55,
        width: dotRadius * 0.38,
        height: dotRadius * 0.28
    )
    ctx.addEllipse(in: sparkleRect)
    ctx.fillPath()
    ctx.restoreGState()

    // ----- Monitor stand (thin neck + base) -----
    ctx.saveGState()
    let neckWidth = monitorWidth * 0.11
    let neckHeight = tileRect.height * 0.055
    let neckRect = CGRect(
        x: monitorRect.midX - neckWidth / 2,
        y: monitorRect.maxY,
        width: neckWidth,
        height: neckHeight
    )
    let neckColors = [
        color(52, 42, 86),
        color(26, 18, 54)
    ] as CFArray
    let neckGradient = CGGradient(colorsSpace: colorSpace,
                                  colors: neckColors,
                                  locations: [0.0, 1.0])!
    ctx.addRect(neckRect)
    ctx.clip()
    ctx.drawLinearGradient(
        neckGradient,
        start: CGPoint(x: neckRect.midX, y: neckRect.minY),
        end: CGPoint(x: neckRect.midX, y: neckRect.maxY),
        options: []
    )
    ctx.restoreGState()

    // Base — a soft rounded lozenge
    ctx.saveGState()
    let baseWidth = monitorWidth * 0.44
    let baseHeight = tileRect.height * 0.022
    let baseRect = CGRect(
        x: monitorRect.midX - baseWidth / 2,
        y: neckRect.maxY,
        width: baseWidth,
        height: baseHeight
    )
    let basePath = CGPath(roundedRect: baseRect,
                          cornerWidth: baseHeight / 2,
                          cornerHeight: baseHeight / 2,
                          transform: nil)
    ctx.addPath(basePath)
    ctx.setFillColor(color(38, 28, 72))
    ctx.fillPath()

    // Base top highlight line
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.setLineWidth(max(1, size / 512))
    ctx.addPath(basePath)
    ctx.strokePath()
    ctx.restoreGState()

    // ----- Inner tile highlight (Big Sur–style glass rim) -----
    ctx.saveGState()
    let rimPath = CGPath(roundedRect: tileRect.insetBy(dx: size * 0.004, dy: size * 0.004),
                         cornerWidth: cornerRadius * 0.98,
                         cornerHeight: cornerRadius * 0.98,
                         transform: nil)
    ctx.addPath(rimPath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
    ctx.setLineWidth(size * 0.004)
    ctx.strokePath()
    ctx.restoreGState()

    // Top gloss across the upper third
    ctx.saveGState()
    let glossColors = [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.10),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
    ] as CFArray
    let glossGradient = CGGradient(colorsSpace: colorSpace,
                                   colors: glossColors,
                                   locations: [0.0, 1.0])!
    ctx.drawLinearGradient(
        glossGradient,
        start: CGPoint(x: tileRect.midX, y: tileRect.minY),
        end: CGPoint(x: tileRect.midX, y: tileRect.minY + tileRect.height * 0.42),
        options: []
    )
    ctx.restoreGState()

    ctx.restoreGState() // end tile clip
}

// MARK: - Render base + export all sizes

let baseCtx = makeContext(size: baseSize)
drawIcon(in: baseCtx, size: baseSize)
guard let baseImage = baseCtx.makeImage() else {
    fputs("Failed to render base image\n", stderr)
    exit(1)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                     UTType.png.identifier as CFString,
                                                     1,
                                                     nil) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image dest"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG"])
    }
}

func resize(_ image: CGImage, to size: Int) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

// iconset layout
let entries: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (pixelSize, filename) in entries {
    let img = (pixelSize == Int(baseSize)) ? baseImage : resize(baseImage, to: pixelSize)
    let url = iconsetDir.appendingPathComponent(filename)
    try writePNG(img, to: url)
    print("wrote \(filename) (\(pixelSize)x\(pixelSize))")
}

// Also write a master 1024 copy next to this script for convenience
let masterURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/icon_source/icon_1024.png")
try writePNG(baseImage, to: masterURL)
print("wrote master icon_1024.png")
