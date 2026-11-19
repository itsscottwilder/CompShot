// UI — CompShot's building blocks, styled to match 1Shot: the black transport bar and step tabs
// under the video, a scrub bar, and the 280-wide dark right panel with 1Shot-style rows.

import AppKit
import MetalKit

enum Theme {
    static let panelWidth: CGFloat = 280
    static let barHeight: CGFloat = 28
    static let bar = NSColor.black.withAlphaComponent(0.85)
    static let welcome = NSColor(calibratedRed: 0.09, green: 0.105, blue: 0.085, alpha: 1)   // 1Shot's project screen
    static let eyebrow = NSColor(calibratedRed: 0.67, green: 0.75, blue: 0.48, alpha: 1)    // 1Shot's "1SHOT" label
    static let playhead = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.16, alpha: 1)          // 1Shot's timeline yellow
}

enum Step: Int, CaseIterable {
    case key, edges, compose, export
    var title: String { ["Key", "Edges", "Compose", "Export"][rawValue] }
    /// Compose and Export show the finished picture; Key and Edges show the key over a test background.
    var showsComposition: Bool { self == .compose || self == .export }
}

/// 1Shot's step tabs: dimmed white text, the selected one bright with a faint highlight.
final class StepTabBar: NSView {
    var onSelect: ((Step) -> Void)?
    private var buttons: [Step: NSButton] = [:]
    private(set) var selected: Step = .key

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bar.cgColor
        let stack = NSStackView(); stack.orientation = .horizontal; stack.distribution = .fillEqually; stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        for step in Step.allCases {
            let b = NSButton(title: step.title, target: self, action: #selector(tapped(_:)))
            b.tag = step.rawValue; b.isBordered = false; b.refusesFirstResponder = true; b.wantsLayer = true
            stack.addArrangedSubview(b); buttons[step] = b
        }
        updateLook()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ s: NSButton) { select(Step(rawValue: s.tag)!); onSelect?(selected) }
    func select(_ s: Step) { selected = s; updateLook() }
    private func updateLook() {
        for (step, b) in buttons {
            let on = step == selected
            b.attributedTitle = NSAttributedString(string: step.title, attributes: [
                .foregroundColor: on ? NSColor.white : NSColor.white.withAlphaComponent(0.55),
                .font: NSFont.systemFont(ofSize: 11, weight: on ? .semibold : .medium)])
            b.layer?.backgroundColor = on ? NSColor.white.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
            b.layer?.cornerRadius = 4
        }
    }
}

/// 1Shot's transport bar, plus the Original / Matte / Key view switch on the right.
final class TransportBar: NSView {
    var onStart: (() -> Void)?, onBack: (() -> Void)?, onPlay: (() -> Void)?, onForward: (() -> Void)?, onEnd: (() -> Void)?
    var onLoop: (() -> Void)?, onView: ((Int) -> Void)?
    private let play: NSButton, loop: NSButton
    let viewSwitch = NSSegmentedControl(labels: ["Original", "Matte", "Key"], trackingMode: .selectOne, target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    private var playing = false

    override init(frame: NSRect) {
        play = Self.button("play.fill", "Play (Space)", size: 15)
        loop = Self.button("repeat", "Loop playback")
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bar.cgColor
        let start = Self.button("backward.end.fill", "Go to start"), back = Self.button("backward.frame.fill", "Back one frame (←)")
        let fwd = Self.button("forward.frame.fill", "Forward one frame (→)"), end = Self.button("forward.end.fill", "Go to end")
        for (b, sel) in [(start, #selector(s1)), (back, #selector(s2)), (play, #selector(s3)), (fwd, #selector(s4)), (end, #selector(s5)), (loop, #selector(s6))] {
            b.target = self; b.action = sel
        }
        let controls = NSStackView(views: [start, back, play, fwd, end]); controls.spacing = 14
        viewSwitch.controlSize = .small; viewSwitch.selectedSegment = 2; viewSwitch.target = self; viewSwitch.action = #selector(viewChanged)
        viewSwitch.toolTip = "Original: the footage · Matte: white is kept, black is removed · Key: the result"
        viewSwitch.refusesFirstResponder = true
        status.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium); status.textColor = NSColor.white.withAlphaComponent(0.55)
        for v in [controls, loop, viewSwitch, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            controls.centerXAnchor.constraint(equalTo: centerXAnchor), controls.centerYAnchor.constraint(equalTo: centerYAnchor),
            loop.leadingAnchor.constraint(equalTo: controls.trailingAnchor, constant: 26), loop.centerYAnchor.constraint(equalTo: centerYAnchor),
            viewSwitch.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), viewSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -12),
        ])
        setLoop(true)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, _ tip: String, size: CGFloat = 12) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium)) ?? NSImage()
        let b = NSButton(image: img, target: nil, action: nil)
        b.isBordered = false; b.imagePosition = .imageOnly; b.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        b.toolTip = tip; b.setAccessibilityLabel(tip); b.refusesFirstResponder = true
        return b
    }
    func setPlaying(_ on: Bool) {
        guard on != playing else { return }
        playing = on
        let tip = on ? "Pause (Space)" : "Play (Space)"
        play.image = NSImage(systemSymbolName: on ? "pause.fill" : "play.fill", accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        play.toolTip = tip; play.setAccessibilityLabel(tip)
    }
    func setLoop(_ on: Bool) {
        loop.contentTintColor = on ? .controlAccentColor : NSColor.white.withAlphaComponent(0.4)
        loop.toolTip = on ? "Loop playback is on" : "Loop playback is off"
    }
    @objc private func s1() { onStart?() }
    @objc private func s2() { onBack?() }
    @objc private func s3() { onPlay?() }
    @objc private func s4() { onForward?() }
    @objc private func s5() { onEnd?() }
    @objc private func s6() { onLoop?() }
    @objc private func viewChanged() { onView?(viewSwitch.selectedSegment) }
}

