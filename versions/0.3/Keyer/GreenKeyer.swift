import CoreImage
import Foundation
import Metal

/// Settings for one key. Mask values are the fraction cut from each side of the frame.
struct KeySettings: Equatable {
    var screen = SIMD3<Float>(0.03, 0.35, 0.04)
    var strength: Float = 1.8
    var softness: Float = 1.0
    var spill: Float = 1.0
    var spillFirmness: Float = 0.5  // 0 = gentle (keeps yellows), 1 = firm (removes olive tints from hair)
    var shrink: Float = 0          // pulls the edge in, in pixels at 1080p (removes thin outlines)
    var smooth: Float = 0          // softens the edge, in pixels at 1080p (hides blocky compression)
    var correction: Float = 1.0   // 0 = one screen color, 1 = follow the screen's shading and shadows
    var edgeRepair: Float = 1.0   // 0 = off, 1 = replace see-through edge color with nearby subject color
    var maskLeft: Float = 0
    var maskRight: Float = 0
    var maskTop: Float = 0
    var maskBottom: Float = 0
}

enum KeyOutput { case foreground, matte }

// Every kernel writes texture 0 and reads inputs from textures 1, 2...
// p[0...2] = output origin x, y and height; p[3...8] = read offsets for inputs 1-3; settings start at p[9].
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

static float2 imagePos(constant float *p, uint2 gid) {
    return float2(p[0] + float(gid.x) + 0.5, p[1] + p[2] - float(gid.y) - 0.5);
}
static uint2 at(constant float *p, uint2 gid, int i) {
    return uint2(int2(gid) + int2(int(p[3 + 2 * i]), int(p[4 + 2 * i])));
}
static float greenness(float3 c) { return (c.g - max(c.r, c.b)) / max(c.g, 0.0001); }

// Reads a smaller copy of the image smoothly. p[base...] = scale, region minX, maxY, width, height.
constexpr sampler smooth(coord::normalized, filter::linear, address::clamp_to_edge);
static float4 sampleSmall(texture2d<float, access::sample> t, constant float *p, int base, float2 pos) {
    float2 q = pos * p[base];
    return t.sample(smooth, float2((q.x - p[base + 1]) / p[base + 3], (p[base + 2] - q.y) / p[base + 4]));
}

// Marks pixels that look like the screen, including where it is in shadow (same hue, darker).
kernel void screenWeight(texture2d<float, access::write> dst [[texture(0)]],
                         texture2d<float, access::read> src [[texture(1)]],
                         constant float *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float3 c = src.read(at(p, gid, 0)).rgb;
    float3 s = float3(p[9], p[10], p[11]);
    float w = smoothstep(0.55, 0.8, greenness(c) / max(greenness(s), 0.0001)) * step(0.003, c.g);
    dst.write(float4(c * w, w), gid);
}

// Fills the subject's hole in the screen with nearby screen color: a clean plate.
kernel void screenPlate(texture2d<float, access::write> dst [[texture(0)]],
                        texture2d<float, access::read> nearBlur [[texture(1)]],
                        texture2d<float, access::read> farBlur [[texture(2)]],
                        constant float *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float4 n = nearBlur.read(at(p, gid, 0)), f = farBlur.read(at(p, gid, 1));
    float3 c = n.a > 0.02 ? n.rgb / n.a : (f.a > 0.002 ? f.rgb / f.a : float3(p[9], p[10], p[11]));
    dst.write(float4(c, 1.0), gid);
}

