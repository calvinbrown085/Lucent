#!/usr/bin/env swift
// Generates placeholder PNGs for Lucent's tvOS brandassets and patches each
// Contents.json to reference them. Run from the repo root:
//
//     swift scripts/generate-placeholder-icons.swift
//
// Re-run any time. Idempotent: overwrites PNGs and rewrites Contents.json.
// All icons render as a layered "L" monogram so the parallax effect on tvOS
// Home is visible (Back = solid fill, Middle = colored "L", Front = outlined "L").

import Foundation
import CoreGraphics
import ImageIO
import CoreText
import UniformTypeIdentifiers

// MARK: - Drawing primitives

enum LayerStyle {
    case back        // flat color fill
    case middle      // filled "L"
    case front       // outlined "L"
    case topShelf    // wide hero with text "LUCENT"
}

func draw(width: Int, height: Int, style: LayerStyle, output: URL) throws {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "draw", code: 1)
    }

    // Background
    let bg = CGColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1)
    ctx.setFillColor(bg)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Subtle gradient for depth
    let gradColors = [
        CGColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 1),
        CGColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: gradColors, locations: [0, 1]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
    }

    let accent = CGColor(red: 0.40, green: 0.78, blue: 1.0, alpha: 1)

    switch style {
    case .back:
        // Just background — leave as-is.
        break

    case .middle:
        drawL(in: ctx, width: width, height: height, fill: accent, outline: nil)

    case .front:
        let outline = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)
        drawL(in: ctx, width: width, height: height, fill: nil, outline: outline)

    case .topShelf:
        drawText(
            in: ctx,
            text: "LUCENT",
            width: width,
            height: height,
            color: accent
        )
    }

    let dest = CGImageDestinationCreateWithURL(
        output as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    )
    guard let dest, let img = ctx.makeImage() else {
        throw NSError(domain: "encode", code: 1)
    }
    CGImageDestinationAddImage(dest, img, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "finalize", code: 1)
    }
}

func drawL(in ctx: CGContext, width: Int, height: Int, fill: CGColor?, outline: CGColor?) {
    let w = CGFloat(width), h = CGFloat(height)
    // Vertical stem and horizontal foot of an "L".
    let stemW = w * 0.16
    let stemH = h * 0.62
    let footW = w * 0.40
    let footH = h * 0.16
    let originX = w * 0.32
    let originY = h * 0.20
    let stem = CGRect(x: originX, y: originY + footH, width: stemW, height: stemH - footH)
    let foot = CGRect(x: originX, y: originY, width: footW, height: footH)
    let path = CGMutablePath()
    path.addRect(stem)
    path.addRect(foot)
    if let fill {
        ctx.setFillColor(fill)
        ctx.addPath(path)
        ctx.fillPath()
    }
    if let outline {
        ctx.setStrokeColor(outline)
        ctx.setLineWidth(max(2, w * 0.012))
        ctx.addPath(path)
        ctx.strokePath()
    }
}

func drawText(in ctx: CGContext, text: String, width: Int, height: Int, color: CGColor) {
    let fontSize = CGFloat(height) * 0.32
    let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
        kCTKernAttributeName: fontSize * 0.05
    ]
    let attributed = CFAttributedStringCreate(
        kCFAllocatorDefault,
        text as CFString,
        attrs as CFDictionary
    )!
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetImageBounds(line, ctx)
    let tx = (CGFloat(width) - bounds.width) / 2 - bounds.minX
    let ty = (CGFloat(height) - bounds.height) / 2 - bounds.minY
    ctx.textPosition = CGPoint(x: tx, y: ty)
    CTLineDraw(line, ctx)
}

// MARK: - Output plan

struct LayerSpec {
    let imagesetDir: URL
    let style: LayerStyle
    let scales: [(filename: String, scale: Int, width: Int, height: Int)]
}

let assetRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Lucent/Lucent/Assets.xcassets/App Icon & Top Shelf Image.brandassets")

