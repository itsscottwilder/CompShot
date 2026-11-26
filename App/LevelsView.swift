// LevelsView (from 1Shot) — histogram with a black-point handle (bottom left) and a white-point
// handle (bottom right) that you drag inward, like Photoshop/Lightroom Levels.

import AppKit

final class LevelsView: NSView {
    static let height: CGFloat = 104

    /// (black, white, finished) — both 0…1
    var onChange: ((Double, Double, Bool) -> Void)?

    private(set) var blackPoint: Double = 0
    private(set) var whitePoint: Double = 1
    private var channels: [[Float]] = []     // red, green, blue — 256 values each, 0…1 for display
    private enum Drag { case none, black, white }
    private var drag: Drag = .none
    private let handleSize: CGFloat = 10
    private let minGap: Double = 0.05

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Data in

    func setPoints(black: Double, white: Double) {
        blackPoint = black
        whitePoint = white
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// `outputBins` describe the picture as it looks NOW (after levels). We map them back
    /// through the current levels so the graph shows the tones the handles act on.
    /// `outputBins`: 768 values (red, green, blue × 256) for the picture as it looks NOW.
    func setHistogram(_ outputBins: [Float]) {
        guard outputBins.count == 768 else { return }
        let span = whitePoint - blackPoint
        var mapped: [[Float]] = []
        for c in 0..<3 {
            var input = [Float](repeating: 0, count: 256)
            for i in 0..<256 {
                let v = Double(i) / 255 * span + blackPoint
                input[min(255, max(0, Int((v * 255).rounded())))] += outputBins[c * 256 + i]
            }
            mapped.append(input)
        }
        // One shared scale so the channels compare honestly.
        let peak = max(mapped.map { $0.max() ?? 0 }.max() ?? 1, 0.0001)
        channels = mapped.map { $0.map { sqrt($0 / peak) } }   // square root keeps small bumps visible
        needsDisplay = true
    }

    // MARK: Geometry

    private var graphRect: NSRect {
        NSRect(x: handleSize, y: 2, width: bounds.width - handleSize * 2, height: bounds.height - 34)
    }

    private func x(for value: Double) -> CGFloat { graphRect.minX + CGFloat(value) * graphRect.width }

    private func value(atX x: CGFloat) -> Double {
        min(1, max(0, Double((x - graphRect.minX) / graphRect.width)))
    }

    private func handleRect(_ value: Double) -> NSRect {
        NSRect(x: x(for: value) - handleSize, y: graphRect.maxY + 2, width: handleSize * 2, height: handleSize + 2)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let graph = graphRect
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: graph, xRadius: 3, yRadius: 3).fill()

        if channels.count == 3 {
            // Additive blend: overlaps mix (red+green = yellow, all three = white).
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: graph, xRadius: 3, yRadius: 3).addClip()
            NSGraphicsContext.current?.compositingOperation = .plusLighter
            let colors: [NSColor] = [NSColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 0.75),
                                     NSColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 0.75),
                                     NSColor(red: 0.25, green: 0.45, blue: 1.0, alpha: 0.75)]
            for (c, values) in channels.enumerated() {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: graph.minX, y: graph.maxY))
                for (i, v) in values.enumerated() {
                    let px = graph.minX + CGFloat(i) / 255 * graph.width
                    path.line(to: NSPoint(x: px, y: graph.maxY - CGFloat(v) * (graph.height - 4)))
                }
                path.line(to: NSPoint(x: graph.maxX, y: graph.maxY))
                path.close()
                colors[c].setFill()
                path.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let hint = NSAttributedString(string: "Play or move a slider to see the histogram", attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor])
            hint.draw(at: NSPoint(x: graph.midX - hint.size().width / 2, y: graph.midY - 6))
        }

        // Shade what gets clipped to pure black / pure white.
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSRect(x: graph.minX, y: graph.minY, width: x(for: blackPoint) - graph.minX, height: graph.height).fill()
        NSRect(x: x(for: whitePoint), y: graph.minY, width: graph.maxX - x(for: whitePoint), height: graph.height).fill()

        // Guide lines
        NSColor(white: 1, alpha: 0.35).setFill()
        NSRect(x: x(for: blackPoint) - 0.5, y: graph.minY, width: 1, height: graph.height).fill()
        NSRect(x: x(for: whitePoint) - 0.5, y: graph.minY, width: 1, height: graph.height).fill()

        drawTriangle(at: blackPoint, fill: .black)
        drawTriangle(at: whitePoint, fill: .white)

        // Values in the familiar 0–255 scale
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 0.8, alpha: 1)
        ]
        let left = NSAttributedString(string: "Black \(Int((blackPoint * 255).rounded()))", attributes: attrs)
        let right = NSAttributedString(string: "White \(Int((whitePoint * 255).rounded()))", attributes: attrs)
        let textY = graph.maxY + handleSize + 6
        left.draw(at: NSPoint(x: graph.minX - handleSize / 2, y: textY))
        right.draw(at: NSPoint(x: graph.maxX + handleSize / 2 - right.size().width, y: textY))
    }

    private func drawTriangle(at value: Double, fill: NSColor) {
        let cx = x(for: value)
        let top = graphRect.maxY + 2
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: cx, y: top))
        tri.line(to: NSPoint(x: cx - handleSize * 0.8, y: top + handleSize))
        tri.line(to: NSPoint(x: cx + handleSize * 0.8, y: top + handleSize))
        tri.close()
        fill.setFill()
        tri.fill()
        NSColor(white: 0.6, alpha: 1).setStroke()
        tri.lineWidth = 1
        tri.stroke()
    }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(handleRect(blackPoint), cursor: .resizeLeftRight)
        addCursorRect(handleRect(whitePoint), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let nearBlack = abs(p.x - x(for: blackPoint))
        let nearWhite = abs(p.x - x(for: whitePoint))
        // Grab the closer handle (anywhere along the bottom strip or the graph).
        guard p.y >= graphRect.minY else { return }
        if event.clickCount >= 2 {
            // Double-click: put the nearer handle back to its corner.
            if nearBlack <= nearWhite { blackPoint = 0 } else { whitePoint = 1 }
            drag = .none
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            onChange?(blackPoint, whitePoint, true)
            return
        }
        drag = nearBlack <= nearWhite ? .black : .white
        mouseDragged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let v = value(atX: convert(event.locationInWindow, from: nil).x)
        switch drag {
        case .black: blackPoint = min(v, whitePoint - minGap)
        case .white: whitePoint = max(v, blackPoint + minGap)
        case .none: return
        }
        needsDisplay = true
        onChange?(blackPoint, whitePoint, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != .none else { return }
        drag = .none
        onChange?(blackPoint, whitePoint, true)
        window?.invalidateCursorRects(for: self)
    }
}
