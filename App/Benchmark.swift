import AVFoundation
import CoreImage

/// Headless test: keys real frames at full size and reports timing.
/// usage: KeyShot --benchmark clip outDir [startSeconds] [frames]
func runBenchmark(_ a: [String]) async {
    do {
        let r = try Renderer()
        let start = a.count > 2 ? Double(a[2])! : 0, count = a.count > 3 ? Int(a[3])! : 125
        let asset = AVURLAsset(url: URL(fileURLWithPath: a[0]))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: .positiveInfinity)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.alwaysCopiesSampleData = false; reader.add(out); reader.startReading()
        var s = KeySettings(); s.maskLeft = 0.09; s.maskRight = 0.22
        func overrides(_ s: inout KeySettings) {
        if ProcessInfo.processInfo.environment["GK_PLAIN"] != nil { s.correction = 0; s.edgeRepair = 0 }
        if ProcessInfo.processInfo.environment["GK_NOEDGE"] != nil { s.edgeRepair = 0 }
        if ProcessInfo.processInfo.environment["GK_NOCORR"] != nil { s.correction = 0 }
        let env = ProcessInfo.processInfo.environment
        if let v = env["GK_SHRINK"] { s.shrink = Float(v)! }
        if let v = env["GK_SMOOTH"] { s.smooth = Float(v)! }
        if let v = env["GK_SPILL"] { s.spill = Float(v)! }
        if let v = env["GK_LEFT"] { s.maskLeft = Float(v)! }
        if let v = env["GK_RIGHT"] { s.maskRight = Float(v)! }
        if let v = ProcessInfo.processInfo.environment["GK_SOFT"] { s.softness = Float(v)! }
        if let v = ProcessInfo.processInfo.environment["GK_STR"] { s.strength = Float(v)! }
        if let f = ProcessInfo.processInfo.environment["GK_FIRM"] { s.spillFirmness = Float(f)! }
        if let b = ProcessInfo.processInfo.environment["GK_BOTTOM"] { s.maskBottom = Float(b)! }
        }
        overrides(&s)
        let bg: Backdrop = ProcessInfo.processInfo.environment["GK_BG"] == "checker" ? .checker : .blue
        var gpu = [Double](), target: MTLTexture?, i = 0
        try FileManager.default.createDirectory(atPath: a[1], withIntermediateDirectories: true)
        while i < count, let sample = out.copyNextSampleBuffer() {
            try autoreleasepool {
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
                let im = CIImage(cvPixelBuffer: pb)
                if i == 0, let c = r.detectScreen(im) {
                    s.screen = c; s.applyScreenDefaults(); overrides(&s)
                    print("screen", c, s.isBlueScreen ? "blue" : "green", "strength", s.strength, "softness", s.softness)
                }
                if target == nil { target = r.makeTarget(width: Int(im.extent.width), height: Int(im.extent.height)) }
                gpu.append(r.timedRender(r.compose(im, settings: s, mode: .key, backdrop: .blue), to: target!, bounds: im.extent))
                if [0, 13, 27].contains(i) {
                    let n = String(format: "%04d", i)
                    try r.context.writeJPEGRepresentation(of: r.compose(im, settings: s, mode: .key, backdrop: bg), to: URL(fileURLWithPath: "\(a[1])/key_\(n).jpg"), colorSpace: r.sRGB)
                    try r.context.writeJPEGRepresentation(of: im, to: URL(fileURLWithPath: "\(a[1])/src_\(n).jpg"), colorSpace: r.sRGB, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.95])
                    try r.context.writeJPEGRepresentation(of: r.compose(im, settings: s, mode: .matte, backdrop: .blue), to: URL(fileURLWithPath: "\(a[1])/matte_\(n).jpg"), colorSpace: r.sRGB)
                }
                i += 1
            }
        }
        // Throughput: decode + key + composite with up to 3 frames in flight, as playback and export do.
        let reader2 = try AVAssetReader(asset: asset)
        reader2.timeRange = reader.timeRange
        let out2 = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out2.alwaysCopiesSampleData = false; reader2.add(out2); reader2.startReading()
        let inFlight = DispatchSemaphore(value: 3), group = DispatchGroup()
        var targets: [MTLTexture] = []; var n = 0
        let t0 = CACurrentMediaTime()
        while n < count, let sample = out2.copyNextSampleBuffer() {
            autoreleasepool {
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
                let im = CIImage(cvPixelBuffer: pb)
                if targets.isEmpty { targets = (0..<3).compactMap { _ in r.makeTarget(width: Int(im.extent.width), height: Int(im.extent.height)) } }
                inFlight.wait()
                guard let cb = r.queue.makeCommandBuffer() else { return }
                let dest = CIRenderDestination(mtlTexture: targets[n % 3], commandBuffer: cb); dest.colorSpace = r.sRGB
                guard let task = try? r.context.startTask(toRender: r.compose(im, settings: s, mode: .key, backdrop: .blue), from: im.extent, to: dest, at: .zero) else { inFlight.signal(); return }
                cb.commit(); group.enter()
                DispatchQueue.global().async { _ = try? task.waitUntilCompleted(); cb.waitUntilCompleted(); _ = pb; inFlight.signal(); group.leave() }
                n += 1
            }
        }
        group.wait()
        let total = CACurrentMediaTime() - t0
        print(String(format: "throughput incl. decoding: %d frames in %.2f s = %.1f fps (%.1f ms per frame)", n, total, Double(n) / total, total * 1000 / Double(max(n, 1))))
        func avg(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(1, v.count)) }
        let sorted = gpu.sorted()
        print(String(format: "frames %d  key+composite at full size: avg %.1f ms, 95th percentile %.1f ms, worst %.1f ms", gpu.count, avg(gpu), sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last ?? 0))
    } catch { print("ERROR", error) }
}
