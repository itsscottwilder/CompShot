import AppKit
import AVFoundation
import MetalKit

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--benchmark" {
    Task { await runBenchmark(Array(args.dropFirst())); exit(0) }
    dispatchMain()
}

final class Action: NSObject {
    let run: (Any?) -> Void
    init(_ run: @escaping (Any?) -> Void) { self.run = run }
    @objc func fire(_ s: Any?) { run(s) }
}

final class KeyView: MTKView {
    var onClick: ((CGPoint) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { onClick?(convert(e.locationInWindow, from: nil)) }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class AppController: NSObject, NSApplicationDelegate, MTKViewDelegate {
    let r: Renderer
    var window: NSWindow!, view: KeyView!
    var actions: [Action] = []
    var settings = KeySettings() { didSet { dirty = true } }
    var mode = ViewMode.key { didSet { dirty = true } }
    var backdrop = Backdrop.blue { didSet { dirty = true } }
    var player = AVPlayer(), output: AVPlayerItemVideoOutput?
    var frame: CIImage?, orientation = CGImagePropertyOrientation.up
    var dirty = false, picking = false, needsDetect = false
    var fit = CGAffineTransform.identity
    var fps = 30.0, duration = 0.0, videoFrames = 0, gpuTimes: [Double] = []
    var playButton: NSButton!, timeSlider: NSSlider!, swatch: NSView!, pickButton: NSButton!
    var videoLabel: NSTextField!, speedLabel: NSTextField!, fullLabel: NSTextField!
    var timeObserver: Any?, sliders: [(NSSlider, NSTextField, ReferenceWritableKeyPath<AppController, Float>, Float)] = []

    init(renderer: Renderer) { r = renderer }

    func action(_ f: @escaping (Any?) -> Void) -> Action { let a = Action(f); actions.append(a); return a }
    func label(_ s: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size); return l
    }
    func button(_ t: String, _ f: @escaping (Any?) -> Void) -> NSButton {
        let a = action(f); return NSButton(title: t, target: a, action: #selector(Action.fire(_:)))
    }
    func segments(_ names: [String], selected: Int, _ f: @escaping (Int) -> Void) -> NSSegmentedControl {
        let a = action { f(($0 as! NSSegmentedControl).selectedSegment) }
        let s = NSSegmentedControl(labels: names, trackingMode: .selectOne, target: a, action: #selector(Action.fire(_:)))
        s.selectedSegment = selected; return s
    }
    func slider(_ name: String, _ key: ReferenceWritableKeyPath<AppController, Float>, _ lo: Float, _ hi: Float) -> NSView {
        let value = label(""); value.alignment = .right; value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let def = self[keyPath: key]
        let a = action { [unowned self] s in
            let v = Float((s as! NSSlider).doubleValue); self[keyPath: key] = v; value.stringValue = String(format: "%.2f", v)
        }
        let s = NSSlider(value: Double(def), minValue: Double(lo), maxValue: Double(hi), target: a, action: #selector(Action.fire(_:)))
        s.isContinuous = true; value.stringValue = String(format: "%.2f", def); sliders.append((s, value, key, def))
        let top = NSStackView(views: [label(name), NSView(), value]); top.distribution = .fill
        let col = NSStackView(views: [top, s]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 2
        top.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        s.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    var strength: Float { get { settings.strength } set { settings.strength = newValue } }
    var softness: Float { get { settings.softness } set { settings.softness = newValue } }
    var spill: Float { get { settings.spill } set { settings.spill = newValue } }
    var spillFirmness: Float { get { settings.spillFirmness } set { settings.spillFirmness = newValue } }
    var shrinkEdges: Float { get { settings.shrink } set { settings.shrink = newValue } }
    var smoothEdges: Float { get { settings.smooth } set { settings.smooth = newValue } }
    var correction: Float { get { settings.correction } set { settings.correction = newValue } }
    var edgeRepair: Float { get { settings.edgeRepair } set { settings.edgeRepair = newValue } }
    var maskLeft: Float { get { settings.maskLeft } set { settings.maskLeft = newValue } }
    var maskRight: Float { get { settings.maskRight } set { settings.maskRight = newValue } }
    var maskTop: Float { get { settings.maskTop } set { settings.maskTop = newValue } }
    var maskBottom: Float { get { settings.maskBottom } set { settings.maskBottom = newValue } }

    func applicationDidFinishLaunching(_ n: Notification) {
        let main = NSMenu(); let item = NSMenuItem(); main.addItem(item); let m = NSMenu()
        m.addItem(withTitle: "Quit GreenKeyLab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = m; NSApp.mainMenu = main

        view = KeyView(frame: .zero, device: r.device)
        view.colorPixelFormat = .bgra8Unorm; view.framebufferOnly = false; view.delegate = self
        view.preferredFramesPerSecond = 60; view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.onClick = { [unowned self] p in self.clicked(p) }

        playButton = button("Play") { [unowned self] _ in self.togglePlay() }; playButton.keyEquivalent = " "
        timeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: action { [unowned self] s in
            self.player.seek(to: CMTime(seconds: (s as! NSSlider).doubleValue, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }, action: #selector(Action.fire(_:)))
        let transport = NSStackView(views: [playButton, timeSlider])
        let left = NSStackView(views: [view, transport]); left.orientation = .vertical; left.spacing = 8; left.alignment = .leading
        left.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        view.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        transport.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -16).isActive = true
        view.setContentHuggingPriority(.defaultLow, for: .vertical)

        swatch = NSView(); swatch.wantsLayer = true; swatch.layer?.cornerRadius = 4
        swatch.widthAnchor.constraint(equalToConstant: 28).isActive = true; swatch.heightAnchor.constraint(equalToConstant: 22).isActive = true
        pickButton = button("Pick Green") { [unowned self] _ in self.setPicking(!self.picking) }
        let pickRow = NSStackView(views: [pickButton, swatch])
        videoLabel = label("No video open"); speedLabel = label("Speed: waiting for video"); fullLabel = label("")
        let items: [NSView] = [
            button("Open Video…") { [unowned self] _ in self.openPanel() },
            label("View", bold: true),
            segments(["Original", "Matte", "Key"], selected: 2) { [unowned self] in self.mode = ViewMode(rawValue: $0)! },
            segments(["Blue", "Checker"], selected: 0) { [unowned self] in self.backdrop = Backdrop(rawValue: $0)! },
            label("Key", bold: true), pickRow,
            slider("Key strength", \.strength, 0.5, 2.5), slider("Edge softness", \.softness, 0.01, 1),
            slider("Shrink edges", \.shrinkEdges, 0, 3), slider("Smooth edges", \.smoothEdges, 0, 3), slider("Spill removal", \.spill, 0, 1), slider("Spill firmness", \.spillFirmness, 0, 1),
            slider("Screen correction", \.correction, 0, 1), slider("Edge color repair", \.edgeRepair, 0, 1),
            label("Mask (cut from each side)", bold: true),
            slider("Left", \.maskLeft, 0, 0.5), slider("Right", \.maskRight, 0, 0.5), slider("Top", \.maskTop, 0, 0.5), slider("Bottom", \.maskBottom, 0, 0.5),
            button("Reset Controls") { [unowned self] _ in self.resetControls() },
            label("Speed", bold: true), videoLabel, speedLabel,
            button("Test Full-Size Speed") { [unowned self] _ in self.fullSizeTest() }, fullLabel,
        ]
        let side = NSStackView(views: items); side.orientation = .vertical; side.alignment = .leading; side.spacing = 9
        side.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        side.widthAnchor.constraint(equalToConstant: 280).isActive = true
        for v in items where v is NSStackView || v is NSTextField {
            v.widthAnchor.constraint(equalTo: side.widthAnchor, constant: -28).isActive = true
        }
        let doc = FlippedView(); side.translatesAutoresizingMaskIntoConstraints = false; doc.addSubview(side)
        let scroll = NSScrollView(); scroll.documentView = doc; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        doc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: doc.topAnchor), side.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            side.trailingAnchor.constraint(equalTo: doc.trailingAnchor), side.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), scroll.widthAnchor.constraint(equalToConstant: 296),
        ])
        let root = NSStackView(views: [left, scroll]); root.spacing = 0; root.alignment = .top; root.distribution = .fill
        left.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        scroll.heightAnchor.constraint(equalTo: root.heightAnchor).isActive = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "GreenKeyLab"; window.contentView = root; window.minSize = NSSize(width: 900, height: 560); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); updateSwatch()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in self.updateStats() }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [unowned self] _ in
            self.player.seek(to: .zero); self.player.play()
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [unowned self] t in
            if NSEvent.pressedMouseButtons == 0 { self.timeSlider.doubleValue = t.seconds }
            self.playButton.title = self.player.rate == 0 ? "Play" : "Pause"
        }
        if let p = args.first { open(URL(fileURLWithPath: p)) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func openPanel() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.movie]
        if p.runModal() == .OK, let u = p.url { open(u) }
    }
    func open(_ url: URL) {
        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: url)
                guard let t = try await asset.loadTracks(withMediaType: .video).first else { videoLabel.stringValue = "No video track found"; return }
                let (size, xf, rate) = try await t.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let d = try await asset.load(.duration).seconds
                let angle = Int((atan2(xf.b, xf.a) * 180 / .pi).rounded())
                orientation = angle == 90 ? .right : angle == -90 ? .left : abs(angle) == 180 ? .down : .up
                let side = abs(angle) == 90
                fps = Double(rate > 0 ? rate : 30); duration = d; timeSlider.maxValue = max(d, 0.01)
                videoLabel.stringValue = String(format: "%@\n%d × %d, %.3g fps", url.lastPathComponent, Int(side ? size.height : size.width), Int(side ? size.width : size.height), fps)
                let item = AVPlayerItem(asset: asset)
                let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true])
                item.add(o); output = o; frame = nil; needsDetect = true
                player.replaceCurrentItem(with: item); player.play()
            } catch { videoLabel.stringValue = "Could not open: \(error.localizedDescription)" }
        }
    }
    func togglePlay() { player.rate == 0 ? player.play() : player.pause() }
    func setPicking(_ on: Bool) { picking = on; pickButton.title = on ? "Click the Green…" : "Pick Green" }
    func updateSwatch() {
        let c = settings.screen
        swatch.layer?.backgroundColor = CGColor(colorSpace: r.linear, components: [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), 1])
    }
    func resetControls() {
        for (s, value, key, def) in sliders { self[keyPath: key] = def; s.doubleValue = Double(def); value.stringValue = String(format: "%.2f", def) }
        if let f = frame, let c = r.detectScreen(f) { settings.screen = c; updateSwatch() }
    }
    func clicked(_ p: CGPoint) {
        guard picking, let f = frame else { return }
        let s = window.backingScaleFactor
        let q = CGPoint(x: p.x * s, y: p.y * s).applying(fit.inverted())
        if let c = r.average(f, rect: CGRect(x: q.x - 6, y: q.y - 6, width: 12, height: 12)) { settings.screen = c; updateSwatch() }
        setPicking(false)
    }
    func updateStats() {
        guard output != nil else { return }
        let n = videoFrames; videoFrames = 0; let times = gpuTimes; gpuTimes = []
        guard player.rate != 0, !times.isEmpty else { speedLabel.stringValue = "Speed: paused"; return }
        let avg = times.reduce(0, +) / Double(times.count), budget = 1000 / fps
        let ok = avg < budget && Double(n) >= fps * 0.9
        speedLabel.stringValue = String(format: "Preview: %d of %.3g frames/sec\nRender: %.1f ms per frame (limit %.0f ms)\n%@", n, fps, avg, budget, ok ? "Keeping up" : "Falling behind")
        speedLabel.textColor = ok ? .systemGreen : .systemOrange
    }
    func fullSizeTest() {
        guard let f = frame else { return }
        fullLabel.stringValue = "Testing…"; let s = settings, m = ViewMode.key, b = backdrop, rr = r, rate = fps
        DispatchQueue.global(qos: .userInitiated).async {
            guard let t = rr.makeTarget(width: Int(f.extent.width), height: Int(f.extent.height)) else { return }
            let im = rr.compose(f, settings: s, mode: m, backdrop: b)
            let v = (0..<30).map { _ in rr.timedRender(im, to: t, bounds: f.extent) }
            let avg = v.reduce(0, +) / 30
            DispatchQueue.main.async {
                self.fullLabel.stringValue = String(format: "Full size: %.1f ms per frame, worst %.1f ms (limit %.0f ms)", avg, v.max() ?? 0, 1000 / rate)
            }
        }
    }

    func mtkView(_ v: MTKView, drawableSizeWillChange s: CGSize) { dirty = true }
    func draw(in v: MTKView) {
        if let o = output {
            let t = o.itemTime(forHostTime: CACurrentMediaTime())
            if o.hasNewPixelBuffer(forItemTime: t), let pb = o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                var im = CIImage(cvPixelBuffer: pb).oriented(orientation)
                im = im.transformed(by: CGAffineTransform(translationX: -im.extent.minX, y: -im.extent.minY))
                frame = im; dirty = true; videoFrames += 1
                if needsDetect { needsDetect = false; if let c = r.detectScreen(im) { settings.screen = c; updateSwatch() } }
            }
        }
        guard dirty, let f = frame, let d = v.currentDrawable, let cb = r.queue.makeCommandBuffer() else { return }
        dirty = false
        let W = CGFloat(d.texture.width), H = CGFloat(d.texture.height)
        let k = min(W / f.extent.width, H / f.extent.height)
        fit = CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: (W - f.extent.width * k) / 2, y: (H - f.extent.height * k) / 2))
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        let out = r.compose(f, settings: settings, mode: mode, backdrop: backdrop).transformed(by: fit)
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        let start = CACurrentMediaTime()
        let dest = CIRenderDestination(mtlTexture: d.texture, commandBuffer: cb); dest.colorSpace = r.sRGB
        guard let task = try? r.context.startTask(toRender: out, from: bounds, to: dest, at: .zero) else { return }
        cb.present(d); cb.commit()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? task.waitUntilCompleted()
            let ms = (CACurrentMediaTime() - start) * 1000
            DispatchQueue.main.async { self?.gpuTimes.append(ms) }
        }
    }
}

do {
    let controller = AppController(renderer: try Renderer())
    let app = NSApplication.shared
    app.setActivationPolicy(.regular); app.delegate = controller; app.run()
} catch { print("Could not start: \(error)"); exit(1) }
