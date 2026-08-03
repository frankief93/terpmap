import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A film look: color math baked into a 3D LUT (CIColorCube) plus spatial
/// effects (grain, halation, vignette) applied as separate CI filters.
struct FilmLook: Identifiable, Equatable {
    let id: String
    let name: String
    var ev: Double          // stops, applied in linear-ish space
    var contrast: Double    // -1...1
    var saturation: Double  // 0...2
    var warmth: Double      // -1...1  (blue <-> amber)
    var tint: Double        // -1...1  (green <-> magenta)
    var fade: Double        // 0...1   lifted blacks
    var grain: Double       // 0...1
    var vignette: Double    // 0...1
    var halation: Double    // 0...1
    var mono: Bool

    static let all: [FilmLook] = [
        FilmLook(id: "natural", name: "Natural", ev: 0, contrast: 0.06, saturation: 1.02, warmth: 0.03, tint: 0, fade: 0.02, grain: 0.10, vignette: 0.12, halation: 0.05, mono: false),
        FilmLook(id: "gold", name: "Gold 200", ev: 0.08, contrast: 0.12, saturation: 1.12, warmth: 0.22, tint: 0.02, fade: 0.06, grain: 0.22, vignette: 0.22, halation: 0.25, mono: false),
        FilmLook(id: "meadow", name: "Meadow", ev: 0.05, contrast: 0.02, saturation: 0.92, warmth: 0.10, tint: -0.06, fade: 0.12, grain: 0.16, vignette: 0.16, halation: 0.12, mono: false),
        FilmLook(id: "chrome", name: "Chrome", ev: -0.05, contrast: 0.22, saturation: 1.18, warmth: -0.04, tint: 0.03, fade: 0.0, grain: 0.12, vignette: 0.26, halation: 0.10, mono: false),
        FilmLook(id: "dusk", name: "Dusk", ev: -0.1, contrast: 0.10, saturation: 0.85, warmth: -0.12, tint: 0.05, fade: 0.10, grain: 0.18, vignette: 0.30, halation: 0.18, mono: false),
        FilmLook(id: "cinema", name: "Cinema", ev: -0.05, contrast: 0.18, saturation: 0.88, warmth: 0.08, tint: -0.04, fade: 0.08, grain: 0.14, vignette: 0.34, halation: 0.30, mono: false),
        FilmLook(id: "mono", name: "Mono 400", ev: 0, contrast: 0.20, saturation: 0, warmth: 0, tint: 0, fade: 0.05, grain: 0.30, vignette: 0.26, halation: 0.08, mono: true),
        FilmLook(id: "noir", name: "Noir", ev: -0.15, contrast: 0.38, saturation: 0, warmth: 0, tint: 0, fade: 0.0, grain: 0.20, vignette: 0.45, halation: 0.05, mono: true),
    ]
}

/// Builds and caches the CI filter chain for a look.
final class LookEngine {
    static let shared = LookEngine()

    private let cubeDimension = 33
    private var cubeCache: [String: Data] = [:]
    private let cacheLock = NSLock()

    // MARK: - Public

    /// Full chain for stills: LUT -> grain -> halation -> vignette.
    func apply(_ look: FilmLook, to image: CIImage, forPreview: Bool = false) -> CIImage {
        var out = applyCube(look, to: image)
        if look.halation > 0.02 && !forPreview {
            out = applyHalation(look, to: out)
        }
        if look.grain > 0.01 {
            out = applyGrain(look, to: out, subtle: forPreview)
        }
        if look.vignette > 0.01 {
            out = applyVignette(look, to: out)
        }
        return out.cropped(to: image.extent)
    }

    // MARK: - LUT

