// Draws CompShot icon concepts from scratch using 1Shot's icon measurements (frame, green, ring, ticks),
// plus a redraw of 1Shot's own icon to check the match.
//   xcrun swift Tools/make-icon-concepts.swift outDir
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S: CGFloat = 1024
func up(_ y: CGFloat) -> CGFloat { S - y }                       // measured top-down, drawn bottom-up
func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }

let greenTop = srgb(64, 81, 26), greenBottom = srgb(40, 54, 14)
let cream = srgb(239, 237, 227), white = srgb(253, 253, 253)
let screenGreen = srgb(62, 204, 70)
let checkLight = NSColor(white: 0.90, alpha: 1), checkDark = NSColor(white: 0.62, alpha: 1)

/// 1Shot's frame: green rounded square, cream viewfinder ring and four ticks.
func frame() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 101, y: 101, width: 822, height: 822), xRadius: 190, yRadius: 190)
    NSGradient(starting: greenTop, ending: greenBottom)!.draw(in: tile, angle: -90)
    cream.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 512 - 297, y: 512 - 297, width: 594, height: 594)); ring.lineWidth = 22; ring.stroke()
    cream.setFill()
    for r in [NSRect(x: 501, y: up(306), width: 22, height: 146), NSRect(x: 501, y: up(864), width: 22, height: 146),
              NSRect(x: 157, y: 501, width: 140, height: 22), NSRect(x: 727, y: 501, width: 140, height: 22)] { r.fill() }
}

func render(_ name: String, _ center: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    frame(); center()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

func softShadow() {
    let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.35); s.shadowBlurRadius = 18
    s.shadowOffset = NSSize(width: 0, height: -6); s.set()
}

func checker(in rect: NSRect, cell: CGFloat) {
    checkLight.setFill(); rect.fill()
    checkDark.setFill()
    var y = rect.minY, row = 0
    while y < rect.maxY {
        var x = rect.minX + (row % 2 == 0 ? 0 : cell)
        while x < rect.maxX { NSRect(x: x, y: y, width: cell, height: cell).intersection(rect).fill(); x += cell * 2 }
        y += cell; row += 1
    }
}

/// 1Shot's camera shape (body and lens), measured from its icon.
func camera() -> NSBezierPath {
    let body = NSBezierPath(roundedRect: NSRect(x: 332, y: up(634), width: 271, height: 233), xRadius: 40, yRadius: 40)
    let lens = NSBezierPath()
    lens.move(to: NSPoint(x: 590, y: up(482)))
    lens.line(to: NSPoint(x: 690, y: up(424)))
    lens.curve(to: NSPoint(x: 707, y: up(436)), controlPoint1: NSPoint(x: 698, y: up(419)), controlPoint2: NSPoint(x: 707, y: up(424)))
    lens.line(to: NSPoint(x: 707, y: up(600)))
    lens.curve(to: NSPoint(x: 690, y: up(612)), controlPoint1: NSPoint(x: 707, y: up(612)), controlPoint2: NSPoint(x: 698, y: up(617)))
    lens.line(to: NSPoint(x: 590, y: up(554)))
    lens.close()
    body.append(lens)
    return body
}

// A redraw of 1Shot's icon, to check the frame matches the original.
render("oneshot_redraw") {
    NSGraphicsContext.saveGraphicsState(); softShadow(); white.setFill(); camera().fill(); NSGraphicsContext.restoreGraphicsState()
}

// Option 1: 1Shot's camera, its left half green screen and its right half cut out to transparency.
render("icon_option1") {
    let cam = camera()
    NSGraphicsContext.saveGraphicsState(); softShadow(); white.setFill(); cam.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); cam.addClip()
    screenGreen.setFill(); NSRect(x: 300, y: 0, width: 220, height: S).fill()
    checker(in: NSRect(x: 520, y: up(640), width: 200, height: 240), cell: 30)
    NSGraphicsContext.restoreGraphicsState()
    cream.setStroke(); cam.lineWidth = 14; cam.stroke()
}

