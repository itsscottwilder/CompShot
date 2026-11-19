import CoreImage
import Metal
import QuartzCore

enum ViewMode: Int { case original, matte, key }
enum Backdrop: Int { case blue, checker }

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let keyer: GreenKeyer
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            throw NSError(domain: "GreenKeyLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable"])
        }
        device = d; queue = q
        context = CIContext(mtlCommandQueue: q, options: [.cacheIntermediates: false])
        keyer = try GreenKeyer(device: d)
    }

    func backdrop(_ b: Backdrop, extent: CGRect) -> CIImage {
        let image: CIImage
        switch b {
        case .blue:
            image = CIImage(color: CIColor(red: 0.16, green: 0.2, blue: 0.42, alpha: 1, colorSpace: sRGB)!)
        case .checker:
            let f = CIFilter(name: "CICheckerboardGenerator")!
            f.setValue(CIVector(x: 0, y: 0), forKey: "inputCenter")
            f.setValue(CIColor(red: 0.32, green: 0.32, blue: 0.32), forKey: "inputColor0")
            f.setValue(CIColor(red: 0.14, green: 0.14, blue: 0.14), forKey: "inputColor1")
            f.setValue(max(extent.width, extent.height) / 48, forKey: "inputWidth")
            f.setValue(1, forKey: "inputSharpness")
            image = f.outputImage!
        }
        return image.cropped(to: extent)
    }

    func compose(_ image: CIImage, settings: KeySettings, mode: ViewMode, backdrop b: Backdrop) -> CIImage {
        switch mode {
        case .original: return image
        case .matte: return keyer.apply(to: image, settings: settings, output: .matte)
        case .key:
            return keyer.apply(to: image, settings: settings)
                .composited(over: backdrop(b, extent: image.extent))
                .cropped(to: image.extent)
        }
    }

    /// Average linear color of part of an image.
    func average(_ image: CIImage, rect: CGRect) -> SIMD3<Float>? {
        let r = rect.intersection(image.extent)
        guard !r.isNull, !r.isEmpty, let f = CIFilter(name: "CIAreaAverage") else { return nil }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgRect: r), forKey: kCIInputExtentKey)
        guard let out = f.outputImage else { return nil }
        var px = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linear)
        return SIMD3(px[0], px[1], px[2])
    }

    /// Finds the screen color by averaging the clearly green pixels of a small copy of the frame.
    func detectScreen(_ image: CIImage) -> SIMD3<Float>? {
        let w = 160, h = max(1, Int(160 * image.extent.height / image.extent.width))
        let small = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width,
                                                            y: CGFloat(h) / image.extent.height))
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 16,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: linear)
        var sum = SIMD3<Float>(repeating: 0); var n: Float = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 1] > 0.04 && px[i + 1] > 1.5 * max(px[i], px[i + 2]) {
            sum += SIMD3(px[i], px[i + 1], px[i + 2]); n += 1
        }
        return n > 20 ? sum / n : nil
    }

    func makeTarget(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]; d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    /// Renders at full size, waits for the finished frame, and returns elapsed milliseconds.
    func timedRender(_ image: CIImage, to target: MTLTexture, bounds: CGRect) -> Double {
        guard let cb = queue.makeCommandBuffer() else { return 0 }
        let start = CACurrentMediaTime()
        let dest = CIRenderDestination(mtlTexture: target, commandBuffer: cb)
        dest.colorSpace = sRGB
        guard let task = try? context.startTask(toRender: image, from: bounds, to: dest, at: .zero) else { return 0 }
        cb.commit()
        let info = try? task.waitUntilCompleted()
        cb.waitUntilCompleted()
        if ProcessInfo.processInfo.environment["GK_INFO"] != nil, let info {
            print(String(format: "passes %d, pixels %.1fM, kernel time %.1f ms", info.passCount, Double(info.pixelsProcessed) / 1e6, info.kernelExecutionTime * 1000))
        }
        return (CACurrentMediaTime() - start) * 1000
    }
}
