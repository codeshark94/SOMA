#!/usr/bin/swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct SourceCrop {
    let x: Int
    let yFromTop: Int
    let width: Int
    let height: Int
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("brand asset generation failed: \(message)\n".utf8))
    exit(2)
}

private func rgbaPixels(from image: CGImage) -> (pixels: [UInt8], width: Int, height: Int) {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not create the RGBA extraction context")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height)
}

private func removeConnectedBackground(
    from pixels: inout [UInt8],
    width: Int,
    height: Int
) {
    let threshold = 232
    var outside = [Bool](repeating: false, count: width * height)
    var queue = [Int]()
    queue.reserveCapacity(width * height / 2)

    func isBackground(_ pixelIndex: Int) -> Bool {
        let byteIndex = pixelIndex * 4
        let red = Int(pixels[byteIndex])
        let green = Int(pixels[byteIndex + 1])
        let blue = Int(pixels[byteIndex + 2])
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        return minimum >= threshold && maximum - minimum <= 18
    }

    func enqueue(_ pixelIndex: Int) {
        guard !outside[pixelIndex], isBackground(pixelIndex) else { return }
        outside[pixelIndex] = true
        queue.append(pixelIndex)
    }

    for x in 0..<width {
        enqueue(x)
        enqueue((height - 1) * width + x)
    }
    for y in 0..<height {
        enqueue(y * width)
        enqueue(y * width + width - 1)
    }

    var cursor = 0
    while cursor < queue.count {
        let index = queue[cursor]
        cursor += 1
        let x = index % width
        let y = index / width
        if x > 0 { enqueue(index - 1) }
        if x + 1 < width { enqueue(index + 1) }
        if y > 0 { enqueue(index - width) }
        if y + 1 < height { enqueue(index + width) }
    }

    for pixelIndex in 0..<(width * height) {
        let byteIndex = pixelIndex * 4
        if outside[pixelIndex] {
            pixels[byteIndex] = 0
            pixels[byteIndex + 1] = 0
            pixels[byteIndex + 2] = 0
            pixels[byteIndex + 3] = 0
            continue
        }

        let red = Double(pixels[byteIndex])
        let green = Double(pixels[byteIndex + 1])
        let blue = Double(pixels[byteIndex + 2])
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let opacity = UInt8(clamping: Int(((255 - luminance) * 1.18).rounded()))
        pixels[byteIndex] = 0
        pixels[byteIndex + 1] = 0
        pixels[byteIndex + 2] = 0
        pixels[byteIndex + 3] = opacity < 7 ? 0 : opacity
    }
}

private func cgImage(pixels: inout [UInt8], width: Int, height: Int) -> CGImage {
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage() else {
        fail("could not create a processed brand image")
    }
    return image
}

private func visibleBounds(in pixels: [UInt8], width: Int, height: Int) -> CGRect {
    var minimumX = width
    var minimumY = height
    var maximumX = -1
    var maximumY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 7 {
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }
    }
    guard maximumX >= minimumX, maximumY >= minimumY else {
        fail("the selected source crop contains no visible mark")
    }
    return CGRect(
        x: minimumX,
        y: minimumY,
        width: maximumX - minimumX + 1,
        height: maximumY - minimumY + 1
    )
}

private func placeOnSquareCanvas(
    _ image: CGImage,
    visibleBounds: CGRect,
    size: Int = 1024,
    padding: Int
) -> CGImage {
    guard let visible = image.cropping(to: visibleBounds.integral) else {
        fail("could not crop the visible brand mark")
    }
    let available = CGFloat(size - padding * 2)
    let scale = min(available / CGFloat(visible.width), available / CGFloat(visible.height))
    let drawWidth = CGFloat(visible.width) * scale
    let drawHeight = CGFloat(visible.height) * scale
    let destination = CGRect(
        x: (CGFloat(size) - drawWidth) / 2,
        y: (CGFloat(size) - drawHeight) / 2,
        width: drawWidth,
        height: drawHeight
    )
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not create the square brand canvas")
    }
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .high
    context.draw(visible, in: destination)
    guard let result = context.makeImage() else {
        fail("could not render the square brand canvas")
    }
    return result
}

private func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fail("could not create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("could not write \(url.path)")
    }
}

private func generateMark(
    source: CGImage,
    crop: SourceCrop,
    padding: Int
) -> CGImage {
    let cropRectangle = CGRect(
        x: crop.x,
        y: crop.yFromTop,
        width: crop.width,
        height: crop.height
    )
    guard let cropped = source.cropping(to: cropRectangle) else {
        fail("source crop is outside the canonical brand board")
    }
    var extracted = rgbaPixels(from: cropped)
    removeConnectedBackground(
        from: &extracted.pixels,
        width: extracted.width,
        height: extracted.height
    )
    let bounds = visibleBounds(in: extracted.pixels, width: extracted.width, height: extracted.height)
    let processed = cgImage(pixels: &extracted.pixels, width: extracted.width, height: extracted.height)
    return placeOnSquareCanvas(processed, visibleBounds: bounds, padding: padding)
}

private func makeApplicationIcon(from mark: CGImage, size: Int = 1024) -> CGImage {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not create the application icon canvas")
    }
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(canvas)

    let tileInset = CGFloat(size) * 0.07
    let tile = canvas.insetBy(dx: tileInset, dy: tileInset)
    let cornerRadius = CGFloat(size) * 0.135
    context.addPath(CGPath(roundedRect: tile, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillPath()

    let markSide = tile.width * 0.59
    let markRectangle = CGRect(
        x: (CGFloat(size) - markSide) / 2,
        y: (CGFloat(size) - markSide) / 2,
        width: markSide,
        height: markSide
    )
    context.saveGState()
    context.clip(to: markRectangle, mask: mark)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(markRectangle)
    context.restoreGState()

    guard let icon = context.makeImage() else {
        fail("could not render the application icon")
    }
    return icon
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: swift scripts/generate-soma-brand-assets.swift SOURCE.png OUTPUT_DIRECTORY")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fail("could not read \(sourceURL.path)")
}
guard source.width == 1254, source.height == 1254 else {
    fail("canonical board must be 1254 x 1254 pixels; found \(source.width) x \(source.height)")
}

let mark = generateMark(
    source: source,
    crop: SourceCrop(x: 340, yFromTop: 100, width: 574, height: 574),
    padding: 88
)
writePNG(mark, to: outputDirectory.appendingPathComponent("soma-mark.png"))
writePNG(makeApplicationIcon(from: mark), to: outputDirectory.appendingPathComponent("soma-app-icon.png"))
