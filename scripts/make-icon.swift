// Export the user's supplied logo into app resources without redrawing the mark.
// Usage: swift scripts/make-icon.swift <icon-1024.png>
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Resources/TeboLogoSource.png")
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
guard let image = NSImage(contentsOf: source),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let crop = cgImage.cropping(to: CGRect(x: 286, y: 272, width: 682, height: 687)) else {
    fatalError("The supplied Tebo logo could not be read")
}
let width = crop.width, height = crop.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { storage in
    let context = CGContext(data: storage.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
}
// Remove only the connected exterior photographic background. The white T and
// sparkles remain untouched, enclosed by the original dark icon silhouette.
var queue: [Int] = []
var visited = [Bool](repeating: false, count: width * height)
func enqueue(_ index: Int) {
    guard !visited[index] else { return }
    visited[index] = true
    let offset = index * 4
    guard Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2]) > 360 else { return }
    queue.append(index)
}
for x in 0..<width { enqueue(x); enqueue((height - 1) * width + x) }
for y in 0..<height { enqueue(y * width); enqueue(y * width + width - 1) }
var cursor = 0
while cursor < queue.count {
    let index = queue[cursor]; cursor += 1
    let x = index % width, y = index / width
    if x > 0 { enqueue(index - 1) }
    if x + 1 < width { enqueue(index + 1) }
    if y > 0 { enqueue(index - width) }
    if y + 1 < height { enqueue(index + width) }
    for channel in 0..<4 { pixels[index * 4 + channel] = 0 }
}
let data = Data(pixels)
let provider = CGDataProvider(data: data as CFData)!
let extracted = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
func export(to path: String, inset: CGFloat) {
    let side = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high
    ctx.draw(extracted, in: CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
export(to: root.appendingPathComponent("Resources/TeboLogo.png").path, inset: 0)
export(to: output, inset: 70)
print("Exported the supplied Tebo logo and icon")
