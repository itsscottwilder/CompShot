// VisualDesignPanel — 1Shot's Visual Design panel, brought into CompShot (0.8):
// White Balance (eyedropper, Color, Tint), Camera LUT, Creative LUT, Levels histogram, Curves, Color sliders.
// Left out from 1Shot: Visual Design groups (CompShot has one clip), Stabilize and Fade to black.
// Added: "Grade" — just the keyed person (to match them to the background) or the whole picture.

import AppKit

final class VisualDesignPanel: NSVisualEffectView {
    var onGradeChanged: ((ColorGrade.Settings) -> Void)?
    var onEyedropper: (() -> Void)?
    var onBypassChanged: ((Bool) -> Void)?
    var onTargetChanged: ((Bool) -> Void)?          // true = whole picture
    enum LUTSlot: Int { case camera = 0, creative = 1 }
    var onLUTSelected: ((LUTSlot, URL?) -> Void)?    // nil = no LUT
    var onLoadLUT: ((LUTSlot) -> Void)?

    private let eyedropperButton = NSButton()
    private let wbNote = NSTextField(wrappingLabelWithString: "")
    private let bypassButton = NSButton()
    private let target = NSSegmentedControl(labels: ["You", "Whole Picture"], trackingMode: .selectOne, target: nil, action: nil)
    private let levels = LevelsView()
    private let curvesView = CurvesView()
    private let curvesLabel = ClickableLabel(labelWithString: "Curves")
    private let curveChannel = NSSegmentedControl(labels: ["RGB", "Red", "Green", "Blue"], trackingMode: .selectOne, target: nil, action: nil)
    private var curvesBypassed = false
    private let lutPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let creativePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var sliders: [NSSlider] = []
    private var valueLabels: [NSTextField] = []
    private var nameLabels: [NSTextField] = []
    private var bypassedRows: Set<Int> = []
    private var selectedLUTs: [LUTSlot: URL] = [:]

