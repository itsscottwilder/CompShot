import CoreImage
import Metal
import QuartzCore

/// key = the finished picture ("Final" in the app). split (0.8) = matte on the left, final on the right.
enum ViewMode: Int { case original, matte, key, split }
enum Backdrop: Int { case blue, checker, custom }

/// Where the keyed person sits in the frame (like a 1Shot graphic's size and nudge).
/// x and y are fractions of the frame width and height; y grows downward, as on screen.
struct Placement: Equatable {
    var scale: Float = 1, x: Float = 0, y: Float = 0
    var isIdentity: Bool { abs(scale - 1) < 0.0005 && abs(x) < 0.0005 && abs(y) < 0.0005 }
    /// Scales about the frame's centre, then moves.
    func transform(for e: CGRect) -> CGAffineTransform {
        let c = CGPoint(x: e.midX, y: e.midY), s = CGFloat(scale)
        return CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: c.x + CGFloat(x) * e.width, y: c.y - CGFloat(y) * e.height))
    }
}

/// Blend (0.8): makes a keyed person sit in the background instead of looking pasted on.
/// Sizes are pixels at 1080p, measured in the finished frame (after Size).
struct Blend: Equatable {
    var lightWrap: Float = 0      // 0–1: the background's light spills over your edges
    var wrapWidth: Float = 12     // 2–40 px: how far in the wrap reaches
    var diffusion: Float = 0      // 0–1: mist-filter glow from the bright parts, softer fine contrast
    var soften: Float = 0         // 0–2 px: a light blur that takes off over-sharpened detail and hard outlines
    var isOff: Bool { lightWrap == 0 && diffusion == 0 && soften == 0 }
}

private let mistKernel = CIColorKernel(source: """
    kernel vec4 mist(__sample s, __sample w, float amount) {
        vec4 soft = mix(s, w, 0.35 * amount);                       // less fine contrast, like a mist filter
        vec3 bloom = max(w.rgb - vec3(0.55) * w.a, vec3(0.0)) * 0.45; // a gentle glow from the brightest parts, reaching past the edge
        return vec4(soft.rgb + bloom * amount, soft.a);
    }
    """)

