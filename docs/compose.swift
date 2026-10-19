import AppKit

// Places island snapshots on a simple desktop backdrop (gradient wallpaper + menu bar), centred under the notch.
// usage: compose <out.png> <canvas width px> <canvas height px> <island.png>...
// Several islands are laid out side by side, each in its own column.

let args = CommandLine.arguments
let (out, width, height) = (args[1], CGFloat(Double(args[2])!), CGFloat(Double(args[3])!))
let islands = args.dropFirst(4).map { NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: $0)))! }
let menuBar: CGFloat = 76  // 38 pt at 2x, the height of a notched MacBook's menu bar

let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)

NSGradient(colors: [NSColor(red: 0.13, green: 0.12, blue: 0.27, alpha: 1),
                    NSColor(red: 0.30, green: 0.17, blue: 0.38, alpha: 1),
                    NSColor(red: 0.85, green: 0.45, blue: 0.40, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 70)
NSColor(white: 0, alpha: 0.28).setFill()
NSRect(x: 0, y: height - menuBar, width: width, height: menuBar).fill()

let column = width / CGFloat(islands.count)
for (i, island) in islands.enumerated() {
    let size = NSSize(width: island.pixelsWide, height: island.pixelsHigh)
    let x = column * CGFloat(i) + (column - size.width) / 2
    island.draw(in: NSRect(x: x, y: height - size.height, width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

NSGraphicsContext.current = nil
try! canvas.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
