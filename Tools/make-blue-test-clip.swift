// Makes a blue screen test clip from a green screen clip by rotating its channels (red <- blue, green <- red,
// blue <- green), which turns a typical green screen into blue-screen blue.
//   xcrun swift Tools/make-blue-test-clip.swift in.mp4 out.mp4 [seconds]
import AVFoundation
import CoreImage

let a = CommandLine.arguments
let seconds = a.count > 3 ? Double(a[3])! : 6
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let (size, rate) = try await track.load(.naturalSize, .nominalFrameRate)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out); reader.startReading()
        try? FileManager.default.removeItem(atPath: a[2])
        let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: a[2]), fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let ctx = CIContext(), sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var n = 0
        while let s = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(s) {
            let swapped = CIImage(cvPixelBuffer: pb).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var dst: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &dst)
            ctx.render(swapped, to: dst!, bounds: CGRect(origin: .zero, size: size), colorSpace: sRGB)
            adaptor.append(dst!, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(s)); n += 1
        }
        input.markAsFinished(); await writer.finishWriting()
        print("wrote", n, "frames at", rate, "fps")
    } catch { print("ERROR", error) }
    sem.signal()
}
sem.wait()
