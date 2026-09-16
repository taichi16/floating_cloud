import AppKit
import CoreGraphics

let srcUrl = URL(fileURLWithPath: "/Users/taichi/.gemini/antigravity-ide/brain/473e21ba-bb75-490b-8ae5-6e65fa426f13/.user_uploaded/media_1789525704410.png")
guard let srcImg = NSImage(contentsOf: srcUrl),
      let srcRep = srcImg.representations.first as? NSBitmapImageRep,
      let srcCg = srcRep.cgImage else {
    print("Cannot open image")
    exit(1)
}

// Exact bounding box of the card
let minX = 191
let minY = 149
let cardW = 642
let cardH = 383

guard let cardCg = srcCg.cropping(to: CGRect(x: minX, y: minY, width: cardW, height: cardH)) else {
    print("Cropping failed")
    exit(1)
}

print("Successfully cropped user's card: \(cardW) x \(cardH)")

// Save raw clean card
let cleanCardImg = NSImage(cgImage: cardCg, size: NSSize(width: cardW, height: cardH))
let cleanRep = NSBitmapImageRep(cgImage: cardCg)
let cleanPngData = cleanRep.representation(using: .png, properties: [:])!
let extractedUrl = URL(fileURLWithPath: "/Users/taichi/AI/floating_cloud/src/unifyIME/Resources/Logo.png")
try! cleanPngData.write(to: extractedUrl)

// 1. Generate Bopomofo.tiff (macOS Menu Bar Icon)
// Standard menu bar size is 22 x 16 pt (aspect ratio 1.375)
// The card aspect ratio is 642 / 383 ≈ 1.676
// In a 22 x 16 pt canvas, we fit the card with optimal margin
func makeMenuBarRep(widthPt: CGFloat, heightPt: CGFloat, scale: CGFloat) -> NSBitmapImageRep {
    let pxW = Int(widthPt * scale)
    let pxH = Int(heightPt * scale)
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: pxW,
        height: pxH,
        bitsPerComponent: 8,
        bytesPerRow: pxW * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    
    ctx.scaleBy(x: scale, y: scale)
    
    // Fit card nicely inside 22 x 16 pt
    // Card ratio: 1.676. Max fit inside 21.5 x 15 pt
    let targetH: CGFloat = 13.5
    let targetW: CGFloat = targetH * (CGFloat(cardW) / CGFloat(cardH))
    let drawX: CGFloat = (widthPt - targetW) / 2.0
    let drawY: CGFloat = (heightPt - targetH) / 2.0
    
    ctx.interpolationQuality = .high
    ctx.draw(cardCg, in: CGRect(x: drawX, y: drawY, width: targetW, height: targetH))
    
    let cgImg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cgImg)
    rep.size = NSSize(width: widthPt, height: heightPt)
    return rep
}

let rep1x = makeMenuBarRep(widthPt: 22, heightPt: 16, scale: 1.0)
let rep2x = makeMenuBarRep(widthPt: 22, heightPt: 16, scale: 2.0)

let menuImg = NSImage(size: NSSize(width: 22, height: 16))
menuImg.addRepresentation(rep1x)
menuImg.addRepresentation(rep2x)

let tiffData = menuImg.tiffRepresentation!
let destTiff = URL(fileURLWithPath: "/Users/taichi/AI/floating_cloud/src/unifyIME/Resources/Bopomofo.tiff")
try! tiffData.write(to: destTiff)
print("Successfully generated menu bar icon Bopomofo.tiff at \(destTiff.path)")

// 2. Generate AppIcon.icns
let iconSizes: [(size: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

let iconsetDir = URL(fileURLWithPath: "/Users/taichi/AI/floating_cloud/build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try! FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for (size, scale) in iconSizes {
    let px = size * scale
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: px * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    
    // Fit card inside square icon canvas with 10% breathing margin
    let fitW = CGFloat(px) * 0.90
    let fitH = fitW * (CGFloat(cardH) / CGFloat(cardW))
    let drawX = (CGFloat(px) - fitW) / 2.0
    let drawY = (CGFloat(px) - fitH) / 2.0
    
    ctx.interpolationQuality = .high
    ctx.draw(cardCg, in: CGRect(x: drawX, y: drawY, width: fitW, height: fitH))
    
    let icnImg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: icnImg)
    let pngData = rep.representation(using: .png, properties: [:])!
    
    let filename = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    let fileUrl = iconsetDir.appendingPathComponent(filename)
    try! pngData.write(to: fileUrl)
}

print("Iconset created. Generating AppIcon.icns...")