// Option 2: a talking-head silhouette cut out over a checkerboard, inside the ring.
render("icon_option2") {
    let card = NSRect(x: 512 - 175, y: 512 - 175, width: 350, height: 350)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 42, yRadius: 42)
    NSGraphicsContext.saveGraphicsState(); softShadow(); checkLight.setFill(); cardPath.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); cardPath.addClip()
    checker(in: card, cell: 44)
    let person = NSBezierPath(ovalIn: NSRect(x: 512 - 70, y: card.minY + 170, width: 140, height: 150))
    let shoulders = NSBezierPath()
    shoulders.move(to: NSPoint(x: 512 - 165, y: card.minY - 10))
    shoulders.curve(to: NSPoint(x: 512, y: card.minY + 175), controlPoint1: NSPoint(x: 512 - 165, y: card.minY + 120), controlPoint2: NSPoint(x: 512 - 110, y: card.minY + 175))
    shoulders.curve(to: NSPoint(x: 512 + 165, y: card.minY - 10), controlPoint1: NSPoint(x: 512 + 110, y: card.minY + 175), controlPoint2: NSPoint(x: 512 + 165, y: card.minY + 120))
    shoulders.close()
    person.append(shoulders)
    let s2 = NSShadow(); s2.shadowColor = NSColor.black.withAlphaComponent(0.3); s2.shadowBlurRadius = 10; s2.set()
    white.setFill(); person.fill()
    NSGraphicsContext.restoreGraphicsState()
    cream.setStroke(); cardPath.lineWidth = 14; cardPath.stroke()
}
// Option 2 with option 1's background: green screen on the left, cut out to checkerboard on the right.
// soft = a smooth blend across the middle instead of a hard split.
func personOnSplit(_ name: String, soft: Bool, screen: NSColor = screenGreen) {
    render(name) {
        let card = NSRect(x: 512 - 175, y: 512 - 175, width: 350, height: 350)
        let cardPath = NSBezierPath(roundedRect: card, xRadius: 42, yRadius: 42)
        NSGraphicsContext.saveGraphicsState(); softShadow(); checkLight.setFill(); cardPath.fill(); NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState(); cardPath.addClip()
        checker(in: card, cell: 44)
        if soft {
            NSGradient(colorsAndLocations: (screen, 0), (screen, 0.3), (screen.withAlphaComponent(0), 0.75))!
                .draw(in: card, angle: 0)
        } else {
            screen.setFill(); NSRect(x: card.minX, y: card.minY, width: card.width / 2, height: card.height).fill()
        }
        let person = NSBezierPath(ovalIn: NSRect(x: 512 - 70, y: card.minY + 170, width: 140, height: 150))
        let shoulders = NSBezierPath()
        shoulders.move(to: NSPoint(x: 512 - 165, y: card.minY - 10))
        shoulders.curve(to: NSPoint(x: 512, y: card.minY + 175), controlPoint1: NSPoint(x: 512 - 165, y: card.minY + 120), controlPoint2: NSPoint(x: 512 - 110, y: card.minY + 175))
        shoulders.curve(to: NSPoint(x: 512 + 165, y: card.minY - 10), controlPoint1: NSPoint(x: 512 + 110, y: card.minY + 175), controlPoint2: NSPoint(x: 512 + 165, y: card.minY + 120))
        shoulders.close()
        person.append(shoulders)
        let s2 = NSShadow(); s2.shadowColor = NSColor.black.withAlphaComponent(0.3); s2.shadowBlurRadius = 10; s2.set()
        white.setFill(); person.fill()
        NSGraphicsContext.restoreGraphicsState()
        cream.setStroke(); cardPath.lineWidth = 14; cardPath.stroke()
    }
}
personOnSplit("icon_option3_split", soft: false)
personOnSplit("icon_option3_soft", soft: true)
personOnSplit("icon_option3_soft_blue", soft: true, screen: srgb(22, 86, 222))   // blue-screen blue
// Option 4: the tile itself fades from key green, through a checkerboard, to key blue, with a solid
// white person in the middle of 1Shot's ring and no card behind him.
func gradientTile(_ name: String, light: Bool) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tileRect = NSRect(x: 101, y: 101, width: 822, height: 822)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    let lightCell = light ? NSColor(white: 0.90, alpha: 1) : NSColor(white: 0.30, alpha: 1)
    let darkCell = light ? NSColor(white: 0.68, alpha: 1) : NSColor(white: 0.20, alpha: 1)
    lightCell.setFill(); tileRect.fill(); darkCell.setFill()
    let cell: CGFloat = 68
    var y = tileRect.minY, row = 0
    while y < tileRect.maxY {
        var x = tileRect.minX + (row % 2 == 0 ? 0 : cell)
        while x < tileRect.maxX { NSRect(x: x, y: y, width: cell, height: cell).fill(); x += cell * 2 }
        y += cell; row += 1
    }
    let keyBlue = srgb(22, 86, 222)
    NSGradient(colorsAndLocations: (screenGreen, 0), (screenGreen, 0.22), (screenGreen.withAlphaComponent(0), 0.48))!.draw(in: tileRect, angle: 0)
    NSGradient(colorsAndLocations: (keyBlue.withAlphaComponent(0), 0.52), (keyBlue, 0.78), (keyBlue, 1))!.draw(in: tileRect, angle: 0)
    NSGraphicsContext.restoreGraphicsState()
    // 1Shot's ring and ticks, with a soft shadow so they read over any part of the tile.
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.45); sh.shadowBlurRadius = 10; sh.set()
    cream.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 512 - 297, y: 512 - 297, width: 594, height: 594)); ring.lineWidth = 22; ring.stroke()
    cream.setFill()
    for r in [NSRect(x: 501, y: up(306), width: 22, height: 146), NSRect(x: 501, y: up(864), width: 22, height: 146),
              NSRect(x: 157, y: 501, width: 140, height: 22), NSRect(x: 727, y: 501, width: 140, height: 22)] { r.fill() }
    NSGraphicsContext.restoreGraphicsState()
    // Solid white head and shoulders inside the ring, cut off flat like a frame's bottom edge.
    NSGraphicsContext.saveGraphicsState()
    let inner = NSBezierPath(ovalIn: NSRect(x: 512 - 286, y: 512 - 286, width: 572, height: 572)); inner.addClip()
    let base = 512 - 286.0
    let person = NSBezierPath(ovalIn: NSRect(x: 512 - 92, y: 512 + 10, width: 184, height: 196))
    let shoulders = NSBezierPath()
    shoulders.move(to: NSPoint(x: 512 - 230, y: base - 20))
    shoulders.curve(to: NSPoint(x: 512, y: 512 + 5), controlPoint1: NSPoint(x: 512 - 230, y: 512 - 110), controlPoint2: NSPoint(x: 512 - 150, y: 512 + 5))
    shoulders.curve(to: NSPoint(x: 512 + 230, y: base - 20), controlPoint1: NSPoint(x: 512 + 150, y: 512 + 5), controlPoint2: NSPoint(x: 512 + 230, y: 512 - 110))
    shoulders.close()
    person.append(shoulders)
    let ps = NSShadow(); ps.shadowColor = NSColor.black.withAlphaComponent(0.4); ps.shadowBlurRadius = 16; ps.shadowOffset = NSSize(width: 0, height: -4); ps.set()
    NSColor.white.setFill(); person.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
