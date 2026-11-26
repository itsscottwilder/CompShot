// CurvesView — a Photoshop/Lightroom-style curves editor that sits under Levels.
// Click the graph to add a point, drag to move it, double-click a point (or drag it off the graph) to remove it,
// double-click empty space to reset the curve. Shows the histogram behind the curve.

import AppKit

final class CurvesView: NSView {
    static let height: CGFloat = 236

    /// (curves, finished dragging)
    var onChange: ((Curves, Bool) -> Void)?

    private(set) var curves = Curves()
    var channel: Curves.Channel = .master { didSet { needsDisplay = true } }
    private var histogram: [[Float]] = []      // red, green, blue — 256 each, 0…1 for display
    private var dragIndex: Int?
    private var dragRemoved = false             // point pulled off the graph (put back if it returns)
    private var dragPoint = SIMD2<Double>(0, 0)
    private var readout: String?
    private let maxPoints = 14
    private let hitRadius: CGFloat = 7

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setCurves(_ c: Curves) { curves = c; needsDisplay = true }

    /// 768 values (red, green, blue × 256) for the picture as it looks now.
    func setHistogram(_ bins: [Float]) {
        guard bins.count == 768 else { return }
        let chans = (0..<3).map { Array(bins[($0 * 256)..<($0 * 256 + 256)]) }
        let peak = max(chans.map { $0.max() ?? 0 }.max() ?? 1, 0.0001)
        histogram = chans.map { $0.map { sqrt($0 / peak) } }
        needsDisplay = true
    }

    // MARK: Geometry

    private var graph: NSRect {
        let side = min(bounds.width - 4, bounds.height - 20)
        return NSRect(x: (bounds.width - side) / 2, y: 18, width: side, height: side)
    }
    private func point(_ v: SIMD2<Double>) -> NSPoint {
        NSPoint(x: graph.minX + CGFloat(v.x) * graph.width, y: graph.minY + CGFloat(v.y) * graph.height)
    }
    private func value(_ p: NSPoint) -> SIMD2<Double> {
        SIMD2(min(1, max(0, Double((p.x - graph.minX) / graph.width))), min(1, max(0, Double((p.y - graph.minY) / graph.height))))
    }

    private static func color(_ c: Curves.Channel) -> NSColor {
        switch c {
        case .master: return NSColor(white: 0.92, alpha: 1)
        case .red: return NSColor(red: 1, green: 0.32, blue: 0.3, alpha: 1)
        case .green: return NSColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1)
        case .blue: return NSColor(red: 0.35, green: 0.55, blue: 1, alpha: 1)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let g = graph
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: g, xRadius: 3, yRadius: 3).fill()

