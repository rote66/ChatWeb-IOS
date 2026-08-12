#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconVariant {
    let filename: String
    let pixels: Int
}

let variants = [
    IconVariant(filename: "Icon-20.png", pixels: 20),
    IconVariant(filename: "Icon-20@2x.png", pixels: 40),
    IconVariant(filename: "Icon-20@2x-ipad.png", pixels: 40),
    IconVariant(filename: "Icon-20@3x.png", pixels: 60),
    IconVariant(filename: "Icon-29.png", pixels: 29),
    IconVariant(filename: "Icon-29@2x.png", pixels: 58),
    IconVariant(filename: "Icon-29@2x-ipad.png", pixels: 58),
    IconVariant(filename: "Icon-29@3x.png", pixels: 87),
    IconVariant(filename: "Icon-40.png", pixels: 40),
    IconVariant(filename: "Icon-40@2x.png", pixels: 80),
    IconVariant(filename: "Icon-40@2x-ipad.png", pixels: 80),
    IconVariant(filename: "Icon-40@3x.png", pixels: 120),
    IconVariant(filename: "Icon-60@2x.png", pixels: 120),
    IconVariant(filename: "Icon-60@3x.png", pixels: 180),
    IconVariant(filename: "Icon-76.png", pixels: 76),
    IconVariant(filename: "Icon-76@2x.png", pixels: 152),
    IconVariant(filename: "Icon-83.5@2x.png", pixels: 167),
    IconVariant(filename: "Icon-1024.png", pixels: 1024)
]

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift <AppIcon.appiconset>\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func drawIcon(pixels: Int) throws -> CGImage {
    let dimension = CGFloat(pixels)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
    guard let context = CGContext(data: nil,
                                  width: pixels,
                                  height: pixels,
                                  bitsPerComponent: 8,
                                  bytesPerRow: pixels * 4,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo.rawValue) else {
        throw NSError(domain: "IconGenerator", code: 1)
    }
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.scaleBy(x: dimension / 1024, y: dimension / 1024)

    context.setFillColor(color(0.055, 0.071, 0.094))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let upperBubble = CGPath(roundedRect: CGRect(x: 150, y: 420, width: 570, height: 390),
                             cornerWidth: 118,
                             cornerHeight: 118,
                             transform: nil)
    context.setFillColor(color(0.10, 0.47, 0.92))
    context.addPath(upperBubble)
    context.fillPath()
    context.beginPath()
    context.move(to: CGPoint(x: 240, y: 448))
    context.addLine(to: CGPoint(x: 170, y: 305))
    context.addLine(to: CGPoint(x: 365, y: 438))
    context.closePath()
    context.fillPath()

    let lowerBubble = CGPath(roundedRect: CGRect(x: 330, y: 210, width: 544, height: 360),
                             cornerWidth: 112,
                             cornerHeight: 112,
                             transform: nil)
    context.setFillColor(color(0.08, 0.73, 0.57))
    context.addPath(lowerBubble)
    context.fillPath()
    context.beginPath()
    context.move(to: CGPoint(x: 790, y: 238))
    context.addLine(to: CGPoint(x: 855, y: 115))
    context.addLine(to: CGPoint(x: 665, y: 225))
    context.closePath()
    context.fillPath()

    context.setFillColor(color(1, 1, 1, 0.94))
    for centerX in [438.0, 548.0, 658.0] {
        context.fillEllipse(in: CGRect(x: centerX - 27, y: 357, width: 54, height: 54))
    }

    guard let image = context.makeImage() else {
        throw NSError(domain: "IconGenerator", code: 2)
    }
    return image
}

for variant in variants {
    let image = try drawIcon(pixels: variant.pixels)
    let destinationURL = outputDirectory.appendingPathComponent(variant.filename)
    guard let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw NSError(domain: "IconGenerator", code: 3)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "IconGenerator", code: 4)
    }
}

print("Generated \(variants.count) icon files in \(outputDirectory.path)")