/// A slim timeline: drag anywhere to scrub. Shows the time on the left and the length on the right.
final class ScrubBar: NSView {
    var duration = 0.0 { didSet { needsDisplay = true } }
    var time = 0.0 { didSet { if abs(time - oldValue) > 0.005 { needsDisplay = true } } }
    var onSeek: ((Double) -> Void)?
    static let height: CGFloat = 34

    override var isFlipped: Bool { true }
    private var track: NSRect { NSRect(x: 84, y: 13, width: max(10, bounds.width - 168), height: 8) }

    override func draw(_ dirty: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let t = track
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: t, xRadius: 4, yRadius: 4).fill()
        let f = duration > 0 ? CGFloat(min(1, max(0, time / duration))) : 0
        NSColor.white.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: t.minX, y: t.minY, width: t.width * f, height: t.height), xRadius: 4, yRadius: 4).fill()
        Theme.playhead.setFill()
        NSBezierPath(roundedRect: NSRect(x: t.minX + t.width * f - 1.5, y: t.minY - 6, width: 3, height: t.height + 12), xRadius: 1.5, yRadius: 1.5).fill()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                .foregroundColor: NSColor.white.withAlphaComponent(0.6)]
        (Self.clock(time) as NSString).draw(at: NSPoint(x: 12, y: 10), withAttributes: a)
        let d = Self.clock(duration) as NSString
        d.draw(at: NSPoint(x: bounds.width - 12 - d.size(withAttributes: a).width, y: 10), withAttributes: a)
    }
    static func clock(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "00:00:00" }
        let i = Int(s); return String(format: "%02d:%02d:%02d", i / 3600, (i / 60) % 60, i % 60)
    }
    override func mouseDown(with e: NSEvent) { seek(e) }
    override func mouseDragged(with e: NSEvent) { seek(e) }
    private func seek(_ e: NSEvent) {
        guard duration > 0 else { return }
        let x = convert(e.locationInWindow, from: nil).x, t = track
        time = Double(min(1, max(0, (x - t.minX) / t.width))) * duration
        onSeek?(time)
    }
}

/// 1Shot's slider: double-click returns it to its default.
final class ResetSlider: NSSlider {
    var resetValue: Double = 0
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { doubleValue = resetValue; sendAction(action, to: target); return }
        super.mouseDown(with: event)
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A right-panel page: dark HUD material, scrolling, 14 pt margins (1Shot's panel layout).
func panelPage(_ views: [NSView], spacingAfter: [NSView: CGFloat] = [:], fullWidth: [NSView] = []) -> NSVisualEffectView {
    let page = NSVisualEffectView()
    page.material = .hudWindow; page.blendingMode = .withinWindow; page.state = .active
    page.appearance = NSAppearance(named: .darkAqua)
    let stack = NSStackView(views: views)
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
    for (v, s) in spacingAfter { stack.setCustomSpacing(s, after: v) }
    stack.translatesAutoresizingMaskIntoConstraints = false
    let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.translatesAutoresizingMaskIntoConstraints = false
    let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false; doc.addSubview(stack)
    scroll.documentView = doc; page.addSubview(scroll)
    NSLayoutConstraint.activate([
        scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        scroll.topAnchor.constraint(equalTo: page.topAnchor), scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -14),
        stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
    ])
    for v in fullWidth { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return page
}

func titleLabel(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = .boldSystemFont(ofSize: 15); return l }
func sectionLabel(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 12, weight: .semibold); return l }
func noteLabel(_ s: String) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s); l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor; return l
}
func smallButton(_ title: String, _ target: AnyObject, _ action: Selector, tip: String) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded; b.controlSize = .small; b.refusesFirstResponder = true; b.toolTip = tip
    return b
}
/// A section title with buttons on the right (like 1Shot's "Color · Bypass · Reset").
func headerRow(_ title: NSTextField, _ buttons: [NSView]) -> NSStackView {
    let r = NSStackView(views: [title, NSView()] + buttons); r.orientation = .horizontal; return r
}

