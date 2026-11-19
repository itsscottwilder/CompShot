import AVFoundation
import CoreImage

enum ExportKind { case withBackground, transparent }

struct ExportJob {
    var clip: URL
    var output: URL
    var kind: ExportKind
    var settings: KeySettings
    var backdrop: Backdrop
    var background: URL?
    var blur: Float
    var placement = Placement()
}

private func exportError(_ s: String) -> NSError {
    NSError(domain: "KeyShot", code: 10, userInfo: [NSLocalizedDescriptionKey: s])
}

/// Keys a whole clip and writes it out with its audio.
/// With background: HEVC in an .mp4. Transparent: ProRes 4444 with alpha in a .mov.
final class Exporter: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    func run(_ job: ExportJob, renderer r: Renderer, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: job.clip)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else { throw exportError("The clip has no video") }
        let (size, xf, rate) = try await vt.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = max(try await asset.load(.duration).seconds, 0.001)
        let o = orientation(for: xf), sideways = o == .left || o == .right
        let W = Int(sideways ? size.height : size.width), H = Int(sideways ? size.width : size.height)
        let transparent = job.kind == .transparent
        var background: BackgroundFrames?
        if job.kind == .withBackground, job.backdrop == .custom, let u = job.background {
            background = try await BackgroundFrames(url: u)
        }

        try? FileManager.default.removeItem(at: job.output)
        let writer = try AVAssetWriter(outputURL: job.output, fileType: transparent ? .mov : .mp4)
        let color: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        var vs: [String: Any] = [AVVideoWidthKey: W, AVVideoHeightKey: H, AVVideoColorPropertiesKey: color]
        if transparent {
            vs[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        } else {
            vs[AVVideoCodecKey] = AVVideoCodecType.hevc
            let bitrate = max(8_000_000, Int(Double(W * H) * Double(rate > 0 ? rate : 30) * 0.15))
            vs[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: bitrate]
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        writer.add(vIn)

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.alwaysCopiesSampleData = false; reader.add(vOut)

        // Audio is copied as-is, without re-encoding.
        var aIn: AVAssetWriterInput?, aOut: AVAssetReaderTrackOutput?
        if let at = try await asset.loadTracks(withMediaType: .audio).first {
            let hint = try await at.load(.formatDescriptions).first
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            let ro = AVAssetReaderTrackOutput(track: at, outputSettings: nil)
            i.expectsMediaDataInRealTime = false; ro.alwaysCopiesSampleData = false
            if writer.canAdd(i), reader.canAdd(ro) { writer.add(i); reader.add(ro); aIn = i; aOut = ro }
        }

        guard reader.startReading() else { throw reader.error ?? exportError("Could not read the clip") }
        guard writer.startWriting() else { throw writer.error ?? exportError("Could not write the file") }
        writer.startSession(atSourceTime: .zero)

        let rec709 = CGColorSpace(name: CGColorSpace.itur_709)!
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        let group = DispatchGroup()
        final class Once { var done = false }

        group.enter()
        let vDone = Once()
        vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "export.video")) { [self] in
            while vIn.isReadyForMoreMediaData && !vDone.done {
                guard !cancelled, let s = vOut.copyNextSampleBuffer(), let src = CMSampleBufferGetImageBuffer(s) else {
                    vIn.markAsFinished(); vDone.done = true; group.leave(); return
                }
                autoreleasepool {
                    let pts = CMSampleBufferGetPresentationTimeStamp(s)
                    let im = upright(src, o)
                    let out = transparent
                        ? r.place(r.keyer.apply(to: im, settings: job.settings), job.placement)
                        : r.compose(im, settings: job.settings, mode: .key, backdrop: job.backdrop,
                                    custom: background?.frame(at: pts.seconds), blur: job.blur, placement: job.placement)
                    var pb: CVPixelBuffer?
                    guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return }
                    if transparent {
                        CVBufferSetAttachment(pb, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
                    }
                    r.context.render(out, to: pb, bounds: bounds, colorSpace: rec709)
                    adaptor.append(pb, withPresentationTime: pts)
                    progress(min(1, pts.seconds / duration))
                }
            }
        }
        if let aIn, let aOut {
            group.enter()
            let aDone = Once()
            aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "export.audio")) { [self] in
                while aIn.isReadyForMoreMediaData && !aDone.done {
                    guard !cancelled, let s = aOut.copyNextSampleBuffer() else {
                        aIn.markAsFinished(); aDone.done = true; group.leave(); return
                    }
                    aIn.append(s)
                }
            }
        }
        await withCheckedContinuation { c in group.notify(queue: .global()) { c.resume() } }

        if cancelled {
            reader.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: job.output)
            throw CancellationError()
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? exportError("Export failed") }
        if reader.status == .failed { throw reader.error ?? exportError("Reading the clip failed") }
        progress(1)
    }
}

/// Headless export for testing: KeyShot --export clip out.mp4|out.mov [background]
func runExportCLI(_ a: [String]) async {
    do {
        let r = try Renderer()
        let clip = URL(fileURLWithPath: a[0]), out = URL(fileURLWithPath: a[1])
        let transparent = out.pathExtension.lowercased() == "mov"
        var s = KeySettings()
        let first = try await AVAssetImageGenerator(asset: AVURLAsset(url: clip)).image(at: .zero).image
        if let c = r.detectScreen(CIImage(cgImage: first)) { s.screen = c; s.applyScreenDefaults() }
        let env = ProcessInfo.processInfo.environment
        let job = ExportJob(clip: clip, output: out, kind: transparent ? .transparent : .withBackground, settings: s,
                            backdrop: a.count > 2 ? .custom : .blue, background: a.count > 2 ? URL(fileURLWithPath: a[2]) : nil,
                            blur: Float(env["GK_BGBLUR"] ?? "0") ?? 0)
        var job2 = job
        if let v = env["GK_PLACE"]?.split(separator: ",").compactMap({ Float($0) }), v.count == 3 { job2.placement = Placement(scale: v[0], x: v[1], y: v[2]) }
        let t = CACurrentMediaTime()
        try await Exporter().run(job2, renderer: r) { _ in }
        print(String(format: "exported in %.1f s", CACurrentMediaTime() - t))
    } catch { print("ERROR", error) }
}