private let wrapKernel = CIColorKernel(source: """
    kernel vec4 lightWrap(__sample f, __sample a, __sample b, float amount) {
        float edge = clamp(2.0 * (1.0 - a.a), 0.0, 1.0);  // 0 deep inside you, up to 1 at the edge
        float k = amount * edge;
        return vec4(mix(f.rgb, b.rgb * f.a, k), f.a);
    }
    """)

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let keyer: GreenKeyer
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            throw NSError(domain: "CompShot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable"])
        }
        device = d; queue = q
        context = CIContext(mtlCommandQueue: q, options: [.cacheIntermediates: false])
        keyer = try GreenKeyer(device: d)
    }

    func backdrop(_ b: Backdrop, extent: CGRect) -> CIImage {
        let image: CIImage
        switch b {
        case .blue, .custom:
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

    /// Scales a background to cover the frame (like "fill"), centred, with optional blur in pixels at 1080p.
    func fill(_ bg: CIImage, extent: CGRect, blur: Float) -> CIImage {
        let b = bg.extent, k = max(extent.width / b.width, extent.height / b.height)
        var im = bg.transformed(by: CGAffineTransform(translationX: -b.minX, y: -b.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        im = im.transformed(by: CGAffineTransform(translationX: extent.minX + (extent.width - b.width * k) / 2,
                                                  y: extent.minY + (extent.height - b.height * k) / 2))
        if blur > 0 { im = im.clampedToExtent().applyingGaussianBlur(sigma: Double(blur) * Double(extent.height) / 1080) }
        return im.cropped(to: extent)
    }

    /// The keyed person moved and resized; the frame stays the same size.
    func place(_ fg: CIImage, _ p: Placement) -> CIImage {
        let e = fg.extent
        return p.isIdentity ? fg : fg.transformed(by: p.transform(for: e)).cropped(to: e)
    }

    /// The keyed person, graded (unless the look is for the whole picture), moved and resized, then
    /// softened and diffused (Blend). Light wrap needs the background, so compose adds it.
    func person(_ image: CIImage, settings: KeySettings, look: Look?, placement: Placement, blend: Blend = Blend(),
                forceGrade: Bool = false) -> CIImage {
        var fg = keyer.apply(to: image, settings: settings)
        if let look, forceGrade || !look.wholePicture { fg = look.gradePerson(fg) }
        fg = place(fg, placement)
        let e = fg.extent, px = Double(e.height) / 1080
        if blend.soften > 0 { fg = fg.applyingGaussianBlur(sigma: Double(blend.soften) * px).cropped(to: e) }
        if blend.diffusion > 0, let k = mistKernel {
            let wide = fg.applyingGaussianBlur(sigma: 14 * px).cropped(to: e)
            fg = k.apply(extent: e, arguments: [fg, wide, NSNumber(value: blend.diffusion)]) ?? fg
        }
        return fg
    }

    /// The background's light spilling over the person's edges.
    func lightWrap(_ fg: CIImage, over bg: CIImage, _ blend: Blend) -> CIImage {
        guard blend.lightWrap > 0, let k = wrapKernel else { return fg }
        let e = fg.extent, sigma = Double(blend.wrapWidth) * Double(e.height) / 1080 / 2
        let a = fg.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: e)
        let b = bg.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: e)
        return k.apply(extent: e, arguments: [fg, a, b, NSNumber(value: blend.lightWrap)]) ?? fg
    }

    /// `look`: the Visual Design grade (nil = none). It touches only the key view, never Matte or Original.
    func compose(_ image: CIImage, settings: KeySettings, mode: ViewMode, backdrop b: Backdrop,
                 custom: CIImage? = nil, blur: Float = 0, placement: Placement = Placement(), look: Look? = nil,
                 split: CGFloat = 0.5, blend: Blend = Blend()) -> CIImage {
        switch mode {
        case .split:
            // Matte left of the line, finished picture right of it: one view shows what every control does to both.
            let e = image.extent, x = e.minX + e.width * min(max(split, 0), 1)
            let matte = compose(image, settings: settings, mode: .matte, backdrop: b, placement: placement)
            let final = compose(image, settings: settings, mode: .key, backdrop: b, custom: custom, blur: blur, placement: placement, look: look, blend: blend)
            return final.cropped(to: CGRect(x: x, y: e.minY, width: e.maxX - x, height: e.height))
                .composited(over: matte.cropped(to: CGRect(x: e.minX, y: e.minY, width: x - e.minX, height: e.height)))
                .cropped(to: e)
        case .original: return image
        case .matte:
            // Outside the moved matte is black (removed), like the rest of the background.
            return place(keyer.apply(to: image, settings: settings, output: .matte), placement)
                .composited(over: CIImage(color: .black).cropped(to: image.extent))
        case .key:
            let bg = b == .custom && custom != nil ? fill(custom!, extent: image.extent, blur: blur)
                                                   : backdrop(b == .custom ? .blue : b, extent: image.extent)
            let fg = lightWrap(person(image, settings: settings, look: look, placement: placement, blend: blend), over: bg, blend)
            let out = fg.composited(over: bg).cropped(to: image.extent)
            if let look, look.wholePicture, !look.isNeutral { return look.grade(out) }
            return out
        }
    }

    /// Average linear color of part of an image.
    func average(_ image: CIImage, rect: CGRect) -> SIMD3<Float>? {
        averageRGBA(image, rect: rect).map { SIMD3($0.x, $0.y, $0.z) }
    }
    /// Average linear color and alpha (premultiplied, as Core Image keeps it).
    func averageRGBA(_ image: CIImage, rect: CGRect) -> SIMD4<Float>? {
        let r = rect.intersection(image.extent)
        guard !r.isNull, !r.isEmpty, let f = CIFilter(name: "CIAreaAverage") else { return nil }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgRect: r), forKey: kCIInputExtentKey)
        guard let out = f.outputImage else { return nil }
        var px = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linear)
        return SIMD4(px[0], px[1], px[2], px[3])
    }

    /// Finds the screen color by averaging the clearly green or clearly blue pixels of a small copy
    /// of the frame, whichever there are more of.
    func detectScreen(_ image: CIImage) -> SIMD3<Float>? {
        let w = 160, h = max(1, Int(160 * image.extent.height / image.extent.width))
        let small = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width,
                                                            y: CGFloat(h) / image.extent.height))
        var px = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 16,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: linear)
        var green = SIMD3<Float>(repeating: 0), blue = SIMD3<Float>(repeating: 0), ng: Float = 0, nb: Float = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = SIMD3(px[i], px[i + 1], px[i + 2])
            if c.y > 0.04 && c.y > 1.5 * max(c.x, c.z) { green += c; ng += 1 }
            else if c.z > 0.04 && c.z > 1.5 * max(c.x, c.y) { blue += c; nb += 1 }
        }
        if max(ng, nb) <= 20 { return nil }
        return ng >= nb ? green / ng : blue / nb
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