/// The card at the top of the Key page, filled with the screen color (like 1Shot's group header).
final class ScreenCard: NSView {
    private let name = NSTextField(labelWithString: "Screen color")
    private let detail = NSTextField(labelWithString: "Open a video to detect it")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 7
        name.font = .systemFont(ofSize: 14, weight: .heavy)
        detail.font = .systemFont(ofSize: 10.5, weight: .medium)
        let s = NSStackView(views: [name, detail]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 1
        s.translatesAutoresizingMaskIntoConstraints = false; addSubview(s)
        NSLayoutConstraint.activate([s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), s.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     heightAnchor.constraint(equalToConstant: 46)])
        set(color: NSColor(srgbRed: 0.3, green: 0.75, blue: 0.3, alpha: 1), detail: "Open a video to detect it")
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(color: NSColor, detail text: String) {
        layer?.backgroundColor = color.cgColor
        let c = color.usingColorSpace(.sRGB) ?? color
        let light = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.45
        name.textColor = light ? .black : .white
        detail.textColor = (light ? NSColor.black : .white).withAlphaComponent(0.7)
        detail.stringValue = text
    }
}

/// The video area: draws the key with Metal, takes clicks for Pick Green and dropped video files.
final class KeyView: MTKView {
    var onClick: ((CGPoint) -> Void)?
    var onDrop: ((URL) -> Bool)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { onClick?(convert(e.locationInWindow, from: nil)) }
    func enableDrops() { registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { fileURL(s) != nil ? .copy : [] }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { fileURL(s).map { onDrop?($0) ?? false } ?? false }
    private func fileURL(_ s: NSDraggingInfo) -> URL? {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
    }
}

/// 1Shot's graphic handles, for the keyed person in the Compose step: drag a corner to resize
/// (the opposite corner stays put), drag the middle or anywhere inside to move. Shift = fine.
final class PlacementHandles: NSView {
    enum Grab: Equatable { case move, corner(Int) }   // 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right
    var box: NSRect? { didSet { if box != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    var onGrab: ((Grab, NSPoint) -> Void)?
    var onDrag: ((NSPoint, Bool) -> Void)?
    var onRelease: (() -> Void)?
    private let corner: CGFloat = 11, centre: CGFloat = 26
    private var dragging = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func corners(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY)]
    }
    private func grab(at p: NSPoint) -> Grab? {
        guard let r = box else { return nil }
        for (i, c) in corners(r).enumerated() where abs(p.x - c.x) <= corner && abs(p.y - c.y) <= corner { return .corner(i) }
        return r.contains(p) || hypot(p.x - r.midX, p.y - r.midY) <= centre / 2 + 4 ? .move : nil
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return grab(at: convert(point, from: superview)) != nil ? self : nil
    }
    override func resetCursorRects() {
        guard let r = box else { return }
        addCursorRect(r, cursor: .openHand)
        for c in corners(r) { addCursorRect(NSRect(x: c.x - corner, y: c.y - corner, width: corner * 2, height: corner * 2), cursor: .crosshair) }
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let g = grab(at: p) else { return }
        dragging = true
        if g == .move { NSCursor.closedHand.set() }
        onGrab?(g, p)
    }
    override func mouseDragged(with e: NSEvent) {
        guard dragging else { return }
        onDrag?(convert(e.locationInWindow, from: nil), e.modifierFlags.contains(.shift))
    }
    override func mouseUp(with e: NSEvent) {
        guard dragging else { return }
        dragging = false; onRelease?(); window?.invalidateCursorRects(for: self)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let r = box else { return }
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.6); shadow.shadowBlurRadius = 3; shadow.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        let accent = NSColor(srgbRed: 0.24, green: 0.80, blue: 0.78, alpha: 1)
        let outline = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); outline.lineWidth = 1.5; accent.setStroke(); outline.stroke()
        for c in corners(r) {
            let h = NSBezierPath(rect: NSRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11))
            NSColor.white.setFill(); h.fill(); h.lineWidth = 1.5; accent.setStroke(); h.stroke()
        }
        let disc = NSBezierPath(ovalIn: NSRect(x: r.midX - centre / 2, y: r.midY - centre / 2, width: centre, height: centre))
        NSColor.black.withAlphaComponent(0.55).setFill(); disc.fill(); disc.lineWidth = 1.5; NSColor.white.setStroke(); disc.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let arrows = NSBezierPath(), cx = r.midX, cy = r.midY, a: CGFloat = 7.5, k: CGFloat = 3
        for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] as [(CGFloat, CGFloat)] {
            let tip = NSPoint(x: cx + dx * a, y: cy + dy * a)
            arrows.move(to: NSPoint(x: cx, y: cy)); arrows.line(to: tip)
            arrows.move(to: NSPoint(x: tip.x - dx * k + dy * k, y: tip.y - dy * k + dx * k)); arrows.line(to: tip)
            arrows.line(to: NSPoint(x: tip.x - dx * k - dy * k, y: tip.y - dy * k - dx * k))
        }
        arrows.lineWidth = 1.5; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round; NSColor.white.setStroke(); arrows.stroke()
    }
}
