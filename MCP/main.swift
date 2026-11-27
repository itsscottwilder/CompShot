// compshot-mcp — the MCP server that AI apps start to drive CompShot (version 0.8).
//
// It speaks MCP (JSON-RPC 2.0 over stdin/stdout, the standard every MCP client uses: the Claude
// desktop app, Claude Code, Cursor, ChatGPT desktop, VS Code and others) and passes each tool call
// to the running CompShot app over its private local socket (see App/ControlServer.swift).
// If the app isn't running, it opens it. Nothing goes over the network.
//
//   compshot-mcp            run as an MCP server (what an AI app does)
//   compshot-mcp --install  add CompShot to the Claude desktop app's settings (build.sh does this)
//   compshot-mcp --test     check that the app answers (opens it if needed) and print its status

import Foundation

let serverVersion = "0.8.0"
let bundleID = "local.compshot"
let supportPath = NSHomeDirectory() + "/Library/Application Support/CompShot"
let socketPath = supportPath + "/mcp.sock"

struct HelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func logLine(_ s: String) { FileHandle.standardError.write(Data(("compshot-mcp: " + s + "\n").utf8)) }

// MARK: - Talking to the app

enum App {
    static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) } }
        guard ok == 0 else { close(fd); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 120, tv_usec: 0)     // the app's own waits are 45 s at most
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Opens the copy of the app that ran last (it writes its path at launch), or finds it by bundle ID.
    static func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let recorded = (try? String(contentsOfFile: supportPath + "/app-path", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = recorded, !path.isEmpty, FileManager.default.fileExists(atPath: path) { p.arguments = [path] }
        else { p.arguments = ["-b", bundleID] }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { logLine("couldn't open the app: \(error)") }
    }

    static func connectOrLaunch() throws -> Int32 {
        if let fd = connect() { return fd }
        logLine("CompShot isn't running; opening it")
        launch()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            usleep(250_000)
            if let fd = connect() { return fd }
        }
        throw HelperError("CompShot didn't open (or it's a version before 0.7). Open it once from Finder, then try again.")
    }

    static func call(_ command: String, _ args: [String: Any]) throws -> Any {
        let fd = try connectOrLaunch()
        defer { close(fd) }
        let request: [String: Any] = ["id": 1, "command": command, "args": args]
        guard JSONSerialization.isValidJSONObject(request) else { throw HelperError("Those arguments aren't valid JSON.") }
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        let sent = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var p = raw.baseAddress else { return false }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                p = p.advanced(by: n); left -= n
            }
            return true
        }
        guard sent else { throw HelperError("Couldn't reach CompShot.") }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while reply.firstIndex(of: 0x0A) == nil {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                throw HelperError("CompShot didn't answer for 2 minutes. A dialog may be open in the app; ask the user to check it.")
            }
            if n <= 0 { throw HelperError("CompShot closed the connection (did it quit?).") }
            reply.append(contentsOf: chunk[0..<n])
        }
        let line = reply.prefix(upTo: reply.firstIndex(of: 0x0A)!)
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { throw HelperError("CompShot sent an answer that isn't JSON.") }
        if object["ok"] as? Bool == true { return object["result"] ?? NSNull() }
        throw HelperError(object["error"] as? String ?? "CompShot reported an error.")
    }
}

// MARK: - Tools

func prop(_ type: Any, _ description: String) -> [String: Any] { ["type": type, "description": description] }

