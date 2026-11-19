import AVFoundation
import CoreImage
import UniformTypeIdentifiers

/// Which way to turn a video's frames, from its track transform.
func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
    let angle = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
    return angle == 90 ? .right : angle == -90 ? .left : abs(angle) == 180 ? .down : .up
}

func upright(_ buffer: CVPixelBuffer, _ o: CGImagePropertyOrientation) -> CIImage {
    let im = CIImage(cvPixelBuffer: buffer).oriented(o)
    return im.transformed(by: CGAffineTransform(translationX: -im.extent.minX, y: -im.extent.minY))
}

func isImageFile(_ url: URL) -> Bool {
    (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
}

private let bgra: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                   kCVPixelBufferMetalCompatibilityKey as String: true]

/// A background for the live preview: a still image, or a muted video that loops.
final class BackgroundPreview {
    let url: URL
    private(set) var still: CIImage?
    private var player: AVPlayer?, output: AVPlayerItemVideoOutput?, observer: Any?
    private var orient = CGImagePropertyOrientation.up
    private(set) var latest: CIImage?

    init(url: URL) async throws {
        self.url = url
        if isImageFile(url) {
            guard let im = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                throw NSError(domain: "KeyShot", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not read that image"])
            }
            still = im
            return
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "KeyShot", code: 4, userInfo: [NSLocalizedDescriptionKey: "That file has no video"])
        }
        orient = orientation(for: try await track.load(.preferredTransform))
        duration = try await asset.load(.duration).seconds
        let item = AVPlayerItem(asset: asset), o = AVPlayerItemVideoOutput(pixelBufferAttributes: bgra)
        item.add(o)
        let p = AVPlayer(playerItem: item); p.isMuted = true; p.actionAtItemEnd = .none
        observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
            p?.seek(to: .zero); p?.play()
        }
        player = p; output = o
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var isVideo: Bool { still == nil }
    private var duration = 0.0

    /// Keeps the background on the clip's clock, looping, the same way export does:
    /// plays and pauses with the clip, and jumps when the clip is scrubbed.
    func follow(time t: Double, playing: Bool) {
        guard let p = player, duration > 0, t.isFinite else { return }
        let target = t.truncatingRemainder(dividingBy: duration)
        let now = p.currentTime().seconds
        var drift = abs(now - target); drift = min(drift, duration - drift)
        let seekTarget = CMTime(seconds: target, preferredTimescale: 600)
        if playing {
            if p.rate == 0 { p.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero); p.play() }
            else if drift > 0.2 { p.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero) }
        } else {
            if p.rate != 0 { p.pause() }
            if drift > 0.02 { p.seek(to: seekTarget, toleranceBefore: .zero, toleranceAfter: .zero) }
        }
    }

    /// The frame to show now. Returns true when it changed since the last call.
    func poll() -> Bool {
        guard let o = output else { return false }
        let t = o.itemTime(forHostTime: CACurrentMediaTime())
        guard o.hasNewPixelBuffer(forItemTime: t), let pb = o.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return false }
        latest = upright(pb, orient)
        return true
    }

    var current: CIImage? { still ?? latest }
}

/// Background frames for export, read in order and looped to cover the whole clip.
final class BackgroundFrames {
    private var still: CIImage?
    private var asset: AVURLAsset?, track: AVAssetTrack?, orient = CGImagePropertyOrientation.up
    private var duration = 0.0, reader: AVAssetReader?, out: AVAssetReaderTrackOutput?
    private var current: CIImage?, pending: CMSampleBuffer?, lastTime = -1.0

    init(url: URL) async throws {
        if isImageFile(url) {
            still = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            return
        }
        let a = AVURLAsset(url: url)
        guard let t = try await a.loadTracks(withMediaType: .video).first else { return }
        asset = a; track = t
        orient = orientation(for: try await t.load(.preferredTransform))
        duration = try await a.load(.duration).seconds
        try restart()
    }

    private func restart() throws {
        guard let asset, let track else { return }
        reader?.cancelReading()
        let r = try AVAssetReader(asset: asset), o = AVAssetReaderTrackOutput(track: track, outputSettings: bgra)
        o.alwaysCopiesSampleData = false; r.add(o); r.startReading()
        reader = r; out = o; pending = nil
    }

    /// The background frame for a time in the clip, looping when the background is shorter.
    func frame(at t: Double) -> CIImage? {
        if let still { return still }
        guard duration > 0 else { return current }
        let lt = t.truncatingRemainder(dividingBy: duration)
        if lt < lastTime { try? restart() }
        lastTime = lt
        while true {
            if pending == nil { pending = out?.copyNextSampleBuffer() }
            guard let s = pending else { break }
            if CMSampleBufferGetPresentationTimeStamp(s).seconds <= lt + 0.0005 || current == nil {
                if let pb = CMSampleBufferGetImageBuffer(s) { current = upright(pb, orient) }
                pending = nil
            } else { break }
        }
        return current
    }
}
