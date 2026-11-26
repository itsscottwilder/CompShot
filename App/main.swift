import AppKit
import AVFoundation
import MetalKit
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--benchmark" {
    Task { await runBenchmark(Array(args.dropFirst())); exit(0) }
    dispatchMain()
}
if args.first == "--export" {
    Task { await runExportCLI(Array(args.dropFirst())); exit(0) }
    dispatchMain()
}

final class Action: NSObject {
    let run: (Any?) -> Void
    init(_ run: @escaping (Any?) -> Void) { self.run = run }
    @objc func fire(_ s: Any?) { run(s) }
}

/// The empty video area: 1Shot's project-screen look, and it accepts a dropped video.
final class DropZone: NSView {
    var onDrop: ((URL) -> Bool)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { url(s) != nil ? .copy : [] }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { url(s).map { onDrop?($0) ?? false } ?? false }
    private func url(_ s: NSDraggingInfo) -> URL? {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
    }
}

final class AppController: NSObject, NSApplicationDelegate, MTKViewDelegate {
    let r: Renderer
    var window: NSWindow!, view: KeyView!
    var actions: [Action] = []
    var settings = KeySettings() { didSet { dirty = true } }
    var mode = ViewMode.key { didSet { dirty = true; updateHandles() } }
    /// One background choice, in the bar above the video, for every page.
    var backdrop = Backdrop.blue { didSet { viewBar?.setBackdrop(backdrop); dirty = true } }
    /// Split view: where the line between matte (left) and final (right) sits, as a share of the frame width.
    var split: CGFloat = 0.5 { didSet { dirty = true } }
    var placement = Placement() { didSet { dirty = true; updateHandles() } }
    var currentStep = Step.key
    struct PlaceDrag { let grab: PlacementHandles.Grab; let start: NSPoint; let box: NSRect; let placement: Placement; let settings: KeySettings }
    var placeDrag: PlaceDrag?
    var player = AVPlayer(), output: AVPlayerItemVideoOutput?
    var frame: CIImage?, orientation = CGImagePropertyOrientation.up
    var dirty = false, picking = false, needsDetect = false, looping = true, screenPicked = false
    var fit = CGAffineTransform.identity
    var fps = 30.0, duration = 0.0, videoSize = CGSize.zero, videoFrames = 0, gpuTimes: [Double] = []
    var background: BackgroundPreview?, clipURL: URL?, exporter: Exporter?
    var bgBlur: Float = 0 { didSet { dirty = true } }
    var blend = Blend() { didSet { dirty = true } }
    /// Visual Design (0.8): the grade from 1Shot's panel. Bypass is for the preview only.
    var look = Look() { didSet { dirty = true } }
    var gradeBypass = false { didSet { dirty = true } }
    var wbPicking = false, histogramBusy = false
    var design: VisualDesignPanel!
    /// The grade the preview shows (on every page since 0.8, so the key is judged on the picture you'll export).
    var shownLook: Look? {
        guard !look.isNeutral else { return nil }
        return gradeBypass ? look.bypassed : look
    }
    var timeObserver: Any?
    var sliders: [(ResetSlider, NSTextField, ReferenceWritableKeyPath<AppController, Float>, Float, (Float) -> String)] = []

    // Views
    var handles: PlacementHandles!, viewBar: ViewBar!
    var transport: TransportBar!, tabs: StepTabBar!, scrub: ScrubBar!, emptyState: DropZone!
    var pages: [Step: NSView] = [:]
    var screenCard: ScreenCard!, pickButton: NSButton!
    var bgLabel: NSTextField!
    var exportKind: NSPopUpButton!, exportSpecs: NSTextField!, exportButton: NSButton!, cancelButton: NSButton!
    var exportProgress: NSProgressIndicator!, exportLabel: NSTextField!, perfLabel: NSTextField!, fullLabel: NSTextField!

    init(renderer: Renderer) { r = renderer }

    // MARK: Settings the sliders edit

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
    var placeScale: Float { get { placement.scale } set { placement.scale = newValue } }
    var lightWrap: Float { get { blend.lightWrap } set { blend.lightWrap = newValue } }
    var wrapWidth: Float { get { blend.wrapWidth } set { blend.wrapWidth = newValue } }
    var diffusion: Float { get { blend.diffusion } set { blend.diffusion = newValue } }
    var soften: Float { get { blend.soften } set { blend.soften = newValue } }
    var placeX: Float { get { placement.x } set { placement.x = newValue } }
    var placeY: Float { get { placement.y } set { placement.y = newValue } }

    static let percent: (Float) -> String = { "\(Int(($0 * 100).rounded()))%" }
    static let number: (Float) -> String = { String(format: "%.2f", $0) }
    static let pixels: (Float) -> String = { $0 == 0 ? "Off" : String(format: "%.1f px", $0) }
    static let signedPercent: (Float) -> String = { v in let p = Int((v * 100).rounded()); return p > 0 ? "+\(p)%" : "\(p)%" }
    static let blurPixels: (Float) -> String = { $0 == 0 ? "Off" : String(format: "%.0f px", $0) }

    func action(_ f: @escaping (Any?) -> Void) -> Action { let a = Action(f); actions.append(a); return a }

