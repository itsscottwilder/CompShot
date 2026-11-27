// ControlServer — 0.7: lets any AI app drive CompShot through MCP.
//
// The app listens on a private local socket that only your Mac user account can open:
//   ~/Library/Application Support/CompShot/mcp.sock
// The small "compshot-mcp" helper (MCP/main.swift) is what an AI app starts. It speaks MCP to the AI
// and passes each tool call to this socket as one line of JSON (the same design as 1Shot):
//   → {"id": 1, "command": "status", "args": {}}
//   ← {"id": 1, "ok": true, "result": {…}}      or      {"id": 1, "ok": false, "error": "…"}
// Nothing leaves the Mac. Every command runs on the main thread, as if you'd used the controls,
// and the window switches to the page that shows what changed.

import AppKit
import AVFoundation
import CoreImage

// MARK: - The socket

final class ControlServer {
    static let shared = ControlServer()

    static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CompShot", isDirectory: true)
    }
    static var socketPath: String { supportFolder.appendingPathComponent("mcp.sock").path }

    private weak var controller: AppController?
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "CompShot.mcp.accept")

    func start(controller c: AppController) {
        controller = c
        let folder = Self.supportFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Tells the helper where this copy of the app lives, so it can open it when it isn't running.
        try? Bundle.main.bundlePath.write(to: folder.appendingPathComponent("app-path"), atomically: true, encoding: .utf8)

        let path = Self.socketPath
        unlink(path)                       // a socket left over from the last run
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("CompShot: MCP socket failed (\(errno))"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 4) == 0 else { NSLog("CompShot: MCP socket couldn't listen (\(errno))"); close(fd); return }
        chmod(path, 0o600)                 // only you
        listenFD = fd
        acceptQueue.async { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        guard listenFD >= 0 else { return }
        close(listenFD); listenFD = -1
        unlink(Self.socketPath)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let writeLock = NSLock(), pending = DispatchGroup()
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                pending.enter()
                handle(line) { reply in
                    writeLock.lock(); Self.writeAll(fd, reply); writeLock.unlock()
                    pending.leave()
                }
            }
        }
        pending.wait()
        close(fd)
    }

    private func handle(_ line: Data, reply: @escaping (Data) -> Void) {
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let command = request["command"] as? String else {
            reply(Self.encode(["id": NSNull(), "ok": false, "error": "That request wasn't valid JSON with a \"command\"."]))
            return
        }
        let id: Any = request["id"] ?? NSNull()
        let args = request["args"] as? [String: Any] ?? [:]
        DispatchQueue.main.async { [weak self] in
            guard let c = self?.controller, c.window != nil else {
                reply(Self.encode(["id": id, "ok": false, "error": "CompShot's window isn't ready yet. Try again in a moment."]))
                return
            }
            c.mcpHandle(command, args) { outcome in
                switch outcome {
                case .success(let value): reply(Self.encode(["id": id, "ok": true, "result": value]))
                case .failure(let error): reply(Self.encode(["id": id, "ok": false, "error": error.localizedDescription]))
                }
            }
        }
    }

    static func encode(_ object: [String: Any]) -> Data {
        var data: Data
        if JSONSerialization.isValidJSONObject(object),
           let d = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) {
            data = d
        } else {
            let id = (object["id"] as? NSNumber).map { "\($0)" } ?? "null"
            data = Data("{\"id\":\(id),\"ok\":false,\"error\":\"CompShot couldn't encode its answer.\"}".utf8)
        }
        data.append(0x0A)
        return data
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return }
                p = p.advanced(by: n); left -= n
            }
        }
    }
}

// MARK: - Helpers

typealias MCPOutcome = Result<Any, Error>
typealias MCPReply = (MCPOutcome) -> Void