// Color-difference key against the local screen color, in linear light. Output is premultiplied.
kernel void greenKey(texture2d<float, access::write> dst [[texture(0)]],
                     texture2d<float, access::read> src [[texture(1)]],
                     texture2d<float, access::sample> plate [[texture(2)]],
                     constant float *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float2 pos = imagePos(p, gid);
    bool inside = pos.x >= p[16] && pos.y >= p[17] && pos.x <= p[18] && pos.y <= p[19];
    float3 c = src.read(at(p, gid, 0)).rgb;
    float3 global = float3(p[9], p[10], p[11]);
    float3 screen = p[15] > 0.0 ? mix(global, sampleSmall(plate, p, 22, pos).rgb, p[15]) : global;

    float screenDiff = max(screen.g - max(screen.r, screen.b), 0.0001);
    float m = 1.0 - p[12] * (c.g - max(c.r, c.b)) / screenDiff;
    // Softness p[13] is where the subject becomes fully solid: 1 keeps the true blend at edges,
    // lower values make edges harder.
    float a = inside ? saturate(m / max(p[13], 0.001)) : 0.0;
    if (p[20] > 0.5) { dst.write(float4(a, a, a, 1.0), gid); return; }

    // Remove the screen's contribution, then limit any green left over. Firmness p[21] moves the
    // limit from the stronger of red and blue (gentle) to their average (firm, also fixes olive tints).
    float3 f = max(c - (1.0 - a) * screen, float3(0.0));
    float limit = mix(max(f.r, f.b), 0.5 * (f.r + f.b), p[21]);
    f.g -= p[14] * max(f.g - limit, 0.0);
    dst.write(float4(min(f, float3(a)), a), gid);
}

// In see-through edges, swap the color for the nearby solid subject color, keeping the brightness.
kernel void edgeRepair(texture2d<float, access::write> dst [[texture(0)]],
                       texture2d<float, access::read> fg [[texture(1)]],
                       texture2d<float, access::sample> blurred [[texture(2)]],
                       constant float *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float4 f = fg.read(at(p, gid, 0));
    if (f.a < 0.001 || f.a > 0.999) { dst.write(f, gid); return; }
    float4 b = sampleSmall(blurred, p, 10, imagePos(p, gid));
    if (f.a < 0.001 || b.a < 0.001) { dst.write(f, gid); return; }
    float3 straight = f.rgb / f.a, inner = b.rgb / b.a;
    const float3 L = float3(0.2126, 0.7152, 0.0722);
    float3 repaired = inner * (dot(straight, L) / max(dot(inner, L), 0.0001));
    float t = p[9] * (1.0 - f.a);
    dst.write(float4(mix(straight, repaired, t) * f.a, f.a), gid);
}

