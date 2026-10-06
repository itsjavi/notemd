#!/usr/bin/env swift
// Draws the layers of NoteMD's Icon Composer icon (AppIcon.icon/Assets/*.png) on a 1024 pt canvas.
// Usage: swift scripts/make-icon.swift [Resources/AppIcon.icon]   (or `make icon`)
//
// Motif: a Markdown note card with a bold amber `#` heading mark and text lines, with an older
// version of the note peeking out behind it (versioning). The background fill, glass, shadow and
// dark appearance live in AppIcon.icon/icon.json; edit that by hand or in Icon Composer. This
// script only rewrites Assets/, so those edits survive a redraw.
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icon"
let canvas: CGFloat = 1024

func color(_ hex: String, _ alpha: CGFloat = 1) -> NSColor {
    let v = UInt32(hex.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

/// One layer on a transparent canvas. Draw flat shapes only: the system adds glass, highlights and shadows.
func layer(_ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Fills a path with a gentle top-to-bottom two-stop gradient. AppKit's origin is bottom-left.
func gradientFill(_ path: NSBezierPath, _ top: String, _ bottom: String) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [color(top), color(bottom)])!.draw(in: path.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

/// Rotates subsequent drawing by `degrees` (counterclockwise) around `center`.
func rotate(_ degrees: CGFloat, around center: NSPoint) {
    let t = NSAffineTransform()
    t.translateX(by: center.x, yBy: center.y)
    t.rotate(byDegrees: degrees)
    t.translateX(by: -center.x, yBy: -center.y)
    t.concat()
}

// MARK: - Layout constants (redraws should change numbers here, not code)

// Artwork stays inside the middle ~60% of the canvas so the system mask, glass and shadow have room.
let artFraction: CGFloat = 0.66
let art = NSRect(x: canvas * (1 - artFraction) / 2, y: canvas * (1 - artFraction) / 2,
                 width: canvas * artFraction, height: canvas * artFraction)
let unit = art.width

// Note card (portrait, like a sheet of paper).
let cardSize = NSSize(width: unit * 0.64, height: unit * 0.80)
let cardRadius = cardSize.width * 0.10
// Previous version: same card, nudged up-right and turned a little, peeking out behind the front one.
let backOffset = NSPoint(x: unit * 0.16, y: unit * 0.12)
let backTurn: CGFloat = -7
// The front card is placed so the two-card stack is centered in the artwork area.
let card = NSRect(x: art.midX - (cardSize.width + backOffset.x) / 2,
                  y: art.midY - (cardSize.height + backOffset.y) / 2,
                  width: cardSize.width, height: cardSize.height)

// Content inside the front card.
let contentInset = cardSize.width * 0.15
let hashSize = cardSize.width * 0.50
let hashStroke = hashSize * 0.19
let hashSlant: CGFloat = 0.20  // horizontal lean of the verticals per unit of height
let lineHeight = cardSize.height * 0.062
let lineGap = cardSize.height * 0.075
let lineWidths: [CGFloat] = [1.0, 0.78, 0.9]

// Palette: deep teal field (icon.json), paper white cards, amber heading mark, cool slate text.
let paperTop = "#FFFFFF", paperBottom = "#E9F1EF"
let backTop = "#CFEAE5", backBottom = "#A5D3CC"
let amberTop = "#FFB547", amberBottom = "#F27F1B"
let ink = "#8FA8AC"

// MARK: - Layers

/// The `#` heading mark built from four rounded strokes (no font dependency, crisp at every size).
func hashPath(in r: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    path.lineWidth = hashStroke
    path.lineCapStyle = .round
    let pad = hashStroke / 2
    let lean = (r.height - 2 * pad) * hashSlant
    for fx: CGFloat in [0.36, 0.72] {  // the two slanted uprights
        let x = r.minX + r.width * fx - lean / 2
        path.move(to: NSPoint(x: x, y: r.minY + pad))
        path.line(to: NSPoint(x: x + lean, y: r.maxY - pad))
    }
    for fy: CGFloat in [0.33, 0.68] {  // the two crossbars
        let y = r.minY + r.height * fy
        path.move(to: NSPoint(x: r.minX + pad, y: y))
        path.line(to: NSPoint(x: r.maxX - pad, y: y))
    }
    return path
}

let hashRect = NSRect(x: card.minX + contentInset, y: card.maxY - contentInset - hashSize,
                      width: hashSize, height: hashSize)

// icon.json lists these front to back: its first layer is drawn on top.
let layers: [(String, NSBitmapImageRep)] = [
    ("heading", layer {
        let stroke = hashPath(in: hashRect)
        let outline = NSBezierPath()
        // Turn the stroked path into a fillable shape so it can take a gradient.
        let cg = stroke.cgPath.copy(strokingWithWidth: hashStroke, lineCap: .round, lineJoin: .round,
                                    miterLimit: 10)
        outline.append(NSBezierPath(cgPath: cg))
        outline.windingRule = .nonZero
        gradientFill(outline, amberTop, amberBottom)
    }),
    ("note", layer {
        gradientFill(NSBezierPath(roundedRect: card, xRadius: cardRadius, yRadius: cardRadius),
                     paperTop, paperBottom)
        // Body text lines below the heading.
        var y = hashRect.minY - lineGap * 1.1 - lineHeight
        let maxWidth = card.width - 2 * contentInset
        color(ink).setFill()
        for w in lineWidths {
            let r = NSRect(x: card.minX + contentInset, y: y, width: maxWidth * w, height: lineHeight)
            NSBezierPath(roundedRect: r, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
            y -= lineHeight + lineGap
        }
    }),
    ("version", layer {
        let r = card.offsetBy(dx: backOffset.x, dy: backOffset.y)
        rotate(backTurn, around: NSPoint(x: r.midX, y: r.midY))
        gradientFill(NSBezierPath(roundedRect: r, xRadius: cardRadius, yRadius: cardRadius),
                     backTop, backBottom)
    }),
]

let assets = URL(fileURLWithPath: output).appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: assets)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
for (name, rep) in layers {
    try rep.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("\(name).png"))
}
print("Wrote \(layers.count) layers to \(assets.path)")