let tools: [[String: Any]] = [
    [
        "name": "status",
        "description": "What CompShot has open: the clip (size, fps, length), playhead, page and view, the screen color (green or blue, detected or picked), every key setting with the defaults for this kind of screen, the background, the size and position, the Visual Design grade (white balance, LUTs, levels, color sliders; set by the user on the Visual Design page), and any export (with progress). Opens the app if it isn't running. Pass wait (up to 45 s) to wait for a running export to finish.",
        "inputSchema": ["type": "object", "properties": [
            "wait": prop("number", "Seconds to wait for a running export to finish (0–45). Leave out to answer right away.")
        ]],
        "annotations": ["readOnlyHint": true]
    ],
    [
        "name": "open_video",
        "description": "Opens a green or blue screen video (paused at the start). The screen color is detected and the right defaults for green or blue are loaded. Answers with the status. Next, look at it with snapshot.",
        "inputSchema": ["type": "object", "properties": [
            "path": prop("string", "The video file. ~ is allowed.")
        ], "required": ["path"]]
    ],
    [
        "name": "snapshot",
        "description": "Pictures of one frame with the current settings, plus measures of the key on that frame (removed, solid and see-through share; screen still showing; screen tint left on the person). Views: key (the finished picture: the person on the backdrop, moved, resized and graded as set; Final in the app), matte (white = kept, black = removed, grey = see-through), split (matte left of the split line, final right of it, as the app shows) and original (the footage). Ask for views [\"key\", \"matte\"] to judge a key; checker as the backdrop makes leftover screen and fringes easy to see. crop zooms into part of the frame, e.g. the hair, at full detail. Changes nothing.",
        "inputSchema": ["type": "object", "properties": [
            "at": prop("number", "Seconds from the start of the clip. Default: the playhead."),
            "views": ["type": "array", "items": ["type": "string", "enum": ["key", "matte", "split", "original"]], "description": "One to three views, one image each. Default: the view the app shows."],
            "backdrop": ["type": "string", "enum": ["blue", "checker", "background"], "description": "Behind the person in the key view. Default: what the app shows."],
            "crop": ["type": "array", "items": ["type": "number"], "description": "[x, y, width, height] as fractions of the frame (y from the top), e.g. [0.35, 0.05, 0.3, 0.3] for the top of the head."],
            "maxWidth": prop("number", "Image width in pixels, 320–1920 (default 1280)."),
            "measure": prop("boolean", "Include the key measures (default true).")
        ]],
        "annotations": ["readOnlyHint": true]
    ],
    [
        "name": "set_key",
        "description": "Changes the key (the Key and Compose page). Only what you pass changes. strength 0.5–2.5 (how firmly the screen is removed; raise if screen or floor still shows, lower if hair thins), softness 0.05–1 (lower makes nearly solid areas fully solid, e.g. a shirt tinted by the screen; higher keeps soft edges and motion blur), spill 0–1 (removes screen light reflected on hair and skin), spillFirmness 0–1 (also removes the tint in hair; lower if clothing near the screen color looks off). shrink 0–3 px (pulls the edge in to remove an outline), smooth 0–3 px (softens jagged edges from compressed video; leave both 0 for clean 4K), edgeColor 0–1 (see-through edges borrow color from the person, removing fringes), edgeClean 0–6 px (recolors a band this wide just inside the edge with color from further inside the person, keeping brightness; removes a green or khaki outline baked into solid edge pixels by compressed video, which spill and edgeColor cannot reach; try 2–3), correction 0–1 (follows wrinkles and shadows on the screen), maskLeft/maskRight/maskTop/maskBottom 0–0.5 (crop out lights, stands and walls beyond the screen, as a share of the frame; the user drags them as the sides of the box on the video). Blend, to make the person sit in the background instead of looking pasted on (only the person is affected): lightWrap 0–1 (the background's light spills over the edges; the main fix for a cut-out look), wrapWidth 2–40 px (how far in it reaches, default 12), diffusion 0–1 (mist-filter glow from the highlights and softer fine contrast, to match a dreamy or soft background), soften 0–2 px (light blur for over-sharpened footage; small amounts). screen: \"auto\" to detect again, a point {x, y} on clean screen in the frame under the playhead (fractions, y from the top), or a color \"#RRGGBB\". reset: true puts everything back to the defaults for this kind of screen. Check the result with snapshot.",
        "inputSchema": ["type": "object", "properties": [
            "strength": prop("number", "0.5–2.5"), "softness": prop("number", "0.05–1"),
            "spill": prop("number", "0–1"), "spillFirmness": prop("number", "0–1"),
            "shrink": prop("number", "0–3 px"), "smooth": prop("number", "0–3 px"),
            "edgeColor": prop("number", "0–1"), "edgeClean": prop("number", "0–6 px"), "correction": prop("number", "0–1"),
            "maskLeft": prop("number", "0–0.5"), "maskRight": prop("number", "0–0.5"),
            "maskTop": prop("number", "0–0.5"), "maskBottom": prop("number", "0–0.5"),
            "lightWrap": prop("number", "0–1"), "wrapWidth": prop("number", "2–40 px"), "diffusion": prop("number", "0–1"), "soften": prop("number", "0–2 px"),
            "screen": prop(["string", "object"], "\"auto\", {\"x\": 0.1, \"y\": 0.2}, or \"#3ECC46\"."),
            "reset": prop("boolean", "Back to the defaults first (applied before the other values you pass).")
        ]]
    ],
    [
        "name": "set_background",
        "description": "Chooses what is behind the person. path: an image or video file (videos are muted and loop in time with the clip). backdrop: blue or checker (test backdrops for checking the key), or background (the chosen image or video). blur 0–20 softens the background so it looks out of focus. Shows the Key and Compose page.",
        "inputSchema": ["type": "object", "properties": [
            "path": prop("string", "An image or video file. ~ is allowed. Choosing one also selects it as the backdrop."),
            "backdrop": ["type": "string", "enum": ["blue", "checker", "background"]],
            "blur": prop("number", "0–20 (pixels at 1080p).")
        ]]
    ],
    [
        "name": "set_placement",
        "description": "Moves and resizes the keyed person in the frame (the frame size stays the same). scale 0.25–3 (1 = as filmed). x, y: −1 to 1, as a share of the frame width and height, y down (0, 0 = centred). bottom: true then sets y so the bottom of the kept area sits on the bottom edge of the frame (good when making the person smaller). reset: true = full size, centred. Applies to every page and to the export.",
        "inputSchema": ["type": "object", "properties": [
            "scale": prop("number", "0.25–3"), "x": prop("number", "−1 to 1, + = right"), "y": prop("number", "−1 to 1, + = down"),
            "bottom": prop("boolean", "Sit the person on the bottom edge (after scale and x)."),
            "reset": prop("boolean", "Full size, centred (applied before the other values).")
        ]]
    ],
    [
        "name": "set_visual",
        "description": "Sets the Visual Design grade (the Visual Design page; also shown on Key and Compose and in the export). Only what you pass changes. grades: person (only the keyed person, to match them to the background; the default) or wholePicture. Sliders −100…100 (0 = untouched): exposure (±1 stop), saturation, vibrance, color (− cooler/blue, + warmer/yellow), tint (− green, + magenta), highlights (− recover, + brighten), shadows (− deepen, + lift); sharpen and denoise 0–100. Levels: blackPoint and whitePoint 0–1. reset: true sets every slider and Levels back to neutral first (LUTs and Curves stay). LUTs and Curves are set by the user in the app. Check with snapshot.",
        "inputSchema": ["type": "object", "properties": [
            "grades": ["type": "string", "enum": ["person", "wholePicture"]],
            "exposure": prop("number", "−100…100"), "saturation": prop("number", "−100…100"), "vibrance": prop("number", "−100…100"),
            "color": prop("number", "−100…100"), "tint": prop("number", "−100…100"),
            "highlights": prop("number", "−100…100"), "shadows": prop("number", "−100…100"),
            "sharpen": prop("number", "0–100"), "denoise": prop("number", "0–100"),
            "blackPoint": prop("number", "0–1"), "whitePoint": prop("number", "0–1"),
            "reset": prop("boolean", "Neutral first (applied before the other values).")
        ]]
    ],
    [
        "name": "set_view",
        "description": "Changes what the user sees in the app: page (key = Key and Compose, design = Visual Design, export) and view (key = Final, matte, split = matte and final side by side, original). Useful to show the user what you're talking about.",
        "inputSchema": ["type": "object", "properties": [
            "page": ["type": "string", "enum": ["key", "design", "export"]],
            "view": ["type": "string", "enum": ["key", "matte", "split", "original"]]
        ]]
    ],
    [
        "name": "seek",
        "description": "Moves the playhead (and pauses) so the user sees that moment. play: true plays from there.",
        "inputSchema": ["type": "object", "properties": [
            "to": prop("number", "Seconds from the start of the clip."),
            "play": prop("boolean", "Start playing from there.")
        ], "required": ["to"]]
    ],
    [
        "name": "export",
        "description": "Exports the whole clip with every current setting (key, edges, mask, background, size and position); audio is copied as is. kind mp4 = with the background, HEVC, ready to upload; kind transparent = only the person, ProRes 4444 .mov with transparency for DaVinci Resolve or Final Cut (large files). The extension is fixed to match. Refuses to replace an existing file unless overwrite: true (ask the user first). Waits up to 45 s; if it isn't done, call status with wait: 45 until export.running is false. Only export when the user asks.",
        "inputSchema": ["type": "object", "properties": [
            "path": prop("string", "Where to save, e.g. ~/Movies/talk keyed.mp4."),
            "kind": ["type": "string", "enum": ["mp4", "transparent"], "description": "Default: from the extension (.mov = transparent)."],
            "overwrite": prop("boolean", "Replace an existing file (only after the user agrees)."),
            "reveal": prop("boolean", "Show the file in Finder when done (default false)."),
            "wait": prop("number", "Seconds to wait for it to finish, 0–45 (default 45).")
        ], "required": ["path"]]
    ],
    [
        "name": "cancel_export",
        "description": "Stops the running export and deletes its unfinished file.",
        "inputSchema": ["type": "object", "properties": [String: Any]()]
    ],
]