struct MCPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum MCP {
    static let waitLimit = 45.0
    /// Rounded for JSON, written exactly as rounded (1.6, not 1.6000000000000001).
    static func r(_ x: Double, _ places: Int = 3) -> NSDecimalNumber {
        guard x.isFinite else { return 0 }
        let k = pow(10, Double(places))
        return NSDecimalNumber(string: "\((x * k).rounded() / k)")
    }
    static func r(_ x: Float, _ places: Int = 3) -> NSDecimalNumber { r(Double(x), places) }
    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    static func poll(until deadline: Date, _ condition: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        if condition() { then(true); return }
        if Date() >= deadline { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll(until: deadline, condition, then: then) }
    }
    static func path(_ v: Any?) -> URL? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
    }
    /// sRGB hex for a linear color.
    static func hex(_ c: SIMD3<Float>) -> String {
        func enc(_ v: Float) -> Int {
            let x = min(max(v, 0), 1)
            let s = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return Int((s * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", enc(c.x), enc(c.y), enc(c.z))
    }
    static func linear(hex: String) -> SIMD3<Float>? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        func dec(_ b: UInt32) -> Float {
            let x = Float(b) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return SIMD3(dec(v >> 16 & 255), dec(v >> 8 & 255), dec(v & 255))
    }
}

private let bgraReader: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                         kCVPixelBufferMetalCompatibilityKey as String: true]

/// One frame of a video at a time (seconds), upright, the same way export reads it.
func readFrame(_ url: URL, at t: Double) async throws -> CIImage {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MCPError("That file has no video.") }
    let (xf, rate) = try await track.load(.preferredTransform, .nominalFrameRate)
    let o = orientation(for: xf), half = 0.5 / Double(rate > 0 ? rate : 30)
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, t - half), preferredTimescale: 6000), duration: .positiveInfinity)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: bgraReader)
    reader.add(out)
    guard reader.startReading() else { throw reader.error ?? MCPError("Couldn't read the video.") }
    defer { reader.cancelReading() }
    var image: CIImage?
    while let s = out.copyNextSampleBuffer() {
        if let pb = CMSampleBufferGetImageBuffer(s) { image = upright(pb, o) }
        if CMSampleBufferGetPresentationTimeStamp(s).seconds >= t - half { break }
    }
    guard let image else { throw MCPError("No frame at \(MCP.r(t, 2)) s.") }
    return image
}

/// A background's frame for a clip time: the image, or the looping video's frame (as export does).
func backgroundFrame(_ url: URL, at t: Double) async throws -> CIImage {
    if isImageFile(url) {
        guard let im = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { throw MCPError("Couldn't read the background image.") }
        return im
    }
    let d = try await AVURLAsset(url: url).load(.duration).seconds
    return try await readFrame(url, at: d > 0 ? t.truncatingRemainder(dividingBy: d) : 0)
}

// MARK: - Commands

extension AppController {
    static let pageNames: [Step: String] = [.key: "key", .design: "design", .export: "export"]
    /// 0.8 merged Key, Edges and Compose; the old names still open that page.
    static let pageAliases: [String: Step] = ["edges": .key, "compose": .key, "keyandcompose": .key]
    static let viewNames: [ViewMode: String] = [.original: "original", .matte: "matte", .key: "key", .split: "split"]
    static let backdropNames: [Backdrop: String] = [.blue: "blue", .checker: "checker", .custom: "background"]

    /// Key and Edges settings by name: the slider each one moves and its range.
    static let keyControls: [(name: String, key: ReferenceWritableKeyPath<AppController, Float>, lo: Float, hi: Float, page: Step)] = [
        ("strength", \.strength, 0.5, 2.5, .key), ("softness", \.softness, 0.05, 1, .key),
        ("spill", \.spill, 0, 1, .key), ("spillFirmness", \.spillFirmness, 0, 1, .key),
        ("shrink", \.shrinkEdges, 0, 3, .key), ("smooth", \.smoothEdges, 0, 3, .key),
        ("edgeColor", \.edgeRepair, 0, 1, .key), ("edgeClean", \.edgeClean, 0, 6, .key), ("correction", \.correction, 0, 1, .key),
        ("maskLeft", \.maskLeft, 0, 0.5, .key), ("maskRight", \.maskRight, 0, 0.5, .key),
        ("maskTop", \.maskTop, 0, 0.5, .key), ("maskBottom", \.maskBottom, 0, 0.5, .key),
        ("lightWrap", \.lightWrap, 0, 1, .key), ("wrapWidth", \.wrapWidth, 2, 40, .key),
        ("diffusion", \.diffusion, 0, 1, .key), ("soften", \.soften, 0, 2, .key),
    ]