        // Histogram: the selected channel, or all three blended for RGB.
        if histogram.count == 3 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: g).addClip()
            NSGraphicsContext.current?.compositingOperation = .plusLighter
            let shown: [Int] = channel == .master ? [0, 1, 2] : [channel.rawValue - 1]
            for c in shown {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: g.minX, y: g.minY))
                for (i, v) in histogram[c].enumerated() {
                    path.line(to: NSPoint(x: g.minX + CGFloat(i) / 255 * g.width, y: g.minY + CGFloat(v) * g.height * 0.9))
                }
                path.line(to: NSPoint(x: g.maxX, y: g.minY)); path.close()
                let base = channel == .master ? Self.color(Curves.Channel(rawValue: c + 1)!) : Self.color(channel)
                base.withAlphaComponent(channel == .master ? 0.22 : 0.3).setFill()
                path.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // Grid in quarters and the untouched diagonal.
        NSColor(white: 1, alpha: 0.1).setStroke()
        let grid = NSBezierPath(); grid.lineWidth = 1
        for q in 1...3 {
            let f = CGFloat(q) / 4
            grid.move(to: NSPoint(x: g.minX + f * g.width, y: g.minY)); grid.line(to: NSPoint(x: g.minX + f * g.width, y: g.maxY))
            grid.move(to: NSPoint(x: g.minX, y: g.minY + f * g.height)); grid.line(to: NSPoint(x: g.maxX, y: g.minY + f * g.height))
        }
        grid.stroke()
        let diag = NSBezierPath(); diag.move(to: NSPoint(x: g.minX, y: g.minY)); diag.line(to: NSPoint(x: g.maxX, y: g.maxY))
        diag.lineWidth = 1; diag.setLineDash([3, 3], count: 2, phase: 0); diag.stroke()

        // Other channels' curves, faint, so you can see everything you've changed.
        for c in Curves.Channel.allCases where c != channel && !curves[c].isIdentity {
            strokeCurve(curves[c], Self.color(c).withAlphaComponent(0.35), width: 1)
        }
        let active = shownCurve
        strokeCurve(active, Self.color(channel), width: 1.6)
        for (i, p) in active.points.enumerated() {
            let c = point(p), r: CGFloat = i == dragIndex ? 4.5 : 3.5
            let dot = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            (i == dragIndex ? Self.color(channel) : NSColor(white: 0.1, alpha: 1)).setFill(); dot.fill()
            Self.color(channel).setStroke(); dot.lineWidth = 1.2; dot.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                    .foregroundColor: NSColor(white: 0.8, alpha: 1)]
        let text = NSAttributedString(string: readout ?? "Click to add a point · drag it off to remove", attributes: readout == nil
            ? [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor] : attrs)
        text.draw(at: NSPoint(x: g.midX - text.size().width / 2, y: 2))
    }

    /// The curve being edited, without a point that's being pulled off.
    private var shownCurve: ToneCurve {
        var c = curves[channel]
        if dragRemoved, let i = dragIndex, c.points.indices.contains(i) { c.points.remove(at: i) }
        return c
    }

    private func strokeCurve(_ c: ToneCurve, _ color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        let steps = Int(graph.width)
        for s in 0...steps {
            let x = Double(s) / Double(steps)
            let p = point(SIMD2(x, c.value(at: x)))
            s == 0 ? path.move(to: p) : path.line(to: p)
        }
        color.setStroke(); path.lineWidth = width; path.stroke()
    }

    // MARK: Mouse

    private func hitPoint(_ p: NSPoint) -> Int? {
        let pts = curves[channel].points
        let near = pts.indices.map { (i: $0, d: hypot(point(pts[$0]).x - p.x, point(pts[$0]).y - p.y)) }.min { $0.d < $1.d }
        return near.flatMap { $0.d <= hitRadius ? $0.i : nil }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard graph.insetBy(dx: -hitRadius, dy: -hitRadius).contains(p) else { return }
        var c = curves[channel]
        if event.clickCount >= 2 {
            if let i = hitPoint(p), i != 0, i != c.points.count - 1 { c.points.remove(at: i) }   // remove a middle point
            else if hitPoint(p) == nil { c.points = ToneCurve.identity }                         // reset this curve
            else { return }
            curves[channel] = c; dragIndex = nil; readout = nil; needsDisplay = true
            onChange?(curves, true); return
        }
        if let i = hitPoint(p) {
            dragIndex = i
        } else {
            guard c.points.count < maxPoints else { return }
            let v = value(p)
            // Only between the two ends, and not on top of another point.
            guard v.x > c.points[0].x + 0.01, v.x < c.points[c.points.count - 1].x - 0.01,
                  !c.points.contains(where: { abs($0.x - v.x) < 0.01 }) else { return }
            let i = c.points.firstIndex { $0.x > v.x } ?? c.points.count
            c.points.insert(v, at: i)
            curves[channel] = c; dragIndex = i
            onChange?(curves, false)
        }
        dragRemoved = false
        dragPoint = curves[channel].points[dragIndex!]
        readout = Self.readout(dragPoint); needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let i = dragIndex else { return }
        let p = convert(event.locationInWindow, from: nil)
        var c = curves[channel]
        let isEnd = i == 0 || i == c.points.count - 1
        // Pull a middle point well off the graph to remove it (it comes back if you drag it back).
        let off = !isEnd && !graph.insetBy(dx: -24, dy: -24).contains(p)
        if off != dragRemoved { dragRemoved = off; readout = off ? "Let go to remove the point" : nil }
        if !off {
            var v = value(p)
            let lo = i > 0 ? c.points[i - 1].x + 0.01 : 0
            let hi = i < c.points.count - 1 ? c.points[i + 1].x - 0.01 : 1
            v.x = min(hi, max(lo, v.x))
            c.points[i] = v; curves[channel] = c
            readout = Self.readout(v)
        }
        needsDisplay = true
        onChange?(dragRemoved ? curvesWithoutDragged : curves, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragIndex != nil else { return }
        if dragRemoved { curves = curvesWithoutDragged }
        dragIndex = nil; dragRemoved = false; readout = nil
        needsDisplay = true
        onChange?(curves, true)
    }

    private var curvesWithoutDragged: Curves { var all = curves; all[channel] = shownCurve; return all }

    private static func readout(_ v: SIMD2<Double>) -> String {
        "In \(Int((v.x * 255).rounded()))  →  Out \(Int((v.y * 255).rounded()))"
    }
}