// Option 5: the tile split straight down the middle, key green on the left and key blue on the right,
// with a solid white person (slightly smaller, clear of the top tick) inside 1Shot's ring.
func splitTile(_ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tileRect = NSRect(x: 101, y: 101, width: 822, height: 822)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    screenGreen.setFill(); NSRect(x: tileRect.minX, y: tileRect.minY, width: tileRect.width / 2, height: tileRect.height).fill()
    srgb(22, 86, 222).setFill(); NSRect(x: tileRect.midX, y: tileRect.minY, width: tileRect.width / 2, height: tileRect.height).fill()
    // A gentle top-to-bottom shade, like 1Shot's tile.
    NSGradient(starting: NSColor.white.withAlphaComponent(0.10), ending: NSColor.black.withAlphaComponent(0.18))!.draw(in: tileRect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.4); sh.shadowBlurRadius = 10; sh.set()
    cream.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 512 - 297, y: 512 - 297, width: 594, height: 594)); ring.lineWidth = 22; ring.stroke()
    cream.setFill()
    for r in [NSRect(x: 501, y: up(306), width: 22, height: 146), NSRect(x: 501, y: up(864), width: 22, height: 146),
              NSRect(x: 157, y: 501, width: 140, height: 22), NSRect(x: 727, y: 501, width: 140, height: 22)] { r.fill() }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    // A free-standing head and shoulders, clear of the ring all round (like 1Shot's camera).
    let head = NSBezierPath(ovalIn: NSRect(x: 512 - 78, y: 512 + 2, width: 156, height: 156))
    let body = NSBezierPath()
    body.move(to: NSPoint(x: 392, y: 352))
    body.line(to: NSPoint(x: 632, y: 352))
    body.curve(to: NSPoint(x: 662, y: 382), controlPoint1: NSPoint(x: 649, y: 352), controlPoint2: NSPoint(x: 662, y: 365))
    body.line(to: NSPoint(x: 662, y: 410))
    body.curve(to: NSPoint(x: 512, y: 500), controlPoint1: NSPoint(x: 662, y: 470), controlPoint2: NSPoint(x: 600, y: 500))
    body.curve(to: NSPoint(x: 362, y: 410), controlPoint1: NSPoint(x: 424, y: 500), controlPoint2: NSPoint(x: 362, y: 470))
    body.line(to: NSPoint(x: 362, y: 382))
    body.curve(to: NSPoint(x: 392, y: 352), controlPoint1: NSPoint(x: 362, y: 365), controlPoint2: NSPoint(x: 375, y: 352))
    body.close()
    let person = head; person.append(body)
    let ps = NSShadow(); ps.shadowColor = NSColor.black.withAlphaComponent(0.35); ps.shadowBlurRadius = 16; ps.shadowOffset = NSSize(width: 0, height: -4); ps.set()
    NSColor.white.setFill(); person.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
splitTile("icon_option5_split")
gradientTile("icon_option4_light", light: true)
gradientTile("icon_option4_dark", light: false)
print("done")
