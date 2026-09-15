import AppKit

// 1. Generate Bopomofo.tiff (22x16 pt, matching macOS input menu standard like vChewing)
func createMenuIconRep(width: CGFloat, height: CGFloat, scale: CGFloat, fontSize: CGFloat) -> NSBitmapImageRep {
    let pxW = Int(width * scale)
    let pxH = Int(height * scale)
    
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pxW,
        pixelsHigh: pxH,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: pxW * 4,
        bitsPerPixel: 32
    )!
    rep.size = NSSize(width: width, height: height)
    
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    let cornerRadius: CGFloat = 3.5
    let bgColor = NSColor(red: 149.0/255.0, green: 211.0/255.0, blue: 206.0/255.0, alpha: 1.0)
    bgColor.setFill()
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.fill()
    
    var font: NSFont?
    let fontNames = [
        "MicrosoftJhengHeiBold",
        "Microsoft JhengHei Bold",
        "PingFangTC-Semibold",
        "PingFangTC-Medium",
        "Heiti TC"
    ]
    for name in fontNames {
        if let f = NSFont(name: name, size: fontSize) {
            font = f
            break
        }
    }
    if font == nil {
        font = NSFont.boldSystemFont(ofSize: fontSize)
    }
    
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font!,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraphStyle,
        .kern: -0.3
    ]
    
    let str = NSAttributedString(string: "行雲", attributes: attrs)
    let strSize = str.size()
    let textRect = NSRect(
        x: (width - strSize.width) / 2.0,
        y: (height - strSize.height) / 2.0 - 0.2,
        width: strSize.width,
        height: strSize.height
    )
    str.draw(in: textRect)
    
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let w: CGFloat = 22.0
let h: CGFloat = 16.0
let rep1 = createMenuIconRep(width: w, height: h, scale: 1.0, fontSize: 11.0)
let rep2 = createMenuIconRep(width: w, height: h, scale: 2.0, fontSize: 11.0)

let menuImg = NSImage(size: NSSize(width: w, height: h))
menuImg.addRepresentation(rep1)
menuImg.addRepresentation(rep2)

if let data = menuImg.tiffRepresentation {
    let dest = URL(fileURLWithPath: "src/unifyIME/Resources/Bopomofo.tiff")
    try! data.write(to: dest)
    print("Generated 22x16 Bopomofo.tiff at \(dest.path)")
}

// 2. Generate AppIcon.icns
func createAppIcon(size: CGFloat, text: String, cornerRadius: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let bgColor = NSColor(red: 149.0/255.0, green: 211.0/255.0, blue: 206.0/255.0, alpha: 1.0)
    bgColor.setFill()
    
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.fill()
    
    var font: NSFont?
    let fontNames = [
        "MicrosoftJhengHeiBold",
        "Microsoft JhengHei Bold",
        "PingFangTC-Semibold",
        "PingFangTC-Medium",
        "Heiti TC"
    ]
    for name in fontNames {
        if let f = NSFont(name: name, size: size * 0.44) {
            font = f
            break
        }
    }
    if font == nil {
        font = NSFont.systemFont(ofSize: size * 0.44, weight: .bold)
    }
    
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font!,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraphStyle
    ]
    
    let str = NSAttributedString(string: text, attributes: attrs)
    let strSize = str.size()
    let textRect = NSRect(
        x: (size - strSize.width) / 2.0,
        y: (size - strSize.height) / 2.0 - (size * 0.02),
        width: strSize.width,
        height: strSize.height
    )
    str.draw(in: textRect)
    
    img.unlockFocus()
    return img
}

let fm = FileManager.default
let iconsetDir = URL(fileURLWithPath: "/tmp/FloatingCloudAppIcon.iconset")
try? fm.removeItem(at: iconsetDir)
try! fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in sizes {
    let radius = size * 0.22
    let icon = createAppIcon(size: size, text: "行雲", cornerRadius: radius)
    if let tiffData = icon.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiffData),
       let pngData = rep.representation(using: .png, properties: [:]) {
        let fileURL = iconsetDir.appendingPathComponent(filename)
        try! pngData.write(to: fileURL)
    }
}

let icnsDest = URL(fileURLWithPath: "src/unifyIME/Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsDest.path]
try! task.run()
task.waitUntilExit()
print("Generated AppIcon.icns at \(icnsDest.path)")
try? fm.removeItem(at: iconsetDir)