    private func applyCube(_ look: FilmLook, to image: CIImage) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(cubeDimension)
        filter.cubeData = cubeData(for: look)
        filter.colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        return filter.outputImage ?? image
    }

    private func cubeData(for look: FilmLook) -> Data {
        let key = "\(look.id)-\(look.ev)-\(look.contrast)-\(look.saturation)-\(look.warmth)-\(look.tint)-\(look.fade)-\(look.mono)"
        cacheLock.lock()
        if let cached = cubeCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        let n = cubeDimension
        var cube = [Float](repeating: 0, count: n * n * n * 4)

        let gain = pow(2.0, look.ev)
        // White balance channel multipliers (same model as the web prototype)
        let wr = 1 + look.warmth * 0.22 + look.tint * 0.06
        let wg = 1 - abs(look.tint) * 0.05 + (look.tint < 0 ? -look.tint * 0.12 : 0)
        let wb = 1 - look.warmth * 0.22 + (look.tint > 0 ? look.tint * 0.12 : 0)
        let sat = look.mono ? 0.0 : look.saturation

        func tone(_ v: Double) -> Double {
            var x = v * gain
            let clamped = min(1, max(0, x))
            let s = clamped * clamped * (3 - 2 * clamped)                    // smoothstep S-curve
            let c = min(1, max(0, 0.5 + (x - 0.5) * (1 + look.contrast * 1.6)))
            x = x * 0.35 + s * 0.25 + c * 0.4
            x = x / (1 + max(0, x - 0.9) * 0.6)                              // highlight shoulder
            x = look.fade * 0.18 + x * (1 - look.fade * 0.18)                // lifted blacks
            return min(1, max(0, x))
        }

        var i = 0
        for b in 0..<n {
            let bf = Double(b) / Double(n - 1)
            for g in 0..<n {
                let gf = Double(g) / Double(n - 1)
                for r in 0..<n {
                    let rf = Double(r) / Double(n - 1)
                    var rr = tone(rf * wr)
                    var gg = tone(gf * wg)
                    var bb = tone(bf * wb)
                    // Saturation around Rec.601 luma
                    let lum = rr * 0.299 + gg * 0.587 + bb * 0.114
                    rr = lum + (rr - lum) * sat
                    gg = lum + (gg - lum) * sat
                    bb = lum + (bb - lum) * sat
                    cube[i] = Float(min(1, max(0, rr)))
                    cube[i + 1] = Float(min(1, max(0, gg)))
                    cube[i + 2] = Float(min(1, max(0, bb)))
                    cube[i + 3] = 1
                    i += 4
                }
            }
        }
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        cacheLock.lock()
        cubeCache[key] = data
        cacheLock.unlock()
        return data
    }

    // MARK: - Grain

    private let noiseSource: CIImage = {
        CIFilter.randomGenerator().outputImage ?? CIImage.empty()
    }()

    private func applyGrain(_ look: FilmLook, to image: CIImage, subtle: Bool) -> CIImage {
        let amount = look.grain * (subtle ? 0.5 : 1.0)
        // Scale noise up slightly relative to image size so grain has body at 48MP.
        let grainScale = max(1.0, image.extent.width / 1600.0)
        var noise = noiseSource
            .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
            .cropped(to: image.extent)

        // Desaturate and center around 0.5 gray with amplitude proportional to `amount`.
        let a = CGFloat(0.35 * amount)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = noise
        matrix.rVector = CIVector(x: a, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: a, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: a, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0.5 - a / 2, y: 0.5 - a / 2, z: 0.5 - a / 2, w: 0)
        noise = matrix.outputImage ?? noise

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = noise
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }

    // MARK: - Halation

    private func applyHalation(_ look: FilmLook, to image: CIImage) -> CIImage {
        // Isolate highlights: subtract threshold, clamp to >= 0.
        let threshold: CGFloat = 0.72
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        let s: CGFloat = 1.0 / (1.0 - threshold)
        m.rVector = CIVector(x: s, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: 0, y: s, z: 0, w: 0)
        m.bVector = CIVector(x: 0, y: 0, z: s, w: 0)
        m.biasVector = CIVector(x: -threshold * s, y: -threshold * s, z: -threshold * s, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = m.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let highlights = clamp.outputImage else { return image }

        // Blur radius scales with image size; warm the glow toward red/orange.
        let radius = image.extent.width / 120.0 * (0.5 + look.halation)
        let blurred = highlights
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: image.extent)

        let warm = CIFilter.colorMatrix()
        warm.inputImage = blurred
        let strength = CGFloat(look.halation) * 0.55
        warm.rVector = CIVector(x: strength, y: 0, z: 0, w: 0)
        warm.gVector = CIVector(x: 0, y: strength * 0.45, z: 0, w: 0)
        warm.bVector = CIVector(x: 0, y: 0, z: strength * 0.2, w: 0)
        warm.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let glow = warm.outputImage else { return image }

        let screen = CIFilter.screenBlendMode()
        screen.inputImage = glow
        screen.backgroundImage = image
        return screen.outputImage ?? image
    }

    // MARK: - Vignette

    private func applyVignette(_ look: FilmLook, to image: CIImage) -> CIImage {
        let v = CIFilter.vignette()
        v.inputImage = image
        v.intensity = Float(look.vignette * 1.4)
        v.radius = Float(min(image.extent.width, image.extent.height) / 900.0 + 1.2)
        return v.outputImage ?? image
    }
}