let instructions = """
CompShot is a Mac app that removes a green or blue screen from a talking-head video and puts the person on any background, in real time. You drive it with these tools; the app's window follows along, so the user sees each change.

A good order: 1 open_video. 2 snapshot with views ["key", "matte"] and backdrop checker, at a few moments (start, middle, a moment with movement). 3 Read the measures and look at the images: screen still showing, holes or see-through areas on the person, colored fringes, a tinted look. Use crop to look closely at hair and edges. 4 Fix with set_key, one or two settings at a time, and check again with snapshot. Masks remove lights and stands beyond the screen. 5 set_background and set_placement for the final look, then show the user a snapshot of the key view. 6 Export only when the user asks, and confirm the file name.

Explain changes in plain words (what you saw, what you changed, why). The defaults are tuned for clean footage: change only what a snapshot shows is wrong. Times are seconds from the start of the clip. If a tool says a dialog is open in the app, ask the user to close it.
"""

// MARK: - MCP (JSON-RPC 2.0 over stdio)

final class Output {
    static let shared = Output()
    private let lock = NSLock()
    func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else {
            logLine("couldn't encode a message"); return
        }
        data.append(0x0A)
        lock.lock(); FileHandle.standardOutput.write(data); lock.unlock()
    }
}

func reply(_ id: Any, result: [String: Any]) { Output.shared.send(["jsonrpc": "2.0", "id": id, "result": result]) }
func replyError(_ id: Any, code: Int, _ message: String) {
    Output.shared.send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]])
}

