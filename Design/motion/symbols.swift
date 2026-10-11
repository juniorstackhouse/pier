// Exports the SF Symbols the motion uses (the ones the app draws: the edge tab, the Inbox, the Live Activity, the
// notification's actions, the system bars) as white PNGs with alpha, so the video can tint them like the real UI.
// Run: `swift Design/motion/symbols.swift Design/motion/assets/symbols`
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let symbols: [(String, NSFont.Weight)] = [
    ("tray.fill", .semibold), ("plus", .semibold), ("bubble.left.and.text.bubble.right.fill", .semibold), ("camera.fill", .semibold),
    ("ellipsis", .semibold), ("xmark", .semibold), ("checkmark", .bold), ("mic.fill", .semibold), ("arrow.up.circle.fill", .semibold),
    ("arrow.up.forward.app", .semibold), ("eye.slash", .semibold), ("list.number", .semibold), ("questionmark.bubble.fill", .semibold),
    ("exclamationmark.bubble.fill", .semibold), ("checkmark.circle.fill", .semibold), ("doc.text.magnifyingglass", .semibold),
    ("apple.logo", .regular), ("wifi", .semibold), ("battery.100percent", .regular), ("cellularbars", .semibold),
    ("magnifyingglass", .medium), ("switch.2", .medium), ("1.circle", .regular), ("2.circle", .regular), ("3.circle", .regular),
    ("arrow.up.forward.square", .regular), ("lock.fill", .semibold), ("flashlight.off.fill", .regular), ("server.rack", .semibold),
    ("iphone", .regular), ("laptopcomputer", .regular), ("bolt.fill", .bold), ("chevron.left", .semibold), ("sparkles", .semibold),
    ("terminal.fill", .semibold), ("person.crop.circle.fill", .regular), ("bell.fill", .semibold), ("lock.open.fill", .semibold),
    ("circle.dotted", .semibold), ("hourglass", .semibold), ("gearshape.fill", .semibold), ("shippingbox.fill", .semibold),
]
for (name, weight) in symbols {
    let config = NSImage.SymbolConfiguration(pointSize: 96, weight: weight)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        print("missing", name); continue
    }
    let size = symbol.size, scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(origin: .zero, size: size)
    symbol.draw(in: rect)
    NSColor.white.set()
    rect.fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    let file = out.appendingPathComponent(name + ".png")
    try! rep.representation(using: .png, properties: [:])!.write(to: file)
    print(name, Int(size.width), "x", Int(size.height))
}
