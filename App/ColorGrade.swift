// ColorGrade — 1Shot's Visual Design color chain, brought into CompShot (0.8):
// white balance → camera LUT → creative LUT → exposure, highlights, shadows, levels,
// saturation, vibrance, sharpen, denoise. Same filters and same slider strengths as 1Shot.

import CoreImage

enum ColorGrade {
    /// All values run −100…+100, 0 = untouched.
    struct Settings: Equatable {
        var exposure: Double = 0
        var highlights: Double = 0
        var shadows: Double = 0
        var temperature: Double = 0     // "Color": − cooler (blue), + warmer (yellow)
        var tint: Double = 0            // − green, + magenta
        var saturation: Double = 0
        var vibrance: Double = 0
        var sharpen: Double = 0         // 0…100
        var denoise: Double = 0         // 0…100
        var blackPoint: Double = 0      // Levels, 0…1
        var whitePoint: Double = 1      // Levels, 0…1
        var curves = Curves()           // applied right after Levels
        var isNeutral: Bool { self == Settings() }
        /// What Bypass leaves on: only Levels (the LUTs stay on too).
        var levelsOnly: Settings { var s = Settings(); s.blackPoint = blackPoint; s.whitePoint = whitePoint; return s }
    }

    /// How hard the sliders push: a slider at ±100 does what ±50 did originally (as in 1Shot).
    static let range: Double = 0.5

    /// White balance → camera LUT → creative LUT → the rest of the sliders.
    static func grade(_ input: CIImage, _ s: Settings, lut: CubeLUT?, creativeLUT: CubeLUT?) -> CIImage {
        var image = input.clampedToExtent()
        if s.temperature != 0 || s.tint != 0 { image = whiteBalance(image, temperature: s.temperature, tint: s.tint) }
        if let lut { image = lut.apply(to: image) }
        if let creativeLUT { image = creativeLUT.apply(to: image) }
        var rest = s
        rest.temperature = 0; rest.tint = 0
        return apply(rest, to: image).cropped(to: input.extent)
    }

