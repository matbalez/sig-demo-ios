// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation

// Render the demo's own monogram, without the Signal Messenger icon. iOS adds
// the platform mask; keep the entire source image opaque and square.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift render-icon.swift OUTPUT.png")
}
let size = 1024
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Cannot create the icon bitmap.")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let canvas = NSRect(x: 0, y: 0, width: size, height: size)
let pink = NSColor(srgbRed: 1, green: 79.0 / 255, blue: 163.0 / 255, alpha: 1)
let deepPink = NSColor(srgbRed: 233.0 / 255, green: 42.0 / 255, blue: 133.0 / 255, alpha: 1)
NSGradient(starting: deepPink, ending: pink)!.draw(in: canvas, angle: 90)
let word = NSAttributedString(string: "sig", attributes: [
    .font: NSFont.systemFont(ofSize: 430, weight: .bold),
    .foregroundColor: NSColor.white,
    .kern: -22
])
let bounds = word.boundingRect(with: canvas.size, options: [.usesLineFragmentOrigin])
word.draw(at: NSPoint(x: (canvas.width - bounds.width) / 2 + 8,
                      y: (canvas.height - bounds.height) / 2 + 25))
NSGraphicsContext.restoreGraphicsState()
guard let image = context.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode the icon.")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