    /// A 1Shot-style slider row: name, small slider (double-click resets), value on the right.
    func row(_ name: String, _ key: ReferenceWritableKeyPath<AppController, Float>, _ lo: Float, _ hi: Float,
             _ format: @escaping (Float) -> String, _ help: String) -> NSStackView {
        let label = NSTextField(labelWithString: name); label.font = .systemFont(ofSize: 12); label.toolTip = help
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let def = self[keyPath: key]
        let value = NSTextField(labelWithString: format(def))
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let a = action { [unowned self] s in
            let v = Float((s as! NSSlider).doubleValue); self[keyPath: key] = v; value.stringValue = format(v)
        }
        let s = ResetSlider(value: Double(def), minValue: Double(lo), maxValue: Double(hi), target: a, action: #selector(Action.fire(_:)))
        s.resetValue = Double(def); s.isContinuous = true; s.controlSize = .small; s.refusesFirstResponder = true
        s.toolTip = help + " · double-click to reset"
        sliders.append((s, value, key, def, format))
        let line = NSStackView(views: [label, s, value]); line.orientation = .horizontal; line.spacing = 6
        return line
    }

    /// Moves sliders to match values changed elsewhere (e.g. by dragging the handles).
    func refreshSliders(_ keys: [ReferenceWritableKeyPath<AppController, Float>]) {
        for (s, value, key, _, format) in sliders where keys.contains(key) {
            s.doubleValue = Double(self[keyPath: key]); value.stringValue = format(self[keyPath: key])
        }
    }

    /// The settings that depend on green or blue, and their current tuned starting values.
    var tunedDefaults: [ReferenceWritableKeyPath<AppController, Float>: Float] {
        let d = settings.screenDefaults
        return [\.strength: d.strength, \.softness: d.softness, \.spill: d.spill, \.spillFirmness: d.spillFirmness]
    }

    func resetSliders(_ keys: [ReferenceWritableKeyPath<AppController, Float>]) {
        let tuned = tunedDefaults
        for (s, value, key, def, format) in sliders where keys.contains(key) {
            let v = tuned[key] ?? def
            self[keyPath: key] = v; s.doubleValue = Double(v); value.stringValue = format(v)
        }
    }

    /// Green and blue screens start from different values. Applies them when the screen type is found
    /// or changes, and points each slider's double-click reset at the right value.
    func applyScreenDefaults() {
        settings.applyScreenDefaults()
        let tuned = tunedDefaults
        for (s, _, key, _, _) in sliders { if let v = tuned[key] { s.resetValue = Double(v) } }
        refreshSliders(Array(tuned.keys))
    }

    // MARK: Building the window

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        view = KeyView(frame: .zero, device: r.device)
        view.colorPixelFormat = .bgra8Unorm; view.framebufferOnly = false; view.delegate = self
        view.preferredFramesPerSecond = 60; view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.onClick = { [unowned self] p in self.clicked(p) }
        view.onDrop = { [unowned self] u in self.dropped(u) }; view.enableDrops()

        transport = TransportBar()
        transport.onPlay = { [unowned self] in self.togglePlay() }
        transport.onStart = { [unowned self] in self.seek(0) }
        transport.onEnd = { [unowned self] in self.seek(max(0, self.duration - 0.05)) }
        transport.onBack = { [unowned self] in self.step(-1) }
        transport.onForward = { [unowned self] in self.step(1) }
        transport.onLoop = { [unowned self] in self.looping.toggle(); self.transport.setLoop(self.looping) }
        viewBar = ViewBar()
        viewBar.onView = { [unowned self] m in self.mode = m }
        viewBar.onBackdrop = { [unowned self] b in
            if b == .custom && self.background == nil { self.chooseBackground() } else { self.backdrop = b }
        }
        tabs = StepTabBar()
        tabs.onSelect = { [unowned self] s in self.show(s) }
        scrub = ScrubBar()
        scrub.onSeek = { [unowned self] t in self.seek(t) }
        emptyState = buildEmptyState()

        handles = PlacementHandles(); handles.isHidden = true
        handles.onGrab = { [unowned self] g, p in self.beginPlaceDrag(g, p) }
        handles.onDrag = { [unowned self] p, fine in self.continuePlaceDrag(p, fine: fine) }
        handles.onRelease = { [unowned self] in self.placeDrag = nil; self.updateHandles() }
        pages = [.key: buildKeyPage(), .design: buildDesignPage(), .export: buildExportPage()]
        let panel = NSView()
        for (_, p) in pages { p.frame = panel.bounds; p.autoresizingMask = [.width, .height]; p.isHidden = true; panel.addSubview(p) }
        show(.key)

        let root = NSView(); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.black.cgColor
        for v in [viewBar!, view!, handles!, emptyState!, transport!, tabs!, scrub!, panel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: root.topAnchor), panel.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: root.trailingAnchor), panel.widthAnchor.constraint(equalToConstant: Theme.panelWidth),
            viewBar.topAnchor.constraint(equalTo: root.topAnchor), viewBar.heightAnchor.constraint(equalToConstant: Theme.barHeight + 4),
            view.topAnchor.constraint(equalTo: viewBar.bottomAnchor), view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: panel.leadingAnchor),
            handles.topAnchor.constraint(equalTo: view.topAnchor), handles.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            handles.leadingAnchor.constraint(equalTo: view.leadingAnchor), handles.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: view.topAnchor), emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor), emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transport.topAnchor.constraint(equalTo: view.bottomAnchor), transport.heightAnchor.constraint(equalToConstant: Theme.barHeight + 4),
            tabs.topAnchor.constraint(equalTo: transport.bottomAnchor), tabs.heightAnchor.constraint(equalToConstant: Theme.barHeight),
            scrub.topAnchor.constraint(equalTo: tabs.bottomAnchor), scrub.heightAnchor.constraint(equalToConstant: ScrubBar.height),
            scrub.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for v in [viewBar!, transport!, tabs!, scrub!] as [NSView] {
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: panel.leadingAnchor).isActive = true
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CompShot"; window.appearance = NSAppearance(named: .darkAqua); window.contentView = root
        window.minSize = NSSize(width: 900, height: 600); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateScreenCard()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] e in
            guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
            switch e.keyCode {
            case 49: self.togglePlay(); return nil
            case 53 where self.wbPicking || self.picking:   // Esc stops either eyedropper
                if self.wbPicking { self.setWBPicking(false) } else { self.setPicking(false) }; return nil
            case 123: self.step(-1); return nil
            case 124: self.step(1); return nil
            default: return e
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in self.updateStats() }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [unowned self] _ in self.updateHistogram() }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [unowned self] n in
            guard (n.object as? AVPlayerItem) === self.player.currentItem, self.looping else { return }
            self.player.seek(to: .zero); self.player.play()
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [unowned self] t in
            self.scrub.time = t.seconds
            self.transport.setPlaying(self.player.rate != 0)
            self.syncBackground()
        }
        ControlServer.shared.start(controller: self)   // 0.7: lets AI apps drive CompShot over MCP
        if let p = args.first, !p.hasPrefix("--") { open(URL(fileURLWithPath: p)) }
        if let i = args.firstIndex(of: "--bg"), i + 1 < args.count { loadBackground(URL(fileURLWithPath: args[i + 1])) }
        if let i = args.firstIndex(of: "--step"), i + 1 < args.count, let n = Int(args[i + 1]), let s = Step(rawValue: n) { tabs.select(s); show(s) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { ControlServer.shared.stop() }

    func buildMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let app = NSMenu(); app.addItem(withTitle: "Quit CompShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let fileItem = NSMenuItem(); bar.addItem(fileItem)
        let file = NSMenu(title: "File")
        for (t, k, f) in [("Open Video…", "o", { [unowned self] in self.openPanel() }),
                          ("Choose Background…", "b", { [unowned self] in self.chooseBackground() }),
                          ("Export…", "e", { [unowned self] in self.export() })] as [(String, String, () -> Void)] {
            let a = action { _ in f() }
            let item = NSMenuItem(title: t, action: #selector(Action.fire(_:)), keyEquivalent: k); item.target = a
            file.addItem(item)
        }
        fileItem.submenu = file
        NSApp.mainMenu = bar
    }

    func buildEmptyState() -> DropZone {
        let z = DropZone(); z.wantsLayer = true; z.layer?.backgroundColor = Theme.welcome.cgColor
        z.onDrop = { [unowned self] u in self.dropped(u) }
        let eyebrow = NSTextField(labelWithString: "COMPSHOT"); eyebrow.font = .boldSystemFont(ofSize: 11); eyebrow.textColor = Theme.eyebrow
        let title = NSTextField(labelWithString: "Drop a green or blue screen video"); title.font = .boldSystemFont(ofSize: 30)
        let sub = NSTextField(labelWithString: "CompShot removes the screen and puts you on any background.")
        sub.font = .systemFont(ofSize: 13); sub.textColor = .secondaryLabelColor
        let open = NSButton(title: "Open Video…", target: action { [unowned self] _ in self.openPanel() }, action: #selector(Action.fire(_:)))
        open.bezelStyle = .rounded; open.controlSize = .large
        let s = NSStackView(views: [eyebrow, title, sub, open]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 6
        s.setCustomSpacing(22, after: sub)
        s.translatesAutoresizingMaskIntoConstraints = false; z.addSubview(s)
        NSLayoutConstraint.activate([s.centerXAnchor.constraint(equalTo: z.centerXAnchor), s.centerYAnchor.constraint(equalTo: z.centerYAnchor)])
        return z
    }

    /// Key and Compose (0.8): everything that shapes the key and where you sit, on one page, because each
    /// control changes what the others need. Grouped by what the controls do; masks and position are dragged on the video.
    func buildKeyPage() -> NSView {
        screenCard = ScreenCard()
        let header = headerRow(titleLabel("Key and Compose"), [smallButton("Reset All", action { [unowned self] _ in self.resetAll() },
                                                                           #selector(Action.fire(_:)),
                                                                           tip: "Detect the screen color again and put every key, edge and mask control back to its default (keeps the background, size and position)")])
        let note = noteLabel("Every control here affects the others. Choose Split above the video to watch the matte and the final picture together.")
        pickButton = NSButton(title: "Pick Screen Color", target: action { [unowned self] _ in self.setPicking(!self.picking) }, action: #selector(Action.fire(_:)))
        pickButton.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "Pick the screen color")
        pickButton.imagePosition = .imageLeading; pickButton.setButtonType(.pushOnPushOff); pickButton.bezelStyle = .rounded
        pickButton.controlSize = .large; pickButton.refusesFirstResponder = true
        pickButton.toolTip = "Click, then click a clean part of the screen in the video"
        func group(_ title: String, _ keys: [ReferenceWritableKeyPath<AppController, Float>], _ tip: String) -> NSStackView {
            headerRow(sectionLabel(title), [smallButton("Reset", action { [unowned self] _ in self.resetSliders(keys) }, #selector(Action.fire(_:)), tip: tip)])
        }

        let matteHeader = group("Matte", [\.strength, \.softness, \.correction], "Strength, Softness and Correction back to their defaults")
        let strength = row("Strength", \.strength, 0.5, 2.5, Self.number, "How firmly the screen color is removed. Raise it if the screen or floor still shows; lower it if hair thins out.")
        let soft = row("Softness", \.softness, 0.05, 1, Self.percent, "Where the person counts as fully solid. Lower makes nearly solid areas (like a white shirt tinted by the screen) solid; higher keeps more soft edge detail and motion blur.")
        let corr = row("Correction", \.correction, 0, 1, Self.percent, "Follows wrinkles, uneven light and shadows on the screen instead of treating it as one flat color")

        let spillHeader = group("Spill", [\.spill, \.spillFirmness], "Spill and Firmness back to their defaults")
        let spill = row("Spill", \.spill, 0, 1, Self.percent, "Removes screen-colored light reflected onto hair and skin")
        let firm = row("Firmness", \.spillFirmness, 0, 1, Self.percent, "Higher also removes the tint the screen leaves in hair. Lower it if clothing near the screen color starts to look off.")

        let edgesHeader = group("Edges", [\.shrinkEdges, \.smoothEdges, \.edgeRepair], "Shrink, Smooth and Edge color back to their defaults")
        let shrink = row("Shrink", \.shrinkEdges, 0, 3, Self.pixels, "Pulls the edge in to remove a thin outline")
        let smooth = row("Smooth", \.smoothEdges, 0, 3, Self.pixels, "Softens jagged, blocky edges from compressed video. Leave Shrink and Smooth off for clean 4K.")
        let repair = row("Edge color", \.edgeRepair, 0, 1, Self.percent, "See-through edges borrow color from the person, removing colored fringes")

        let blendHeader = group("Blend", [\.lightWrap, \.wrapWidth, \.diffusion, \.soften], "Light wrap, Diffusion and Soften off")
        let blendNote = noteLabel("Helps you sit in the background instead of looking pasted on. Only you are affected.")
        let wrap = row("Light wrap", \.lightWrap, 0, 1, Self.percent, "The background's light spills over your edges, the way it would if you were really there. The biggest help against a cut-out look.")
        let wrapW = row("Wrap width", \.wrapWidth, 2, 40, Self.blurPixels, "How far in from your edges the light wrap reaches")
        let diff = row("Diffusion", \.diffusion, 0, 1, Self.percent, "Like a mist filter on the lens: bright parts glow softly and fine contrast drops, to match a dreamy background")
        let soft2 = row("Soften", \.soften, 0, 2, Self.pixels, "A light blur for over-sharpened footage and hard outlines. Small amounts only.")

        let maskHeader = headerRow(sectionLabel("Mask"), [smallButton("Reset", action { [unowned self] _ in self.resetMask() }, #selector(Action.fire(_:)),
                                                                      tip: "No mask: keep the whole frame")])
        let maskNote = noteLabel("Drag a side of the box on the video (the orange grips) to crop out lights, stands and walls beyond the screen.")

        let bgTitle = sectionLabel("Background")
        let choose = NSButton(title: "Choose Image or Video…", target: action { [unowned self] _ in self.chooseBackground() }, action: #selector(Action.fire(_:)))
        choose.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil); choose.imagePosition = .imageLeading
        choose.bezelStyle = .rounded; choose.refusesFirstResponder = true
        bgLabel = noteLabel("No background chosen. Videos loop in time with your clip.")
        let blur = row("Blur", \.bgBlur, 0, 20, Self.blurPixels, "Softens the background so it looks out of focus behind you")

        let placeHeader = headerRow(sectionLabel("Size and position"), [smallButton("Reset", action { [unowned self] _ in
            self.placement = Placement(); self.refreshSliders([\.placeScale])
        }, #selector(Action.fire(_:)), tip: "Back to full size, centred")])
        let placeNote = noteLabel("Drag a corner of the box to resize, the middle to move. Hold Shift for fine control.")
        let size = row("Size", \.placeScale, 0.25, 3, Self.percent, "How big you are in the frame")

        let views: [NSView] = [screenCard, header, note, pickButton, matteHeader, strength, soft, corr, spillHeader, spill, firm,
                               edgesHeader, shrink, smooth, repair, blendHeader, blendNote, wrap, wrapW, diff, soft2,
                               maskHeader, maskNote, bgTitle, choose, bgLabel, blur, placeHeader, placeNote, size]
        return panelPage(views, spacingAfter: [screenCard: 14, note: 12, pickButton: 18, matteHeader: 2, corr: 16, spillHeader: 2, firm: 16,
                                               edgesHeader: 2, repair: 16, blendHeader: 2, blendNote: 6, soft2: 16, maskHeader: 2, maskNote: 16, bgTitle: 6, choose: 4, bgLabel: 8, blur: 16, placeHeader: 2, placeNote: 6],
                         fullWidth: [screenCard, header, note, pickButton, matteHeader, strength, soft, corr, spillHeader, spill, firm,
                                     edgesHeader, shrink, smooth, repair, blendHeader, blendNote, wrap, wrapW, diff, soft2, maskHeader, maskNote, choose, bgLabel, blur, placeHeader, placeNote, size])
    }

    func resetMask() {
        settings.maskLeft = 0; settings.maskRight = 0; settings.maskTop = 0; settings.maskBottom = 0
        updateHandles()
    }
    func resetAll() {
        resetKey()
        resetSliders([\.correction, \.shrinkEdges, \.smoothEdges, \.edgeRepair]); resetMask()
    }

    func buildDesignPage() -> NSView {
        design = VisualDesignPanel()
        design.onGradeChanged = { [unowned self] s in self.look.settings = s }
        design.onBypassChanged = { [unowned self] on in self.gradeBypass = on }
        design.onTargetChanged = { [unowned self] whole in self.look.wholePicture = whole }
        design.onEyedropper = { [unowned self] in self.setWBPicking(!self.wbPicking) }
        design.onLUTSelected = { [unowned self] slot, url in self.useLUT(url, slot: slot) }
        design.onLoadLUT = { [unowned self] slot in
            let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
            p.message = slot == .camera ? "Choose a camera LUT (.cube)" : "Choose a creative LUT (.cube)"
            guard p.runModal() == .OK, let u = p.url else { return }
            do {
                let copy = try CubeLUT.importToLibrary(u)
                self.design.rebuildLUTMenu(select: copy, slot: slot); self.useLUT(copy, slot: slot)
            } catch { self.lutFailed(error, slot: slot) }
        }
        return design
    }

    func useLUT(_ url: URL?, slot: VisualDesignPanel.LUTSlot) {
        do {
            let lut = try url.map { try CubeLUT.cached(url: $0) }
            if slot == .camera { look.lut = lut } else { look.creativeLUT = lut }
        } catch { lutFailed(error, slot: slot) }
    }
    func lutFailed(_ error: Error, slot: VisualDesignPanel.LUTSlot) {
        design.clearLUTSelection(slot)
        if slot == .camera { look.lut = nil } else { look.creativeLUT = nil }
        let a = NSAlert(); a.messageText = "That LUT can't be used"; a.informativeText = error.localizedDescription; a.runModal()
    }

    func setWBPicking(_ on: Bool) {
        if on && picking { setPicking(false) }
        guard on != wbPicking else { return }
        wbPicking = on; design.setEyedropperActive(on)
        if on { design.setWhiteBalanceNote(nil); NSCursor.crosshair.push() } else { NSCursor.pop() }
        updateHandles()
    }

    /// White balance eyedropper: measures what the grade starts from at the clicked spot (the keyed
    /// person, spill already removed, or the whole ungraded picture) and solves Color and Tint so it
    /// comes out neutral after the camera LUT.
    func pickWhite(_ viewPoint: CGPoint) {
        setWBPicking(false)
        guard let f = frame else { return }
        let k = window.backingScaleFactor
        let q = CGPoint(x: viewPoint.x * k, y: viewPoint.y * k).applying(fit.inverted())
        let spot = { (p: CGPoint) in CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8) }
        let measured: SIMD4<Float>?
        if mode == .original {
            measured = r.averageRGBA(f, rect: spot(q))
        } else if look.wholePicture {
            let ungraded = r.compose(f, settings: settings, mode: .key, backdrop: backdrop,
                                     custom: background?.current, blur: bgBlur, placement: placement)
            measured = r.averageRGBA(ungraded, rect: spot(q))
        } else {
            let p = q.applying(placement.transform(for: f.extent).inverted())
            measured = r.averageRGBA(r.keyer.apply(to: f, settings: settings), rect: spot(p))
        }
        guard let m = measured, m.w > 0.5 else {
            design.setWhiteBalanceNote("That spot is see-through. Click something white or gray on you, like a shirt or the whites of your eyes.")
            return
        }
        let c = SIMD3(m.x, m.y, m.z) / m.w
        let lut = look.lut
        design.setWhiteBalanceNote("Measuring…")
        DispatchQueue.global(qos: .userInitiated).async {
            let wb = ColorGrade.solveWhiteBalance(linear: c, lut: lut)
            DispatchQueue.main.async {
                self.design.applyWhiteBalance(temperature: wb.temperature, tint: wb.tint)
                self.design.setWhiteBalanceNote(String(format: "Set from the picked spot: Color %+.0f, Tint %+.0f", wb.temperature, wb.tint))
            }
        }
    }

    /// Red, green and blue histogram of what the grade produces (just you, or the whole picture),
    /// from a small copy of the frame, four times a second while Visual Design is showing.
    func updateHistogram() {
        guard currentStep == .design, !histogramBusy, let f = frame else { return }
        histogramBusy = true
        let rr = r, s = settings, l = shownLook ?? Look(), whole = look.wholePicture, b = backdrop, bg = background?.current
        let blur = bgBlur, place = placement
        DispatchQueue.global(qos: .utility).async {
            let w = 320, h = max(1, Int(320 * f.extent.height / f.extent.width)), k = CGFloat(w) / f.extent.width
            let small = f.transformed(by: CGAffineTransform(scaleX: k, y: k))
            let im = whole ? rr.compose(small, settings: s, mode: .key, backdrop: b, custom: bg, blur: blur, placement: place, look: l)
                           : l.gradePerson(rr.keyer.apply(to: small, settings: s))
            var px = [UInt8](repeating: 0, count: w * h * 4)
            rr.context.render(im, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: rr.sRGB)
            var bins = [Float](repeating: 0, count: 768)
            for i in stride(from: 0, to: px.count, by: 4) {
                let a = Float(px[i + 3]); guard a >= 128 else { continue }   // only the solid parts of you
                let u = 255 / a
                bins[min(255, Int(Float(px[i]) * u))] += 1
                bins[256 + min(255, Int(Float(px[i + 1]) * u))] += 1
                bins[512 + min(255, Int(Float(px[i + 2]) * u))] += 1
            }
            DispatchQueue.main.async { self.histogramBusy = false; self.design.setHistogram(bins) }
        }
    }

    func buildExportPage() -> NSView {
        let title = titleLabel("Export")
        let note = noteLabel("Everything you set is included: the key, edges, mask, background and Visual Design. Audio is copied as is.")
        exportKind = NSPopUpButton(frame: .zero, pullsDown: false)
        exportKind.addItems(withTitles: ["With background · MP4", "Transparent · ProRes 4444 MOV"])
        exportKind.target = action { [unowned self] _ in self.updateExportSpecs() }; exportKind.action = #selector(Action.fire(_:))
        exportKind.toolTip = "With background: a finished video to upload. Transparent: just you, for DaVinci Resolve or Final Cut (large files)."
        exportSpecs = NSTextField(wrappingLabelWithString: "Open a video first"); exportSpecs.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        exportButton = NSButton(title: "Export…", target: action { [unowned self] _ in self.export() }, action: #selector(Action.fire(_:)))
        exportButton.bezelStyle = .rounded; exportButton.controlSize = .large; exportButton.refusesFirstResponder = true
        exportProgress = NSProgressIndicator(); exportProgress.style = .bar; exportProgress.isIndeterminate = false
        exportProgress.minValue = 0; exportProgress.maxValue = 1; exportProgress.isHidden = true; exportProgress.controlSize = .small
        cancelButton = smallButton("Cancel", action { [unowned self] _ in self.exporter?.cancel() }, #selector(Action.fire(_:)), tip: "Stop the export")
        cancelButton.isHidden = true
        exportLabel = noteLabel("")
        let statusRow = NSStackView(views: [exportLabel, NSView(), cancelButton]); statusRow.orientation = .horizontal
        let perfTitle = sectionLabel("Performance")
        perfLabel = noteLabel("Play the video to measure")
        let test = smallButton("Test Full-Size Speed", action { [unowned self] _ in self.fullSizeTest() }, #selector(Action.fire(_:)),
                               tip: "Times the key at the video's full resolution, as export renders it")
        fullLabel = noteLabel("")
        let views: [NSView] = [title, note, exportKind, exportSpecs, exportButton, exportProgress, statusRow, perfTitle, perfLabel, test, fullLabel]
        return panelPage(views, spacingAfter: [note: 14, exportSpecs: 14, statusRow: 22, perfTitle: 6],
                         fullWidth: [note, exportKind, exportSpecs, exportButton, exportProgress, statusRow, perfLabel, fullLabel])
    }

    func show(_ s: Step) {
        currentStep = s; dirty = true
        if s != .design && wbPicking { setWBPicking(false) }
        if s != .key && picking { setPicking(false) }
        for (k, p) in pages { p.isHidden = k != s }
        updateHandles()
    }

    // MARK: Size and position (Compose)

    /// The part of the frame that is kept (inside the mask), in image pixels.
    func baseRect(_ e: CGRect) -> CGRect {
        let m = settings
        return CGRect(x: e.minX + CGFloat(m.maskLeft) * e.width, y: e.minY + CGFloat(m.maskBottom) * e.height,
                      width: e.width * CGFloat(1 - m.maskLeft - m.maskRight), height: e.height * CGFloat(1 - m.maskTop - m.maskBottom))
    }
    func imageToView(_ r: CGRect) -> NSRect {
        let k = window.backingScaleFactor, p = r.applying(fit)
        return NSRect(x: p.minX / k, y: view.bounds.height - p.maxY / k, width: p.width / k, height: p.height / k)
    }
    func viewToImage(_ r: NSRect) -> CGRect {
        let k = window.backingScaleFactor
        return CGRect(x: r.minX * k, y: (view.bounds.height - r.maxY) * k, width: r.width * k, height: r.height * k).applying(fit.inverted())
    }
    /// The box (Key and Compose page, any view but Original) and the split line (Split view, any page).
    func updateHandles() {
        guard handles != nil, placeDrag == nil else { return }
        guard let f = frame, emptyState.isHidden, mode != .original, !picking, !wbPicking else {   // eyedroppers need clicks on the video
            handles.isHidden = true; handles.box = nil; handles.splitX = nil; return
        }
        let shown = imageToView(f.extent)
        handles.box = currentStep == .key ? imageToView(baseRect(f.extent).applying(placement.transform(for: f.extent))) : nil
        handles.splitX = mode == .split ? shown.minX + shown.width * split : nil
        handles.isHidden = handles.box == nil && handles.splitX == nil
    }
    func beginPlaceDrag(_ g: PlacementHandles.Grab, _ p: NSPoint) {
        if g != .split { player.pause(); syncBackground() }
        placeDrag = PlaceDrag(grab: g, start: p, box: handles.box ?? .zero, placement: placement, settings: settings)
    }
    func continuePlaceDrag(_ p: NSPoint, fine: Bool) {
        guard let d = placeDrag, let f = frame else { return }
        let k: CGFloat = fine ? 0.25 : 1
        let delta = CGPoint(x: (p.x - d.start.x) * k, y: (p.y - d.start.y) * k)
        var box = d.box
        switch d.grab {
        case .split:
            let shown = imageToView(f.extent)
            split = min(0.97, max(0.03, (p.x - shown.minX) / max(shown.width, 1)))
            handles.splitX = shown.minX + shown.width * split
            return
        case .edge(let side):
            // A side of the box is that edge of the mask. Convert the drag to a share of the frame at its current size.
            let shown = imageToView(f.extent), s = CGFloat(d.placement.scale)
            let fx = Float(delta.x / max(shown.width * s, 1)), fy = Float(delta.y / max(shown.height * s, 1))
            var m = d.settings
            switch side {
            case 0: m.maskLeft = min(max(m.maskLeft + fx, 0), min(0.5, 0.9 - m.maskRight))
            case 1: m.maskRight = min(max(m.maskRight - fx, 0), min(0.5, 0.9 - m.maskLeft))
            case 2: m.maskTop = min(max(m.maskTop + fy, 0), min(0.5, 0.9 - m.maskBottom))
            default: m.maskBottom = min(max(m.maskBottom - fy, 0), min(0.5, 0.9 - m.maskTop))
            }
            settings.maskLeft = m.maskLeft; settings.maskRight = m.maskRight; settings.maskTop = m.maskTop; settings.maskBottom = m.maskBottom
            handles.box = imageToView(baseRect(f.extent).applying(placement.transform(for: f.extent)))
            return
        case .move:
            box = box.offsetBy(dx: delta.x, dy: delta.y)
        case .corner(let c):
            // The opposite corner stays put; the size follows the mouse along the diagonal (as in 1Shot).
            let cs = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
            let from = cs[c], fixed = cs[3 - c], to = CGPoint(x: from.x + delta.x, y: from.y + delta.y)
            let diag = CGPoint(x: from.x - fixed.x, y: from.y - fixed.y), len2 = diag.x * diag.x + diag.y * diag.y
            guard len2 > 1 else { return }
            let s0 = CGFloat(d.placement.scale)
            let r = min(max(((to.x - fixed.x) * diag.x + (to.y - fixed.y) * diag.y) / len2, 0.25 / s0), 3 / s0)
            let w = box.width * r, h = box.height * r
            box = CGRect(x: c % 2 == 0 ? fixed.x - w : fixed.x, y: c < 2 ? fixed.y - h : fixed.y, width: w, height: h)
        }
        // Work out the size and nudge that put the kept area exactly in that box.
        let e = f.extent, base = baseRect(e), img = viewToImage(box)
        let s = img.width / max(base.width, 1), c = CGPoint(x: e.midX, y: e.midY)
        let dx = img.minX - c.x - s * (base.minX - c.x), dy = img.minY - c.y - s * (base.minY - c.y)
        placement = Placement(scale: Float(s), x: Float(dx / e.width), y: Float(-dy / e.height))
        handles.box = box
        refreshSliders([\.placeScale])
    }

    // MARK: Video

    func openPanel() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.movie]; p.message = "Choose a green or blue screen video"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }
    func dropped(_ u: URL) -> Bool {
        guard let t = UTType(filenameExtension: u.pathExtension), t.conforms(to: .movie) || t.conforms(to: .image) else { return false }
        if t.conforms(to: .image) || (clipURL != nil && NSEvent.modifierFlags.contains(.option)) { loadBackground(u) } else { open(u) }
        return true
    }
    func open(_ url: URL, play: Bool = !args.contains("--paused")) {
        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: url)
                guard let t = try await asset.loadTracks(withMediaType: .video).first else { exportLabel.stringValue = "That file has no video"; return }
                let (size, xf, rate) = try await t.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                duration = try await asset.load(.duration).seconds
                orientation = CompShot.orientation(for: xf)
                let side = orientation == .left || orientation == .right
                videoSize = side ? CGSize(width: size.height, height: size.width) : size
                fps = Double(rate > 0 ? rate : 30); scrub.duration = duration
                let item = AVPlayerItem(asset: asset)
                let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                                                        kCVPixelBufferMetalCompatibilityKey as String: true])
                item.add(o); output = o; frame = nil; needsDetect = true; screenPicked = false; clipURL = url
                player.replaceCurrentItem(with: item)
                if let i = args.firstIndex(of: "--time"), i + 1 < args.count, let t = Double(args[i + 1]) { seek(t) }
                if play { player.play() }
                window.title = url.lastPathComponent
                emptyState.isHidden = true
                updateExportSpecs()
            } catch { exportLabel.stringValue = "Could not open: \(error.localizedDescription)" }
        }
    }
    func togglePlay() {
        guard output != nil else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
        transport.setPlaying(player.rate != 0); syncBackground()
    }
    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func step(_ n: Int) { player.pause(); player.currentItem?.step(byCount: n); syncBackground() }

    // MARK: Key

    func setPicking(_ on: Bool) {
        if on && wbPicking { setWBPicking(false) }
        guard on != picking else { return }
        picking = on; pickButton.state = on ? .on : .off
        pickButton.title = on ? "Click the screen in the video" : "Pick Screen Color"
        if on { NSCursor.crosshair.push() } else { NSCursor.pop() }
        updateHandles()
    }
    func updateScreenCard() {
        let c = settings.screen
        let color = NSColor(cgColor: CGColor(colorSpace: r.linear, components: [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), 1])!)!
        let kind = settings.isBlueScreen ? "Blue screen" : "Green screen"
        screenCard.set(color: color, detail: frame == nil ? "Open a video to detect it"
                       : "\(kind) · " + (screenPicked ? "picked from the video" : "detected automatically"))
    }
    func resetKey() {
        if let f = frame, let c = r.detectScreen(f) { settings.screen = c; screenPicked = false }
        applyScreenDefaults(); updateScreenCard()
    }
    func clicked(_ p: CGPoint) {
        if wbPicking { pickWhite(p); return }
        guard picking, let f = frame else { return }
        let s = window.backingScaleFactor
        var q = CGPoint(x: p.x * s, y: p.y * s).applying(fit.inverted())
        // Key and Matte show you moved and resized; find the matching spot in the original footage.
        if mode != .original { q = q.applying(placement.transform(for: f.extent).inverted()) }
        if let c = r.average(f, rect: CGRect(x: q.x - 6, y: q.y - 6, width: 12, height: 12)) {
            let wasBlue = settings.isBlueScreen
            settings.screen = c; screenPicked = true
            if settings.isBlueScreen != wasBlue { applyScreenDefaults() }   // picked a different kind of screen
            updateScreenCard()
        }
        setPicking(false)
    }

    // MARK: Background

    func syncBackground() { background?.follow(time: player.currentTime().seconds, playing: player.rate != 0) }
    func chooseBackground() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.image, .movie]; p.message = "Choose a background image or video"
        guard p.runModal() == .OK, let u = p.url else { viewBar.setBackdrop(backdrop); return }
        loadBackground(u)
    }
    func loadBackground(_ u: URL) {
        Task { @MainActor in
            do {
                let b = try await BackgroundPreview(url: u)
                background = b; syncBackground()
                bgLabel.stringValue = u.lastPathComponent + (b.isVideo ? " · video, loops" : " · image")
                backdrop = .custom; dirty = true
            } catch {
                bgLabel.stringValue = "Could not use that file: \(error.localizedDescription)"
                viewBar.setBackdrop(backdrop)
            }
        }
    }

    // MARK: Export

    func updateExportSpecs() {
        guard clipURL != nil else { exportSpecs.stringValue = "Open a video first"; return }
        let transparent = exportKind.indexOfSelectedItem == 1
        exportSpecs.stringValue = String(format: "%d × %d · %.3g fps\n%@", Int(videoSize.width), Int(videoSize.height), fps,
                                         transparent ? "ProRes 4444 with transparency · .mov" : "HEVC · .mp4 · ready to upload")
    }
    func export() {
        guard let clip = clipURL else { exportLabel.stringValue = "Open a video first"; return }
        let transparent = exportKind.indexOfSelectedItem == 1
        let p = NSSavePanel()
        p.allowedContentTypes = [transparent ? .quickTimeMovie : .mpeg4Movie]
        p.nameFieldStringValue = clip.deletingPathExtension().lastPathComponent + (transparent ? " keyed.mov" : " keyed.mp4")
        guard p.runModal() == .OK, let out = p.url else { return }
        startExport(to: out, transparent: transparent, reveal: true)
    }

    /// What the last export did, for the MCP status (main thread only).
    var exportStatus: [String: Any] = [:]
    var exportFraction = 0.0

    /// Starts an export of the current clip with every current setting. Returns false if one is already running.
    @discardableResult
    func startExport(to out: URL, transparent: Bool, reveal: Bool) -> Bool {
        guard let clip = clipURL, exporter == nil else { return false }
        exportKind.selectItem(at: transparent ? 1 : 0); updateExportSpecs()
        let job = ExportJob(clip: clip, output: out, kind: transparent ? .transparent : .withBackground, settings: settings,
                            backdrop: backdrop, background: background?.url, blur: bgBlur, placement: placement,
                            look: look.isNeutral ? nil : look, blend: blend)
        let ex = Exporter(); exporter = ex
        exportFraction = 0
        exportStatus = ["running": true, "output": out.path, "kind": transparent ? "transparent" : "mp4"]
        player.pause(); syncBackground()
        tabs.select(.export); show(.export)
        exportButton.isEnabled = false; cancelButton.isHidden = false; exportProgress.isHidden = false
        exportProgress.doubleValue = 0; exportLabel.stringValue = "Exporting…"
        let start = CACurrentMediaTime(), rr = r
        Task.detached {
            do {
                try await ex.run(job, renderer: rr) { f in DispatchQueue.main.async { self.exportProgress.doubleValue = f; self.exportFraction = f } }
                await MainActor.run {
                    let secs = CACurrentMediaTime() - start
                    self.exportLabel.stringValue = String(format: "Saved in %.0f s", secs)
                    self.exportStatus.merge(["running": false, "result": "saved", "seconds": (secs * 10).rounded() / 10]) { $1 }
                    if reveal { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                }
            } catch is CancellationError {
                await MainActor.run { self.exportLabel.stringValue = "Export cancelled"
                    self.exportStatus.merge(["running": false, "result": "cancelled"]) { $1 } }
            } catch {
                await MainActor.run { self.exportLabel.stringValue = "Export failed: \(error.localizedDescription)"
                    self.exportStatus.merge(["running": false, "result": "failed", "error": error.localizedDescription]) { $1 } }
            }
            await MainActor.run {
                self.exportButton.isEnabled = true; self.cancelButton.isHidden = true; self.exportProgress.isHidden = true; self.exporter = nil
            }
        }
        return true
    }

    // MARK: Speed

    func updateStats() {
        guard output != nil else { return }
        let n = videoFrames; videoFrames = 0; let times = gpuTimes; gpuTimes = []
        guard player.rate != 0, !times.isEmpty else { transport.status.stringValue = ""; return }
        let avg = times.reduce(0, +) / Double(times.count), budget = 1000 / fps
        let ok = avg < budget && Double(n) >= fps * 0.9
        transport.status.stringValue = String(format: "%d/%.0f fps · %.0f ms", n, fps.rounded(), avg)
        transport.status.textColor = ok ? NSColor.systemGreen.withAlphaComponent(0.85) : .systemOrange
        perfLabel.stringValue = String(format: "Preview: %d of %.3g frames a second\nRender: %.1f ms per frame (limit %.0f ms)\n%@",
                                       n, fps, avg, budget, ok ? "Keeping up" : "Falling behind")
    }
    func fullSizeTest() {
        guard let f = frame else { fullLabel.stringValue = "Open a video first"; return }
        fullLabel.stringValue = "Testing…"; let s = settings, b = backdrop, rr = r, rate = fps
        let bg = background?.current, blur = bgBlur, place = placement, look: Look? = self.look.isNeutral ? nil : self.look, bl = blend
        DispatchQueue.global(qos: .userInitiated).async {
            guard let t = rr.makeTarget(width: Int(f.extent.width), height: Int(f.extent.height)) else { return }
            let im = rr.compose(f, settings: s, mode: .key, backdrop: b, custom: bg, blur: blur, placement: place, look: look, blend: bl)
            let v = (0..<30).map { _ in rr.timedRender(im, to: t, bounds: f.extent) }
            let avg = v.reduce(0, +) / 30
            DispatchQueue.main.async {
                self.fullLabel.stringValue = String(format: "Full size: %.1f ms per frame, worst %.1f ms (limit %.0f ms)", avg, v.max() ?? 0, 1000 / rate)
            }
        }
    }

    // MARK: Drawing

    func mtkView(_ v: MTKView, drawableSizeWillChange s: CGSize) { dirty = true }
    func draw(in v: MTKView) {
        if let o = output {
            let t = o.itemTime(forHostTime: CACurrentMediaTime())
            if o.hasNewPixelBuffer(forItemTime: t), let pb = o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                frame = upright(pb, orientation); dirty = true; videoFrames += 1
                if needsDetect {
                    needsDetect = false
                    if let c = r.detectScreen(frame!) { settings.screen = c }
                    applyScreenDefaults(); updateScreenCard()
                }
            }
        }
        if background?.poll() == true && backdrop == .custom { dirty = true }
        guard dirty, let f = frame, let d = v.currentDrawable, let cb = r.queue.makeCommandBuffer() else { return }
        dirty = false
        let W = CGFloat(d.texture.width), H = CGFloat(d.texture.height)
        let k = min(W / f.extent.width, H / f.extent.height)
        fit = CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: (W - f.extent.width * k) / 2, y: (H - f.extent.height * k) / 2))
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        let out = r.compose(f, settings: settings, mode: mode, backdrop: backdrop, custom: background?.current, blur: bgBlur,
                            placement: placement, look: shownLook, split: split, blend: blend).transformed(by: fit)
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        updateHandles()
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