    func mcpHandle(_ command: String, _ args: [String: Any], _ done: @escaping MCPReply) {
        do {
            switch command {
            case "status":         mcpStatusCommand(args, done)
            case "open_video":     try mcpOpen(args, done)
            case "snapshot":       try mcpSnapshot(args, done)
            case "set_key":        done(.success(try mcpSetKey(args)))
            case "set_background": try mcpSetBackground(args, done)
            case "set_placement":  done(.success(try mcpSetPlacement(args)))
            case "set_view":       done(.success(try mcpSetView(args)))
            case "set_visual":     done(.success(try mcpSetVisual(args)))
            case "seek":           done(.success(try mcpSeek(args)))
            case "export":         try mcpExport(args, done)
            case "cancel_export":
                guard let ex = exporter else { throw MCPError("No export is running.") }
                ex.cancel(); done(.success(["cancelling": true]))
            default: throw MCPError("CompShot doesn't know the command “\(command)”.")
            }
        } catch { done(.failure(error)) }
    }

    func goTo(_ s: Step) { if currentStep != s { tabs.select(s); show(s) } }

    func requireClip() throws -> URL {
        guard let u = clipURL, frame != nil else { throw MCPError("No video is open. Use open_video first.") }
        return u
    }
    func requireNoExport() throws {
        if exporter != nil { throw MCPError("An export is running. Wait for it (status with wait) or cancel_export first.") }
    }

    // MARK: status