    static let rows: [(title: String, help: String, key: WritableKeyPath<ColorGrade.Settings, Double>, min: Double)] = [
        ("Exposure", "Overall brightness (±1 stop)", \.exposure, -100),
        ("Saturation", "− toward black & white, + more vivid", \.saturation, -100),
        ("Vibrance", "Boosts muted colors more than strong ones — gentler on skin tones", \.vibrance, -100),
        ("Color", "Color temperature: − cooler (blue), + warmer (yellow)", \.temperature, -100),
        ("Tint", "− greener, + more magenta", \.tint, -100),
        ("Highlights", "− recover detail in bright areas, + brighten them", \.highlights, -100),
        ("Shadows", "− deepen dark areas, + lift them", \.shadows, -100),
        ("Sharpen", "Crisper detail (0 = off). Small amounts go a long way.", \.sharpen, 0),
        ("Denoise", "Smooths grain from low-light footage (0 = off)", \.denoise, 0),
    ]
    static func isWB(_ i: Int) -> Bool { rows[i].key == \ColorGrade.Settings.temperature || rows[i].key == \ColorGrade.Settings.tint }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 400))
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        appearance = NSAppearance(named: .darkAqua)

        let drawerTitle = titleLabel("Visual Design")
        let drawerSubtitle = noteLabel("Picture flows top to bottom. Grade “You” to match yourself to the background.")
        target.selectedSegment = 0; target.segmentDistribution = .fillEqually; target.refusesFirstResponder = true
        target.target = self; target.action = #selector(targetChanged)
        target.toolTip = "You: only the keyed person is graded (match them to the background). Whole Picture: the finished picture, background too."

        // White balance first, because it's applied before the LUT.
        let wbTitle = titleLabel("White Balance")
        eyedropperButton.title = "White Balance"
        eyedropperButton.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "White balance eyedropper")
        eyedropperButton.imagePosition = .imageLeading; eyedropperButton.setButtonType(.pushOnPushOff)
        eyedropperButton.bezelStyle = .rounded; eyedropperButton.controlSize = .large; eyedropperButton.refusesFirstResponder = true
        eyedropperButton.toolTip = "Click, then click something in the video that should be white or gray"
        eyedropperButton.target = self; eyedropperButton.action = #selector(eyedropperClicked)
        wbNote.font = .systemFont(ofSize: 11); wbNote.textColor = .secondaryLabelColor; wbNote.isHidden = true

        let lutTitle = sectionLabel("Camera LUT"), creativeTitle = sectionLabel("Creative LUT")
        for (popup, slot) in [(lutPopup, LUTSlot.camera), (creativePopup, LUTSlot.creative)] {
            popup.tag = slot.rawValue; popup.refusesFirstResponder = true
            popup.target = self; popup.action = #selector(lutChosen(_:))
        }
        lutPopup.toolTip = "Converts your camera's log footage (e.g. Apple Log) to normal video. Applied right after white balance."
        creativePopup.toolTip = "A look or film style, applied after the Camera LUT. Shares 1Shot's LUT folder."
        rebuildLUTMenu()

        let levelsTitle = sectionLabel("Levels")
        levelsTitle.toolTip = "Drag the bottom-left triangle in to set the black point, the bottom-right one to set the white point. Double-click a handle to reset it."
        levels.heightAnchor.constraint(equalToConstant: LevelsView.height).isActive = true
        levels.onChange = { [weak self] _, _, _ in guard let self else { return }; self.onGradeChanged?(self.currentSettings) }

        curvesLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        curvesLabel.toolTip = "Click the graph to add a point, drag it to bend the curve. Drag a point off the graph or double-click it to remove it; double-click empty space to reset that curve. Click the name to bypass Curves."
        curvesLabel.onClick = { [weak self] in self?.toggleCurvesBypass() }
        let curvesHeader = headerRow(curvesLabel, [smallButton("Reset", self, #selector(resetCurvesClicked), tip: "All four curves back to straight")])
        curveChannel.selectedSegment = 0; curveChannel.segmentDistribution = .fillEqually; curveChannel.controlSize = .small
        curveChannel.refusesFirstResponder = true; curveChannel.target = self; curveChannel.action = #selector(curveChannelChanged)
        curveChannel.toolTip = "RGB bends brightness and contrast. Red, Green and Blue bend one color (e.g. lift Blue in the shadows for a cool look)."
        curvesView.heightAnchor.constraint(equalToConstant: CurvesView.height).isActive = true
        curvesView.onChange = { [weak self] _, _ in
            guard let self else { return }
            if self.curvesBypassed { self.curvesBypassed = false; self.updateCurvesBypassLook() }
            self.updateChannelLabels(); self.onGradeChanged?(self.currentSettings)
        }

        bypassButton.title = "Bypass"; bypassButton.setButtonType(.pushOnPushOff); bypassButton.bezelStyle = .rounded
        bypassButton.controlSize = .small; bypassButton.refusesFirstResponder = true
        bypassButton.toolTip = "Turns off white balance, Curves and the Color sliders (LUTs and Levels stay on). Export always includes them."
        bypassButton.target = self; bypassButton.action = #selector(bypassClicked(_:))
        let colorHeader = headerRow(titleLabel("Color"), [bypassButton, smallButton("Reset", self, #selector(resetClicked),
                                                                                  tip: "Sliders, Levels and Curves back to neutral (keeps the LUTs)")])

        var sliderRows: [NSStackView] = []
        for (i, row) in Self.rows.enumerated() {
            let label = ClickableLabel(labelWithString: row.title)
            label.font = .systemFont(ofSize: 12); label.toolTip = row.help + " · click the name to bypass just this control"
            label.widthAnchor.constraint(equalToConstant: 72).isActive = true
            label.onClick = { [weak self] in self?.toggleRowBypass(i) }
            nameLabels.append(label)
            let slider = ResetSlider(value: 0, minValue: row.min, maxValue: 100, target: self, action: #selector(sliderMoved(_:)))
            slider.tag = i; slider.isContinuous = true; slider.controlSize = .small; slider.refusesFirstResponder = true
            slider.toolTip = row.help + " · double-click to reset"
            let value = NSTextField(labelWithString: "0")
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 34).isActive = true
            sliders.append(slider); valueLabels.append(value)
            let line = NSStackView(views: [label, slider, value]); line.orientation = .horizontal; line.spacing = 6
            sliderRows.append(line)
        }
        let wbRows = sliderRows.indices.filter(Self.isWB).map { sliderRows[$0] }
        let otherRows = sliderRows.indices.filter { !Self.isWB($0) }.map { sliderRows[$0] }

        let views: [NSView] = [drawerTitle, drawerSubtitle, target, wbTitle, eyedropperButton, wbNote] + wbRows
            + [lutTitle, lutPopup, creativeTitle, creativePopup, levelsTitle, levels, curvesHeader, curveChannel, curvesView, colorHeader] + otherRows
        var spacing: [NSView: CGFloat] = [drawerSubtitle: 10, target: 20, wbTitle: 10, eyedropperButton: 10, lutTitle: 6,
                                          lutPopup: 12, creativeTitle: 6, creativePopup: 16, levelsTitle: 6, levels: 18,
                                          curvesHeader: 6, curveChannel: 6, curvesView: 20, colorHeader: 12]
        if let last = wbRows.last { spacing[last] = 20 }
        let page = panelPage(views, spacingAfter: spacing,
                             fullWidth: [drawerSubtitle, target, eyedropperButton, wbNote, lutPopup, creativePopup, levels,
                                         curvesHeader, curveChannel, curvesView, colorHeader] + sliderRows)
        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page)
        NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo: leadingAnchor), page.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     page.topAnchor.constraint(equalTo: topAnchor), page.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: LUT menus

    /// Both menus: None · your LUTs · Load LUT… · Show LUT Folder (one shared LUT library).
    func rebuildLUTMenu(select url: URL? = nil, slot: LUTSlot = .camera) {
        if let url { selectedLUTs[slot] = url }
        buildMenu(for: lutPopup, selected: selectedLUTs[.camera])
        buildMenu(for: creativePopup, selected: selectedLUTs[.creative])
    }

    private func buildMenu(for popup: NSPopUpButton, selected: URL?) {
        let menu = NSMenu()
        let none = NSMenuItem(title: "None", action: nil, keyEquivalent: ""); menu.addItem(none)
        let files = CubeLUT.libraryFiles()
        if !files.isEmpty { menu.addItem(.separator()) }
        var selectedItem = none
        for file in files {
            let item = NSMenuItem(title: file.deletingPathExtension().lastPathComponent, action: nil, keyEquivalent: "")
            item.representedObject = file; menu.addItem(item)
            if file.standardizedFileURL == selected?.standardizedFileURL { selectedItem = item }
        }
        menu.addItem(.separator())
        let load = NSMenuItem(title: "Load LUT…", action: nil, keyEquivalent: ""); load.tag = 1; menu.addItem(load)
        let reveal = NSMenuItem(title: "Show LUT Folder", action: nil, keyEquivalent: ""); reveal.tag = 2; menu.addItem(reveal)
        popup.menu = menu; popup.select(selectedItem)
    }

    func clearLUTSelection(_ slot: LUTSlot) { selectedLUTs[slot] = nil; rebuildLUTMenu() }
    func lutName(_ slot: LUTSlot) -> String? { selectedLUTs[slot]?.deletingPathExtension().lastPathComponent }

    @objc private func lutChosen(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, let slot = LUTSlot(rawValue: sender.tag) else { return }
        switch item.tag {
        case 1: rebuildLUTMenu(); onLoadLUT?(slot)
        case 2: rebuildLUTMenu(); NSWorkspace.shared.activateFileViewerSelecting([CubeLUT.libraryFolder])
        default:
            selectedLUTs[slot] = item.representedObject as? URL
            onLUTSelected?(slot, selectedLUTs[slot])
        }
    }

    // MARK: Updating from outside

    func setSettings(_ s: ColorGrade.Settings) {
        for (i, row) in Self.rows.enumerated() {
            if sliders[i].doubleValue != s[keyPath: row.key], bypassedRows.remove(i) != nil { updateRowBypassLook(i) }
            sliders[i].doubleValue = s[keyPath: row.key]
            valueLabels[i].stringValue = Self.label(s[keyPath: row.key])
        }
        levels.setPoints(black: s.blackPoint, white: s.whitePoint)
        curvesView.setCurves(s.curves)
        if curvesBypassed { curvesBypassed = false; updateCurvesBypassLook() }
        updateChannelLabels()
    }

    /// Eyedropper result: set Color and Tint, turn their bypass off, and apply.
    func applyWhiteBalance(temperature: Double, tint: Double) {
        for i in Self.rows.indices where Self.isWB(i) {
            let v = Self.rows[i].key == \ColorGrade.Settings.temperature ? temperature : tint
            sliders[i].doubleValue = v; valueLabels[i].stringValue = Self.label(v)
            if bypassedRows.remove(i) != nil { updateRowBypassLook(i) }
        }
        onGradeChanged?(currentSettings)
    }

    func setHistogram(_ bins: [Float]) { levels.setHistogram(bins); curvesView.setHistogram(bins) }
    func setEyedropperActive(_ active: Bool) {
        eyedropperButton.state = active ? .on : .off
        eyedropperButton.title = active ? "Click white or gray in the video" : "White Balance"
    }
    /// A short message under the eyedropper (nil hides it).
    func setWhiteBalanceNote(_ s: String?) { wbNote.stringValue = s ?? ""; wbNote.isHidden = s == nil }
    var wholePicture: Bool { target.selectedSegment == 1 }
    func setWholePicture(_ on: Bool) { target.selectedSegment = on ? 1 : 0 }

    var currentSettings: ColorGrade.Settings {
        var s = ColorGrade.Settings()
        for (i, row) in Self.rows.enumerated() where !bypassedRows.contains(i) { s[keyPath: row.key] = sliders[i].doubleValue.rounded() }
        s.blackPoint = levels.blackPoint; s.whitePoint = levels.whitePoint
        if !curvesBypassed { s.curves = curvesView.curves }
        return s
    }

    // MARK: Actions

    private func toggleRowBypass(_ i: Int) {
        if bypassedRows.contains(i) { bypassedRows.remove(i) } else { bypassedRows.insert(i) }
        updateRowBypassLook(i); onGradeChanged?(currentSettings)
    }
    private func updateRowBypassLook(_ i: Int) {
        let off = bypassedRows.contains(i)
        nameLabels[i].textColor = off ? .systemRed : .labelColor
        valueLabels[i].textColor = off ? .systemRed : .labelColor
    }
    @objc private func sliderMoved(_ slider: NSSlider) {
        if bypassedRows.remove(slider.tag) != nil { updateRowBypassLook(slider.tag) }
        if abs(slider.doubleValue) < 2 { slider.doubleValue = 0 }    // snap to 0 so "untouched" is easy to hit
        valueLabels[slider.tag].stringValue = Self.label(slider.doubleValue)
        onGradeChanged?(currentSettings)
    }
    @objc private func resetClicked() {
        bypassedRows.removeAll(); for i in nameLabels.indices { updateRowBypassLook(i) }
        setSettings(ColorGrade.Settings()); onGradeChanged?(currentSettings)
    }
    private func toggleCurvesBypass() {
        curvesBypassed.toggle(); updateCurvesBypassLook(); onGradeChanged?(currentSettings)
    }
    private func updateCurvesBypassLook() { curvesLabel.textColor = curvesBypassed ? .systemRed : .labelColor }
    /// A dot after a channel's name when its curve isn't straight, so you can see what you've touched.
    private func updateChannelLabels() {
        for c in Curves.Channel.allCases {
            let name = ["RGB", "Red", "Green", "Blue"][c.rawValue]
            curveChannel.setLabel(curvesView.curves[c].isIdentity ? name : name + " •", forSegment: c.rawValue)
        }
    }
    @objc private func curveChannelChanged() { curvesView.channel = Curves.Channel(rawValue: curveChannel.selectedSegment) ?? .master }
    @objc private func resetCurvesClicked() {
        curvesView.setCurves(Curves())
        if curvesBypassed { curvesBypassed = false; updateCurvesBypassLook() }
        updateChannelLabels(); onGradeChanged?(currentSettings)
    }
    @objc private func eyedropperClicked() { onEyedropper?() }
    @objc private func targetChanged() { onTargetChanged?(wholePicture) }
    @objc private func bypassClicked(_ sender: NSButton) {
        let on = sender.state == .on
        sender.contentTintColor = on ? .systemOrange : nil
        sender.title = on ? "Bypassed" : "Bypass"
        onBypassChanged?(on)
    }
    private static func label(_ v: Double) -> String { let n = Int(v.rounded()); return n > 0 ? "+\(n)" : "\(n)" }
}

/// A text label that reports clicks (used for click-to-bypass on control names).
final class ClickableLabel: NSTextField {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