/// Compact JSON with sorted keys and numbers written short (0.8, not 0.80000000000000004).
func jsonText(_ v: Any) -> String {
    switch v {
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        let d = n.doubleValue
        guard d.isFinite else { return "null" }
        return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : "\(d)"
    case let s as String:
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    case let a as [Any]: return "[" + a.map(jsonText).joined(separator: ",") + "]"
    case let d as [String: Any]: return "{" + d.keys.sorted().map { jsonText($0) + ":" + jsonText(d[$0]!) }.joined(separator: ",") + "}"
    case is NSNull: return "null"
    default: return jsonText("\(v)")
    }
}

/// The app's answer as MCP content: the JSON as text, and any pictures as images.
func toolContent(_ value: Any) -> [[String: Any]] {
    var images: [[String: Any]] = []
    var rest = value
    if var dict = value as? [String: Any], let list = dict["images"] as? [[String: Any]] {
        images = list
        dict["images"] = list.map { var m = $0; m.removeValue(forKey: "data"); m["attached"] = true; return m }
        rest = dict
    }
    var content: [[String: Any]] = [["type": "text", "text": jsonText(rest)]]
    for image in images {
        if let data = image["data"] as? String {
            content.append(["type": "image", "data": data, "mimeType": image["mimeType"] as? String ?? "image/jpeg"])
        }
    }
    return content
}