    func mcpStatus() -> [String: Any] {
        var s: [String: Any] = ["app": "CompShot",
                                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"]
        if let u = clipURL {
            s["clip"] = ["path": u.path, "name": u.lastPathComponent, "width": Int(videoSize.width), "height": Int(videoSize.height),
                         "fps": MCP.r(fps, 3), "duration": MCP.r(duration, 2)] as [String: Any]
            s["playhead"] = MCP.r(player.currentTime().seconds, 2)
            s["playing"] = player.rate != 0
        } else {
            s["clip"] = NSNull()
        }
        s["page"] = Self.pageNames[currentStep]
        s["view"] = Self.viewNames[mode]
        let k = settings
        s["screen"] = ["kind": k.isBlueScreen ? "blue" : "green", "color": MCP.hex(k.screen),
                       "linear": [MCP.r(k.screen.x), MCP.r(k.screen.y), MCP.r(k.screen.z)],
                       "source": frame == nil ? "none yet" : screenPicked ? "picked" : "detected"] as [String: Any]
        var key: [String: Any] = [:]
        for c in Self.keyControls { key[c.name] = MCP.r(self[keyPath: c.key]) }
        s["key"] = key
        let d = settings.screenDefaults
        s["defaultsForThisScreen"] = ["strength": MCP.r(d.strength), "softness": MCP.r(d.softness), "spill": MCP.r(d.spill),
                                      "spillFirmness": MCP.r(d.spillFirmness), "shrink": 0, "smooth": 0, "edgeColor": 1, "edgeClean": 0,
                                      "correction": 1, "maskLeft": 0, "maskRight": 0, "maskTop": 0, "maskBottom": 0,
                                      "lightWrap": 0, "wrapWidth": 12, "diffusion": 0, "soften": 0]
        var bg: [String: Any] = ["choice": Self.backdropNames[backdrop]!, "blur": MCP.r(bgBlur, 1)]
        if let b = background { bg["file"] = b.url.path; bg["isVideo"] = b.isVideo } else { bg["file"] = NSNull() }
        s["background"] = bg
        let g = look.settings
        var visual: [String: Any] = ["grades": look.wholePicture ? "wholePicture" : "person", "bypassed": gradeBypass,
                                     "cameraLUT": design?.lutName(.camera) ?? NSNull(), "creativeLUT": design?.lutName(.creative) ?? NSNull(),
                                     "blackPoint": MCP.r(g.blackPoint), "whitePoint": MCP.r(g.whitePoint)]
        for row in VisualDesignPanel.rows { visual[row.title.lowercased()] = g[keyPath: row.key] }
        var curves: [String: Any] = [:]
        for (c, name) in zip(Curves.Channel.allCases, ["rgb", "red", "green", "blue"]) where !g.curves[c].isIdentity {
            curves[name] = g.curves[c].points.map { [Int(($0.x * 255).rounded()), Int(($0.y * 255).rounded())] }
        }
        visual["curves"] = curves.isEmpty ? "straight" : curves as Any
        s["visualDesign"] = visual
        s["placement"] = ["scale": MCP.r(placement.scale), "x": MCP.r(placement.x), "y": MCP.r(placement.y)]
        var ex = exportStatus
        if exporter != nil { ex["running"] = true; ex["progress"] = MCP.r(exportFraction, 2) }
        s["export"] = ex.isEmpty ? NSNull() : ex
        return s
    }

    func mcpStatusCommand(_ args: [String: Any], _ done: @escaping MCPReply) {
        let wait = min(max(MCP.num(args["wait"]) ?? 0, 0), MCP.waitLimit)
        guard wait > 0, exporter != nil else { done(.success(mcpStatus())); return }
        MCP.poll(until: Date().addingTimeInterval(wait), { [unowned self] in exporter == nil }) { [unowned self] _ in
            done(.success(mcpStatus()))
        }
    }

    // MARK: open_video

    func mcpOpen(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        try requireNoExport()
        guard let u = MCP.path(args["path"]) else { throw MCPError("Give path: the green or blue screen video to open.") }
        guard FileManager.default.fileExists(atPath: u.path) else { throw MCPError("There's no file at \(u.path).") }
        goTo(.key)
        frame = nil
        open(u, play: false)
        MCP.poll(until: Date().addingTimeInterval(20), { [unowned self] in
            clipURL == u && frame != nil && !needsDetect
        }) { [unowned self] ok in
            if ok { done(.success(mcpStatus())) }
            else { done(.failure(MCPError(exportLabel.stringValue.isEmpty ? "The video didn't open in 20 s." : exportLabel.stringValue))) }
        }
    }

    // MARK: snapshot

    func mcpSnapshot(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        let clip = try requireClip()
        let t = MCP.num(args["at"]) ?? player.currentTime().seconds
        guard t >= 0, t <= duration + 0.01 else { throw MCPError("at must be between 0 and \(MCP.r(duration, 2)) s.") }
        var views: [ViewMode] = []
        for v in (args["views"] as? [String]) ?? [(args["view"] as? String) ?? Self.viewNames[mode]!] {
            guard let m = Self.viewNames.first(where: { $0.value == v.lowercased() })?.key else {
                throw MCPError("Views are original, matte, key and split (not “\(v)”).")
            }
            views.append(m)
        }
        guard !views.isEmpty, views.count <= 3 else { throw MCPError("Give one to three views.") }
        var shownBackdrop = backdrop
        if let b = args["backdrop"] as? String {
            guard let v = Self.backdropNames.first(where: { $0.value == b.lowercased() })?.key else {
                throw MCPError("backdrop is blue, checker or background.")
            }
            if v == .custom && background == nil { throw MCPError("No background image or video is chosen yet (set_background).") }
            shownBackdrop = v
        }
        var crop: CGRect?
        if let c = args["crop"] as? [Any] {
            let v = c.compactMap(MCP.num)
            guard v.count == 4, v[2] > 0.02, v[3] > 0.02, v[0] >= 0, v[1] >= 0, v[0] + v[2] <= 1.001, v[1] + v[3] <= 1.001 else {
                throw MCPError("crop is [x, y, width, height] as fractions of the frame (y from the top), e.g. [0.3, 0.1, 0.4, 0.4].")
            }
            crop = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        let maxWidth = Int(min(max(MCP.num(args["maxWidth"]) ?? 1280, 320), 1920))
        let measure = args["measure"] as? Bool ?? true
        let s = settings, place = placement, blur = bgBlur, rr = r, bgURL = background?.url
        let grade: Look? = look.isNeutral ? nil : look
        let splitAt = split, bl = blend
        let screenKind = s.isBlueScreen

        Task { @MainActor in
            do {
                let src = try await readFrame(clip, at: t)
                let bg: CIImage? = shownBackdrop == .custom && bgURL != nil ? try await backgroundFrame(bgURL!, at: t) : nil
                let result: [String: Any] = try await Task.detached {
                    var images: [[String: Any]] = []
                    for m in views {
                        var im = rr.compose(src, settings: s, mode: m, backdrop: shownBackdrop, custom: bg, blur: blur, placement: place, look: grade, split: splitAt, blend: bl)
                        let e = src.extent
                        var area = e
                        if let c = crop {
                            area = CGRect(x: e.minX + c.minX * e.width, y: e.minY + (1 - c.maxY) * e.height,
                                          width: c.width * e.width, height: c.height * e.height).integral.intersection(e)
                        }
                        im = im.cropped(to: area).transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
                        let k = min(1, CGFloat(maxWidth) / area.width)
                        if k < 1 { im = im.transformed(by: CGAffineTransform(scaleX: k, y: k)) }
                        let w = Int((area.width * k).rounded()), h = Int((area.height * k).rounded())
                        guard let cg = rr.context.createCGImage(im, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: rr.sRGB),
                              let jpg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                            throw MCPError("Couldn't draw the \(AppController.viewNames[m]!) view.")
                        }
                        images.append(["view": AppController.viewNames[m]!, "width": w, "height": h,
                                       "mimeType": "image/jpeg", "data": jpg.base64EncodedString()])
                    }
                    var out: [String: Any] = ["at": MCP.r(t, 2), "backdrop": AppController.backdropNames[shownBackdrop]!, "images": images]
                    if let c = crop { out["crop"] = [c.minX, c.minY, c.width, c.height].map { MCP.r(Double($0)) } }
                    if measure { out["measures"] = keyMeasures(rr, src, s, blueScreen: screenKind) }
                    return out
                }.value
                done(.success(result))
            } catch { done(.failure(error)) }
        }
    }

    // MARK: set_key

    func mcpSetKey(_ args: [String: Any]) throws -> Any {
        _ = try requireClip()
        try requireNoExport()
        // Check every value before changing anything, so a refused call changes nothing.
        var values: [(c: (name: String, key: ReferenceWritableKeyPath<AppController, Float>, lo: Float, hi: Float, page: Step), v: Float)] = []
        var notes: [String] = []
        for c in Self.keyControls {
            guard let raw = args[c.name] else { continue }
            guard let v = MCP.num(raw) else { throw MCPError("\(c.name) must be a number.") }
            let clamped = min(max(Float(v), c.lo), c.hi)
            if clamped != Float(v) { notes.append("\(c.name) kept to its range \(c.lo)–\(c.hi)") }
            values.append((c, clamped))
        }
        let reset = args["reset"] as? Bool == true
        func finalMask(_ name: String) -> Float {
            if let v = values.first(where: { $0.c.name == name }) { return v.v }
            return reset ? 0 : self[keyPath: Self.keyControls.first { $0.name == name }!.key]
        }
        if finalMask("maskLeft") + finalMask("maskRight") > 0.9 || finalMask("maskTop") + finalMask("maskBottom") > 0.9 {
            throw MCPError("Those masks together would leave almost nothing of the frame.")
        }
        // The screen color too: worked out (and checked) before anything changes.
        var newScreen: (color: SIMD3<Float>, picked: Bool)?
        if let screen = args["screen"] {
            if let s = screen as? String, s.lowercased() == "auto" {
                guard let f = frame, let c = r.detectScreen(f) else { throw MCPError("No green or blue screen was found in this frame.") }
                newScreen = (c, false)
            } else if let s = screen as? String {
                guard let c = MCP.linear(hex: s) else { throw MCPError("screen is \"auto\", a color like \"#3ECC46\", or a point {x, y}.") }
                newScreen = (c, true)
            } else if let p = screen as? [String: Any], let x = MCP.num(p["x"]), let y = MCP.num(p["y"]),
                      (0...1).contains(x), (0...1).contains(y), let f = frame {
                let e = f.extent, q = CGPoint(x: e.minX + x * e.width, y: e.minY + (1 - y) * e.height)
                guard let c = r.average(f, rect: CGRect(x: q.x - 6, y: q.y - 6, width: 12, height: 12)) else { throw MCPError("Couldn't read that spot.") }
                newScreen = (c, true)
            } else {
                throw MCPError("screen is \"auto\", a color like \"#3ECC46\", or a point {x, y} (fractions of the frame, y from the top) on clean screen in the frame under the playhead.")
            }
        }

        var changed: [String] = []
        if reset {
            if let f = frame, let c = r.detectScreen(f) { settings.screen = c; screenPicked = false }
            applyScreenDefaults()
            resetSliders([\.shrinkEdges, \.smoothEdges, \.edgeRepair, \.edgeClean, \.correction]); resetMask()
            blend = Blend(); refreshSliders([\.lightWrap, \.wrapWidth, \.diffusion, \.soften])
            changed.append("reset")
        }
        if let n = newScreen {
            let wasBlue = settings.isBlueScreen
            settings.screen = n.color; screenPicked = n.picked
            if settings.isBlueScreen != wasBlue { applyScreenDefaults(); changed.append("screen type changed, so its defaults were loaded") }
            changed.append("screen")
        }
        for (c, v) in values {
            self[keyPath: c.key] = v
            changed.append(c.name)
        }
        guard !changed.isEmpty else { throw MCPError("Nothing to change. Pass screen, reset, or a setting such as strength.") }
        refreshSliders(Self.keyControls.map(\.key))
        updateScreenCard()
        goTo(.key)
        var answer = mcpStatus()
        answer["changed"] = changed
        if !notes.isEmpty { answer["notes"] = notes }
        return answer
    }

    // MARK: set_background

    func mcpSetBackground(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        try requireNoExport()
        if let b = MCP.num(args["blur"]) { bgBlur = Float(min(max(b, 0), 20)); refreshSliders([\.bgBlur]) }
        func finish() {
            if let choice = args["backdrop"] as? String {
                switch choice.lowercased() {
                case "blue": backdrop = .blue
                case "checker": backdrop = .checker
                case "background", "image", "video":
                    guard background != nil else { done(.failure(MCPError("No background image or video is chosen yet: pass path."))); return }
                    backdrop = .custom
                default: done(.failure(MCPError("backdrop is blue, checker or background."))); return
                }
            }
            goTo(.key)
            done(.success(mcpStatus()))
        }
        guard let u = MCP.path(args["path"]) else {
            guard args["backdrop"] != nil || args["blur"] != nil else {
                throw MCPError("Pass path (an image or video), backdrop (blue, checker, background) or blur.")
            }
            finish(); return
        }
        guard FileManager.default.fileExists(atPath: u.path) else { throw MCPError("There's no file at \(u.path).") }
        Task { @MainActor in
            do {
                let b = try await BackgroundPreview(url: u)
                background = b; syncBackground()
                bgLabel.stringValue = u.lastPathComponent + (b.isVideo ? " · video, loops" : " · image")
                backdrop = .custom; dirty = true
                finish()
            } catch { done(.failure(MCPError("Couldn't use that file: \(error.localizedDescription)"))) }
        }
    }

    // MARK: set_placement

    func mcpSetPlacement(_ args: [String: Any]) throws -> Any {
        _ = try requireClip()
        try requireNoExport()
        var p = args["reset"] as? Bool == true ? Placement() : placement
        if let v = MCP.num(args["scale"]) { p.scale = Float(min(max(v, 0.25), 3)) }
        if let v = MCP.num(args["x"]) { p.x = Float(min(max(v, -1), 1)) }
        if let v = MCP.num(args["y"]) { p.y = Float(min(max(v, -1), 1)) }
        if let v = args["bottom"] as? Bool, v {
            // Sit the kept area on the bottom edge of the frame, at this size and left/right position.
            // The kept area's bottom is (0.5 − maskBottom) below the middle; scaled by s and moved by y, it lands at 1.
            p.y = min(max(0.5 - p.scale * (0.5 - settings.maskBottom), -1), 1)
        }
        placement = p
        refreshSliders([\.placeScale, \.placeX, \.placeY])
        goTo(.key)
        return mcpStatus()
    }

    // MARK: set_visual

    /// The Visual Design sliders by name (as status reports them), with their ranges.
    static let visualControls: [(name: String, key: WritableKeyPath<ColorGrade.Settings, Double>, lo: Double, hi: Double)] =
        VisualDesignPanel.rows.map { ($0.title.lowercased(), $0.key, $0.min, 100) }
        + [("blackPoint", \.blackPoint, 0, 0.9), ("whitePoint", \.whitePoint, 0.1, 1)]

    func mcpSetVisual(_ args: [String: Any]) throws -> Any {
        try requireNoExport()
        var s = look.settings
        if args["reset"] as? Bool == true { let curves = s.curves; s = ColorGrade.Settings(); s.curves = curves }
        var changed: [String] = []
        for c in Self.visualControls {
            guard let raw = args[c.name] else { continue }
            guard let v = MCP.num(raw) else { throw MCPError("\(c.name) must be a number.") }
            s[keyPath: c.key] = min(max(v, c.lo), c.hi); changed.append(c.name)
        }
        if s.whitePoint - s.blackPoint < 0.05 { throw MCPError("whitePoint must be above blackPoint.") }
        if let g = args["grades"] as? String {
            switch g.lowercased() {
            case "person", "you": look.wholePicture = false
            case "wholepicture", "whole", "picture": look.wholePicture = true
            default: throw MCPError("grades is person or wholePicture.")
            }
            design.setWholePicture(look.wholePicture); changed.append("grades")
        }
        if args["reset"] as? Bool == true { changed.append("reset") }
        guard !changed.isEmpty else { throw MCPError("Nothing to change. Pass a setting such as exposure, or grades.") }
        look.settings = s; design.setSettings(s)
        var answer = mcpStatus(); answer["changed"] = changed
        return answer
    }

    // MARK: set_view, seek

    func mcpSetView(_ args: [String: Any]) throws -> Any {
        if let p = args["page"] as? String {
            let name = p.lowercased().replacingOccurrences(of: " ", with: "")
            guard let s = Self.pageNames.first(where: { $0.value == name })?.key ?? Self.pageAliases[name] else { throw MCPError("page is key (Key and Compose), design or export.") }
            goTo(s)
        }
        if let v = args["view"] as? String {
            let name = v.lowercased() == "final" ? "key" : v.lowercased()
            guard let m = Self.viewNames.first(where: { $0.value == name })?.key else { throw MCPError("view is key (Final), matte, split or original.") }
            mode = m; viewBar.setMode(m)
        }
        return mcpStatus()
    }

    func mcpSeek(_ args: [String: Any]) throws -> Any {
        _ = try requireClip()
        guard let t = MCP.num(args["to"]), t >= 0 else { throw MCPError("to is seconds from the start of the clip.") }
        player.pause()
        seek(min(t, max(0, duration - 0.05)))
        if args["play"] as? Bool == true { player.play() }
        syncBackground()
        var s = mcpStatus(); s["playhead"] = MCP.r(min(t, duration), 2)
        return s
    }

    // MARK: export

    func mcpExport(_ args: [String: Any], _ done: @escaping MCPReply) throws {
        _ = try requireClip()
        try requireNoExport()
        guard var out = MCP.path(args["path"]) else { throw MCPError("Give path: where to save, e.g. ~/Movies/me keyed.mp4.") }
        let kind = (args["kind"] as? String)?.lowercased()
        let transparent: Bool
        switch kind {
        case "transparent", "prores", "mov": transparent = true
        case "mp4", "background", "withbackground": transparent = false
        case nil: transparent = out.pathExtension.lowercased() == "mov"
        default: throw MCPError("kind is mp4 (with background) or transparent (ProRes 4444 .mov).")
        }
        let ext = transparent ? "mov" : "mp4"
        if out.pathExtension.lowercased() != ext { out = out.deletingPathExtension().appendingPathExtension(ext) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path, isDirectory: &isDir), isDir.boolValue else {
            throw MCPError("The folder \(out.deletingLastPathComponent().path) doesn't exist.")
        }
        if FileManager.default.fileExists(atPath: out.path), args["overwrite"] as? Bool != true {
            throw MCPError("\(out.path) already exists. Ask the user, then pass overwrite: true, or choose another name.")
        }
        guard startExport(to: out, transparent: transparent, reveal: args["reveal"] as? Bool ?? false) else {
            throw MCPError("Couldn't start the export.")
        }
        let wait = min(max(MCP.num(args["wait"]) ?? MCP.waitLimit, 0), MCP.waitLimit)
        MCP.poll(until: Date().addingTimeInterval(wait), { [unowned self] in exporter == nil }) { [unowned self] finished in
            var s = mcpStatus()
            if !finished { s["hint"] = "Still exporting. Call status with wait: 45 until export.running is false." }
            done(.success(s))
        }
    }
}

// MARK: - Key measures (numbers an AI can judge the key by)

/// Rendered small: how much of the frame is removed, kept and see-through, and two warning signs:
/// screen that still shows through, and screen-colored tint left on the person.
func keyMeasures(_ r: Renderer, _ src: CIImage, _ s: KeySettings, blueScreen: Bool) -> [String: Any] {
    let e = src.extent, w = 480, h = max(1, Int((480 * e.height / e.width).rounded()))
    let toSmall = CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
    func pixels(_ im: CIImage) -> [Float] {
        var px = [Float](repeating: 0, count: w * h * 4)
        r.context.render(im.transformed(by: toSmall), toBitmap: &px, rowBytes: w * 16,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: r.linear)
        return px
    }
    let orig = pixels(src), fg = pixels(r.keyer.apply(to: src, settings: s))
    var clear = 0, solid = 0, partial = 0, screenLike = 0, screenShowing = 0, kept = 0, tinted = 0
    for i in stride(from: 0, to: orig.count, by: 4) {
        let a = fg[i + 3]
        if a < 0.02 { clear += 1 } else if a > 0.98 { solid += 1 } else { partial += 1 }
        let c = SIMD3(orig[i], orig[i + 1], orig[i + 2])
        let main = blueScreen ? c.z : c.y, others = blueScreen ? max(c.x, c.y) : max(c.x, c.z)
        if main > 0.04 && main > 1.5 * others { screenLike += 1; if a > 0.1 { screenShowing += 1 } }
        if a > 0.5 {
            kept += 1
            let f = SIMD3(fg[i], fg[i + 1], fg[i + 2]) / a
            let m2 = blueScreen ? f.z : f.y, o2 = blueScreen ? max(f.x, f.y) : max(f.x, f.z)
            if m2 - o2 > 0.02 { tinted += 1 }
        }
    }
    let n = Double(orig.count / 4)
    func pct(_ x: Int, of total: Double) -> NSDecimalNumber { total > 0 ? MCP.r(100 * Double(x) / total, 1) : 0 }
    return [
        "removedPercent": pct(clear, of: n), "solidPercent": pct(solid, of: n), "seeThroughPercent": pct(partial, of: n),
        "screenShowingPercent": pct(screenShowing, of: Double(screenLike)),
        "tintedPercent": pct(tinted, of: Double(kept)),
        "explain": "Measured on this frame at 480 px wide. removed/solid/seeThrough: share of the frame that is fully removed, fully kept and partly see-through (see-through should be only a thin band at edges and hair; lots of it means the person is ghosting: lower softness or raise strength). screenShowingPercent: of the pixels that look like the screen, how many are still kept (should be near 0; raise strength or correction, or mask off areas beyond the screen). tintedPercent: of the kept pixels, how many still carry a screen-colored tint (spill; raise spill or spillFirmness). These are hints, not a verdict: always look at the images too.",
    ]
}