    private static let highlightRecoveryKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 recoverHighlights(__sample s, float amount, float knee) {
            vec3 c = s.rgb;
            float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
            if (l <= knee || amount <= 0.0) { return s; }
            float x = l - knee;
            float y = x / (1.0 + amount * x / max(1.0 - knee, 0.0001));
            return vec4(c * ((knee + y) / l), s.a);
        }
        """)

    static func apply(_ s: Settings, to input: CIImage) -> CIImage {
        guard !s.isNeutral else { return input }
        var image = input
        if s.denoise > 0, let f = CIFilter(name: "CINoiseReduction") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(0.06 * s.denoise / 100, forKey: "inputNoiseLevel")
            f.setValue(0.4, forKey: "inputSharpness")
            image = f.outputImage ?? image
        }
        if s.exposure != 0, let f = CIFilter(name: "CIExposureAdjust") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(s.exposure * range / 50, forKey: kCIInputEVKey)
            image = f.outputImage ?? image
        }
        if s.highlights < 0 {
            let h = -s.highlights / 100
            if let kernel = highlightRecoveryKernel {
                let knee = 0.38 - 0.18 * h
                image = kernel.apply(extent: image.extent, arguments: [image, NSNumber(value: 4.5 * h), NSNumber(value: knee)]) ?? image
            }
            if let f = CIFilter(name: "CIHighlightShadowAdjust") {
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(1 - 0.55 * h, forKey: "inputHighlightAmount")
                f.setValue(0, forKey: "inputShadowAmount")
                f.setValue(12, forKey: "inputRadius")
                image = f.outputImage ?? image
            }
            if let f = CIFilter(name: "CIUnsharpMask") {
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(18, forKey: kCIInputRadiusKey)
                f.setValue(0.25 * h, forKey: kCIInputIntensityKey)
                image = f.outputImage ?? image
            }
        }
        if s.shadows != 0, let f = CIFilter(name: "CIHighlightShadowAdjust") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(s.shadows * range / 100, forKey: "inputShadowAmount")
            f.setValue(1, forKey: "inputHighlightAmount")
            image = f.outputImage ?? image
        }
        if s.highlights > 0, let f = CIFilter(name: "CIToneCurve") {
            let h = CGFloat(s.highlights * range / 100)
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
            f.setValue(CIVector(x: 0.25, y: 0.25), forKey: "inputPoint1")
            f.setValue(CIVector(x: 0.5, y: 0.5 + 0.03 * h), forKey: "inputPoint2")
            f.setValue(CIVector(x: 0.75, y: 0.75 + 0.12 * h), forKey: "inputPoint3")
            f.setValue(CIVector(x: 1, y: 1), forKey: "inputPoint4")
            image = f.outputImage ?? image
        }
        if s.blackPoint > 0.0001 || s.whitePoint < 0.9999 {
            let scale = 1 / max(0.02, s.whitePoint - s.blackPoint), bias = -s.blackPoint * scale
            image = image.applyingFilter("CILinearToSRGBToneCurve")
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0),
                "inputBiasVector": CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 0)])
            image = image.applyingFilter("CISRGBToneCurveToLinear")
        }
        if !s.curves.isIdentity, let f = CIFilter(name: "CIColorCurves") {
            // The curves act on the picture as you see it (sRGB-encoded), the same tones the graph shows.
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(s.curves.tableData(), forKey: "inputCurvesData")
            f.setValue(CIVector(x: 0, y: 1), forKey: "inputCurvesDomain")
            f.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
            image = f.outputImage ?? image
        }
        if s.saturation != 0, let f = CIFilter(name: "CIColorControls") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(1 + s.saturation / 100, forKey: kCIInputSaturationKey)
            image = f.outputImage ?? image
        }
        if s.vibrance != 0, let f = CIFilter(name: "CIVibrance") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(s.vibrance / 100, forKey: "inputAmount")
            image = f.outputImage ?? image
        }
        if s.sharpen > 0, let f = CIFilter(name: "CISharpenLuminance") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(1.2 * s.sharpen / 100, forKey: kCIInputSharpnessKey)
            f.setValue(1.6, forKey: "inputRadius")
            image = f.outputImage ?? image
        }
        return image
    }

    static func whiteBalance(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard let f = CIFilter(name: "CITemperatureAndTint") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: CGFloat(6500 + temperature * range * 35), y: CGFloat(tint * range)), forKey: "inputNeutral")
        f.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
        return f.outputImage ?? image
    }

    /// Finds the Color/Tint that make the picked color neutral gray after white balance + camera LUT.
    /// The color is given in linear sRGB (what CompShot measures).
    static func solveWhiteBalance(linear c: SIMD3<Float>, lut: CubeLUT?) -> (temperature: Double, tint: Double) {
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!, rec709 = CGColorSpace(name: CGColorSpace.itur_709)!
        guard let color = CIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1, colorSpace: linear) else { return (0, 0) }
        let context = CIContext(options: [.cacheIntermediates: false])
        let pixel = CGRect(x: 0, y: 0, width: 1, height: 1)
        let base = CIImage(color: color).cropped(to: pixel)
        func castError(_ t: Double, _ ti: Double) -> Double {
            var px = [Float](repeating: 0, count: 4)
            var img = whiteBalance(base.clampedToExtent(), temperature: t, tint: ti)
            if let lut { img = lut.apply(to: img) }
            context.render(img.cropped(to: pixel), toBitmap: &px, rowBytes: 16, bounds: pixel, format: .RGBAf, colorSpace: rec709)
            let (R, G, B) = (Double(px[0]), Double(px[1]), Double(px[2]))
            let mean = max((R + G + B) / 3, 0.001)
            return ((R - G) * (R - G) + (B - G) * (B - G)) / (mean * mean)
        }
        var best = (t: 0.0, ti: 0.0, err: castError(0, 0))
        for (step, span) in [(10.0, 100.0), (2.0, 10.0), (0.5, 2.0)] {
            let center = best
            var t = max(-100, center.t - span)
            while t <= min(100, center.t + span) {
                var ti = max(-100, center.ti - span)
                while ti <= min(100, center.ti + span) {
                    let e = castError(t, ti)
                    if e < best.err { best = (t, ti, e) }
                    ti += step
                }
                t += step
            }
        }
        return (best.t.rounded(), best.ti.rounded())
    }
}

/// One curve: points from (0,0) to (1,1) in display tones, joined by a smooth curve that never
/// overshoots between points (monotone cubic, the kind Photoshop and Lightroom curves feel like).
struct ToneCurve: Equatable {
    static let identity: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 1)]
    /// Sorted by x, at least two. The first and last are the ends (they can move too).
    var points: [SIMD2<Double>] = ToneCurve.identity
    var isIdentity: Bool { points == Self.identity }

    func value(at x: Double) -> Double {
        let p = points
        guard p.count >= 2 else { return x }
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }
        let m = slopes()
        var i = 0
        while i < p.count - 2 && x > p[i + 1].x { i += 1 }
        let h = p[i + 1].x - p[i].x, t = (x - p[i].x) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * p[i].y + (t3 - 2 * t2 + t) * h * m[i]
              + (-2 * t3 + 3 * t2) * p[i + 1].y + (t3 - t2) * h * m[i + 1]
        return min(1, max(0, y))
    }

    /// Fritsch–Carlson tangents: smooth, and flat wherever the curve turns around.
    private func slopes() -> [Double] {
        let p = points, n = p.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 1e-6) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        if n > 2 { for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
            if s > 9 { let k = 3 / s.squareRoot(); m[i] = k * a * d[i]; m[i + 1] = k * b * d[i] }
        }
        return m
    }
}

/// Curves: one master (RGB) curve plus one per channel. Each channel goes through its own curve, then the master.
struct Curves: Equatable {
    var master = ToneCurve(), red = ToneCurve(), green = ToneCurve(), blue = ToneCurve()
    var isIdentity: Bool { master.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity }
    enum Channel: Int, CaseIterable { case master = 0, red, green, blue }
    subscript(_ c: Channel) -> ToneCurve {
        get { switch c { case .master: master; case .red: red; case .green: green; case .blue: blue } }
        set { switch c { case .master: master = newValue; case .red: red = newValue; case .green: green = newValue; case .blue: blue = newValue } }
    }

    /// 1024 RGB float triplets for CIColorCurves.
    func tableData(size: Int = 1024) -> Data {
        var t = [Float](); t.reserveCapacity(size * 3)
        for i in 0..<size {
            let x = Double(i) / Double(size - 1)
            t.append(Float(master.value(at: red.value(at: x))))
            t.append(Float(master.value(at: green.value(at: x))))
            t.append(Float(master.value(at: blue.value(at: x))))
        }
        return t.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Everything the Visual Design page sets, ready to render.
struct Look {
    var settings = ColorGrade.Settings()
    var lut: CubeLUT? = nil
    var creativeLUT: CubeLUT? = nil
    /// false: grade only the keyed person (to match them to the background). true: grade the finished picture.
    var wholePicture = false
    var isNeutral: Bool { settings.isNeutral && lut == nil && creativeLUT == nil }
    /// Bypass: LUTs and Levels stay, white balance and the Color sliders go (preview only).
    var bypassed: Look { var l = self; l.settings = settings.levelsOnly; return l }

    func grade(_ image: CIImage) -> CIImage { ColorGrade.grade(image, settings, lut: lut, creativeLUT: creativeLUT) }

    /// Grades a keyed (premultiplied) person: colors graded on their own, then their transparency put back,
    /// so a look never tints the see-through edges.
    func gradePerson(_ fg: CIImage) -> CIImage {
        guard !isNeutral else { return fg }
        let opaque = fg.unpremultiplyingAlpha().applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        return grade(opaque).applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: fg]).cropped(to: fg.extent)
    }
}
