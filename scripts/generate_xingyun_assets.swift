import AppKit

func createIcon(size: CGFloat, text: String, cornerRadius: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // Precise background color #95D3CE (RGB: 149, 211, 206)
    let bgColor = NSColor(red: 149.0/255.0, green: 211.0/255.0, blue: 206.0/255.0, alpha: 1.0)
    bgColor.setFill()
    
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.fill()
    
    // Choose Microsoft JhengHei or PingFang TC Semibold fallback
    var font: NSFont?
    let fontNames = [
        "MicrosoftJhengHeiBold",
        "Microsoft JhengHei Bold",
        "MicrosoftJhengHeiRegular",
        "Microsoft JhengHei",
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

// 1. Generate Bopomofo.tiff (32x32 for macOS input menu bar)
let bopomofoIcon = createIcon(size: 32, text: "行雲", cornerRadius: 6)
if let rep = bopomofoIcon.representations.first as? NSBitmapImageRep,
   let tiffData = rep.representation(using: .tiff, properties: [:]) {
    let dest = URL(fileURLWithPath: "src/unifyIME/Resources/Bopomofo.tiff")
    try! tiffData.write(to: dest)
    print("Generated Bopomofo.tiff at \(dest.path)")
} else if let tiffData = bopomofoIcon.tiffRepresentation {
    let dest = URL(fileURLWithPath: "src/unifyIME/Resources/Bopomofo.tiff")
    try! tiffData.write(to: dest)
    print("Generated Bopomofo.tiff at \(dest.path)")
}

// 2. Generate AppIcon.icns
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
    let radius = size * 0.22 // macOS squircle ratio
    let icon = createIcon(size: size, text: "行雲", cornerRadius: radius)
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
