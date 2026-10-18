// Renders icon/ephedrine-icon.svg (a drawn coffee cup, the Claude spark as its steam) into AppIcon.icns.
//   swift icon/make-icon.swift   (run from the repo root; writes Resources/AppIcon.icns)
import AppKit

guard let art = NSImage(contentsOf: URL(fileURLWithPath: "icon/ephedrine-icon.svg")) else {
    print("could not load icon/ephedrine-icon.svg (run from the repo root)"); exit(1)
}

func render(size px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    art.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let set = "AppIcon.iconset"
try? fm.removeItem(atPath: set)
try! fm.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(size: base * scale).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "\(set)/\(name)"))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(atPath: set)
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