func iconLayer(stack: String, layer: String, style: LayerStyle, sizes: [(Int, Int, Int)]) -> LayerSpec {
    let imageset = assetRoot
        .appendingPathComponent("\(stack).imagestack")
        .appendingPathComponent("\(layer).imagestacklayer")
        .appendingPathComponent("Content.imageset")
    let scales = sizes.map { (s, w, h) -> (String, Int, Int, Int) in
        let suffix = s == 1 ? "" : "@\(s)x"
        return ("\(layer)\(suffix).png", s, w, h)
    }
    return LayerSpec(imagesetDir: imageset, style: style, scales: scales)
}

func topShelf(name: String, sizes: [(Int, Int, Int)]) -> LayerSpec {
    let imageset = assetRoot.appendingPathComponent("\(name).imageset")
    let baseName = name.replacingOccurrences(of: " ", with: "-").lowercased()
    let scales = sizes.map { (s, w, h) -> (String, Int, Int, Int) in
        let suffix = s == 1 ? "" : "@\(s)x"
        return ("\(baseName)\(suffix).png", s, w, h)
    }
    return LayerSpec(imagesetDir: imageset, style: .topShelf, scales: scales)
}

// Per Apple tvOS HIG:
//   App Icon (drawer):       400×240 (1x), 800×480 (2x)
//   App Icon (App Store):    1280×768 (1x only)
//   Top Shelf Image:         1920×720 (1x), 3840×1440 (2x)
//   Top Shelf Image Wide:    2320×720 (1x), 4640×1440 (2x)
let iconStackSizes: [(Int, Int, Int)] = [(1, 400, 240), (2, 800, 480)]
let appStoreStackSizes: [(Int, Int, Int)] = [(1, 1280, 768)]
let topShelfSizes: [(Int, Int, Int)] = [(1, 1920, 720), (2, 3840, 1440)]
let topShelfWideSizes: [(Int, Int, Int)] = [(1, 2320, 720), (2, 4640, 1440)]

let specs: [LayerSpec] = [
    iconLayer(stack: "App Icon", layer: "Back", style: .back, sizes: iconStackSizes),
    iconLayer(stack: "App Icon", layer: "Middle", style: .middle, sizes: iconStackSizes),
    iconLayer(stack: "App Icon", layer: "Front", style: .front, sizes: iconStackSizes),
    iconLayer(stack: "App Icon - App Store", layer: "Back", style: .back, sizes: appStoreStackSizes),
    iconLayer(stack: "App Icon - App Store", layer: "Middle", style: .middle, sizes: appStoreStackSizes),
    iconLayer(stack: "App Icon - App Store", layer: "Front", style: .front, sizes: appStoreStackSizes),
    topShelf(name: "Top Shelf Image", sizes: topShelfSizes),
    topShelf(name: "Top Shelf Image Wide", sizes: topShelfWideSizes),
]

// MARK: - Run

func patchContentsJSON(at imagesetDir: URL, scales: [(filename: String, scale: Int, width: Int, height: Int)]) throws {
    let contents = imagesetDir.appendingPathComponent("Contents.json")
    let images: [[String: Any]] = scales.map { entry -> [String: Any] in
        var dict: [String: Any] = [
            "idiom": "tv",
            "filename": entry.filename
        ]
        if scales.count > 1 || entry.scale != 1 {
            dict["scale"] = "\(entry.scale)x"
        }
        return dict
    }
    let json: [String: Any] = [
        "images": images,
        "info": ["author": "xcode", "version": 1]
    ]
    let data = try JSONSerialization.data(
        withJSONObject: json,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(to: contents)
}

var produced = 0
for spec in specs {
    try FileManager.default.createDirectory(at: spec.imagesetDir, withIntermediateDirectories: true)
    for entry in spec.scales {
        let url = spec.imagesetDir.appendingPathComponent(entry.filename)
        try draw(width: entry.width, height: entry.height, style: spec.style, output: url)
        produced += 1
    }
    try patchContentsJSON(at: spec.imagesetDir, scales: spec.scales)
}
print("[icons] Wrote \(produced) PNGs under \(assetRoot.path)")
