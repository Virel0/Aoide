import CoreImage
import SwiftUI
import UIKit

/// Derives a page tint from album art.
///
/// This is the iOS 26 Apple Music signature: an album page washed in a colour taken
/// from its cover. There is no system API for it, so the colour is sampled here.
///
/// The naive version — average the whole image — reliably produces mud, because
/// averaging opposing hues cancels them. This instead samples a small grid, discards
/// near-white and near-black (sleeve borders and letterboxing, which dominate an
/// average without being what anyone would call the record's colour), and picks the
/// most saturated cluster. Then it forces the result into a band of lightness where
/// text stays legible in both themes.
actor ArtworkColorExtractor {
    static let shared = ArtworkColorExtractor()

    private var cache: [URL: ArtworkPalette] = [:]

    func palette(for url: URL) async -> ArtworkPalette? {
        if let cached = cache[url] { return cached }
        guard let image = await ArtworkCache.shared.image(for: url) else { return nil }
        guard let palette = ArtworkPalette(image: image) else { return nil }
        cache[url] = palette
        return palette
    }
}

/// A colour sampled from artwork, already adjusted for legibility.
struct ArtworkPalette: Sendable, Hashable {
    /// The background wash. Deliberately desaturated and darkened/lightened into a
    /// band where white or black text keeps its contrast.
    let tint: Color
    /// Whether that background wants light text on it.
    let prefersLightForeground: Bool

    init?(image: UIImage) {
        guard let dominant = Self.dominantHue(in: image) else { return nil }
        let (hue, saturation, brightness) = dominant

        // Clamp into a usable band. An unmodified sample is either so pale the page
        // looks broken or so dark it swallows the artwork.
        let usableSaturation = min(max(saturation, 0.18), 0.62)
        let usableBrightness = min(max(brightness, 0.26), 0.52)

        tint = Color(hue: hue, saturation: usableSaturation, brightness: usableBrightness)
        prefersLightForeground = usableBrightness < 0.62
    }

    /// Samples a grid rather than averaging, then takes the most saturated bucket.
    private static func dominantHue(in image: UIImage) -> (hue: Double, saturation: Double, brightness: Double)? {
        let side = 24
        guard let cgImage = image.cgImage else { return nil }

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Twelve hue buckets. Ranked by summed saturation-squared so a small vivid
        // area beats a large muted one — which is usually the colour a person would
        // actually name if you showed them the sleeve.
        let bucketCount = 12
        var weight = [Double](repeating: 0, count: bucketCount)
        var hueSum = [Double](repeating: 0, count: bucketCount)
        var saturationSum = [Double](repeating: 0, count: bucketCount)
        var brightnessSum = [Double](repeating: 0, count: bucketCount)
        var samples = [Int](repeating: 0, count: bucketCount)

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255

            let (h, s, v) = rgbToHSV(r: r, g: g, b: b)
            // Skip near-grey, near-black and near-white: sleeve borders and
            // letterboxing, which win on area without being the record's colour.
            guard s > 0.12, v > 0.12, v < 0.96 else { continue }

            let bucket = min(Int(h * Double(bucketCount)), bucketCount - 1)
            weight[bucket] += s * s
            hueSum[bucket] += h
            saturationSum[bucket] += s
            brightnessSum[bucket] += v
            samples[bucket] += 1
        }

        guard
            let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
            samples[best] > 0
        else {
            // A genuinely monochrome cover. Better to fall back to the plain
            // background than to invent a colour.
            return nil
        }

        let n = Double(samples[best])
        return (
            hue: hueSum[best] / n,
            saturation: saturationSum[best] / n,
            brightness: brightnessSum[best] / n
        )
    }

    private static func rgbToHSV(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV

        var hue: Double = 0
        if delta > 0 {
            if maxV == r {
                hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                hue = (b - r) / delta + 2
            } else {
                hue = (r - g) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxV == 0 ? 0 : delta / maxV, maxV)
    }
}
