import AppKit

// Run on macOS 26 or later to preserve the numbered calendar symbol style on older systems.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift Scripts/generate-menu-bar-date-icons.swift <output-directory>")
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
_ = NSApplication.shared
NSApp.appearance = NSAppearance(named: .aqua)
let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)

for day in 1...31 {
    guard let image = NSImage(systemSymbolName: "\(day).calendar", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else {
        fatalError("Numbered calendar symbols require macOS 26 or later.")
    }
    for scale in [CGFloat(1), CGFloat(2)] {
        let width = Int(ceil(image.size.width * scale))
        let height = Int(ceil(image.size.height * scale))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        bitmap.size = image.size
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("MenuBarDate\(day)\(suffix).png"))
    }
}
print("Generated 31 numbered calendar templates at 1x and 2x.")