// Replaces the edge with a shrunk and smoothed one. refined = blur(min(fg)), premultiplied.
// Where the original edge was nearly clear, the color comes from the smoothed subject instead.
kernel void refineEdge(texture2d<float, access::write> dst [[texture(0)]],
                       texture2d<float, access::read> fg [[texture(1)]],
                       texture2d<float, access::read> refined [[texture(2)]],
                       constant float *p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    float4 f = fg.read(at(p, gid, 0)), r = refined.read(at(p, gid, 1));
    float a = r.a;
    if (a < 0.0005) { dst.write(float4(0.0), gid); return; }
    float3 straight = f.a > 0.05 ? f.rgb / f.a : r.rgb / max(r.a, 0.0001);
    dst.write(float4(straight * a, a), gid);
}
"""

/// Runs one of the Metal functions above inside a Core Image graph.
private final class KeyStep: CIImageProcessorKernel {
    nonisolated(unsafe) static var pipelines: [String: MTLComputePipelineState] = [:]

    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
    /// Input 1 may be a smaller copy (scale "k", extent "e1"); it is read with smooth sampling.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard input == 1, let k = arguments?["k"] as? Float, let e1 = (arguments?["e1"] as? CIVector)?.cgRectValue else { return outputRect }
        let r = outputRect.applying(CGAffineTransform(scaleX: CGFloat(k), y: CGFloat(k))).insetBy(dx: -2, dy: -2).integral
        return r.intersection(e1)
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let inputs, let name = arguments?["fn"] as? String, let pipeline = pipelines[name],
              let settings = arguments?["p"] as? [Float], let dst = output.metalTexture,
              let cb = output.metalCommandBuffer, let e = cb.makeComputeCommandEncoder() else { return }
        let o = output.region
        var p: [Float] = [Float(o.minX), Float(o.minY), Float(o.height)]
        for i in 0..<3 {
            let r = i < inputs.count ? inputs[i].region : o
            p += [Float(o.minX - r.minX), Float(r.maxY - o.maxY)]
        }
        p += settings
        if let k = arguments?["k"] as? Float, inputs.count > 1 {
            let r = inputs[1].region
            p += [k, Float(r.minX), Float(r.maxY), Float(r.width), Float(r.height)]
        }
        e.setComputePipelineState(pipeline)
        e.setTexture(dst, index: 0)
        for (i, input) in inputs.enumerated() { e.setTexture(input.metalTexture, index: i + 1) }
        e.setBytes(p, length: p.count * MemoryLayout<Float>.stride, index: 0)
        e.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        e.endEncoding()
    }

    static func run(_ fn: String, _ inputs: [CIImage], extent: CGRect, _ settings: [Float], smallScale: Float? = nil) -> CIImage {
        var args: [String: Any] = ["fn": fn, "p": settings]
        if let k = smallScale, inputs.count > 1 { args["k"] = k; args["e1"] = CIVector(cgRect: inputs[1].extent) }
        return (try? apply(withExtent: extent, inputs: inputs, arguments: args)) ?? inputs[0]
    }
}

/// The portable part: takes a CIImage and returns a keyed CIImage. No app or UI code.
final class GreenKeyer {
    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        for name in ["screenWeight", "screenPlate", "greenKey", "edgeRepair", "refineEdge"] {
            KeyStep.pipelines[name] = try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
    }

    private func blur(_ image: CIImage, _ radius: CGFloat) -> CIImage {
        image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: image.extent)
    }

    private func shrink(_ image: CIImage, _ k: CGFloat) -> CIImage {
        let e = image.extent
        return image.transformed(by: CGAffineTransform(scaleX: k, y: k))
            .cropped(to: CGRect(x: 0, y: 0, width: (e.width * k).rounded(.down), height: (e.height * k).rounded(.down)))
    }

    /// An estimate of the empty screen behind the subject, at 1/8 size.
    func screenPlate(for image: CIImage, screen: [Float]) -> CIImage {
        let small = shrink(image, 1.0 / 8), se = small.extent
        let weight = KeyStep.run("screenWeight", [small], extent: se, screen)
        return KeyStep.run("screenPlate", [blur(weight, se.width * 0.0125), blur(weight, se.width * 0.06)], extent: se, screen)
    }

    func apply(to input: CIImage, settings s: KeySettings, output: KeyOutput = .foreground) -> CIImage {
        let origin = input.extent.origin
        let image = input.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let e = image.extent
        let screen = [s.screen.x, s.screen.y, s.screen.z]
        let plate = s.correction > 0 ? screenPlate(for: image, screen: screen) : shrink(image, 1.0 / 8)
        let p = screen + [s.strength, s.softness, s.spill, s.correction,
                          s.maskLeft * Float(e.width), s.maskBottom * Float(e.height),
                          Float(e.width) - s.maskRight * Float(e.width), Float(e.height) - s.maskTop * Float(e.height),
                          0, s.spillFirmness]
        var result = KeyStep.run("greenKey", [image, plate], extent: e, p, smallScale: 1.0 / 8)
        if output == .foreground && s.edgeRepair > 0 {
            let small = shrink(result, 1.0 / 4)
            result = KeyStep.run("edgeRepair", [result, blur(small, small.extent.width / 480)], extent: e, [s.edgeRepair], smallScale: 1.0 / 4)
        }
        if s.shrink > 0 || s.smooth > 0 {
            let px = Float(e.height) / 1080
            var refined = result
            if s.shrink > 0 {
                refined = refined.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: s.shrink * px]).cropped(to: e)
            }
            if s.smooth > 0 { refined = blur(refined, CGFloat(s.smooth * px)) }
            result = KeyStep.run("refineEdge", [result, refined], extent: e, [])
        }
        if output == .matte {
            // Show the alpha channel as gray, including any shrink and smoothing.
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: e)
        }
        return result.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }
}