func callTool(_ id: Any, _ params: [String: Any]) {
    let name = params["name"] as? String ?? ""
    let args = params["arguments"] as? [String: Any] ?? [:]
    guard tools.contains(where: { $0["name"] as? String == name }) else { replyError(id, code: -32602, "Unknown tool: \(name)"); return }
    do {
        let value = try App.call(name, args)
        reply(id, result: ["content": toolContent(value), "isError": false])
    } catch {
        reply(id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
    }
}

func handle(_ message: [String: Any]) {
    guard let method = message["method"] as? String else { return }
    let params = message["params"] as? [String: Any] ?? [:]
    if method.hasPrefix("notifications/") { return }
    guard let id = message["id"] else { return }
    switch method {
    case "initialize":
        let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
        let asked = params["protocolVersion"] as? String ?? ""
        reply(id, result: [
            "protocolVersion": supported.contains(asked) ? asked : supported[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "compshot", "title": "CompShot", "version": serverVersion],
            "instructions": instructions
        ])
    case "ping": reply(id, result: [:])
    case "tools/list": reply(id, result: ["tools": tools])
    case "tools/call": DispatchQueue.global(qos: .userInitiated).async { callTool(id, params) }
    default: replyError(id, code: -32601, "Method not found: \(method)")
    }
}

// MARK: - --install and --test

func install() {
    let fm = FileManager.default
    let helper = supportPath + "/compshot-mcp"
    let claudeFolder = NSHomeDirectory() + "/Library/Application Support/Claude"
    let config = claudeFolder + "/claude_desktop_config.json"
    guard fm.fileExists(atPath: claudeFolder) else {
        print("The Claude desktop app isn't installed, so it wasn't set up. Other AI apps: point them at \(helper)")
        return
    }
    var settings: [String: Any] = [:]
    if let data = fm.contents(atPath: config), !data.isEmpty {
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("Couldn't read \(config) (it isn't valid JSON), so it was left alone.")
            print("Add this to it by hand:  \"compshot\": { \"command\": \"\(helper)\" }  inside \"mcpServers\".")
            return
        }
        settings = parsed
    }
    var servers = settings["mcpServers"] as? [String: Any] ?? [:]
    if let existing = servers["compshot"] as? [String: Any], existing["command"] as? String == helper {
        print("Claude desktop is already set up for CompShot.")
        return
    }
    if fm.fileExists(atPath: config) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.copyItem(atPath: config, toPath: config + ".backup-" + stamp)
    }
    servers["compshot"] = ["command": helper]
    settings["mcpServers"] = servers
    do {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: config), options: .atomic)
        print("Added CompShot to the Claude desktop app. Quit Claude (⌘Q) and open it again to connect.")
    } catch {
        print("Couldn't update \(config): \(error.localizedDescription)")
    }
}

func test() {
    do {
        let status = try App.call("status", [:])
        let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print("CompShot answered:")
        print(String(data: data, encoding: .utf8) ?? "")
    } catch {
        print("Test failed: \(error.localizedDescription)")
        exit(1)
    }
}

// MARK: - Main

signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("--install") { install(); exit(0) }
if arguments.contains("--test") { test(); exit(0) }
if arguments.contains("--version") { print("compshot-mcp \(serverVersion)"); exit(0) }

logLine("ready (version \(serverVersion))")
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    guard let data = trimmed.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) else {
        replyError(NSNull(), code: -32700, "Parse error"); continue
    }
    if let message = parsed as? [String: Any] { handle(message) }
    else if let batch = parsed as? [[String: Any]] { batch.forEach(handle) }
}
Thread.sleep(forTimeInterval: 0.5)
exit(0)
