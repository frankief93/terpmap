import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Applies a film look to a captured photo while preserving its EXIF metadata.
enum PhotoProcessor {

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any,
        .cacheIntermediates: false,
    ])

    /// Returns styled HEIF/JPEG data, or nil to fall back to the original.
    static func applyLook(_ look: FilmLook, toImageData data: Data) -> Data? {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return nil }
        let styled = LookEngine.shared.apply(look, to: image)

        guard let cgImage = context.createCGImage(
            styled,
            from: styled.extent,
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)
        ) else { return nil }

        // Carry the original metadata across, minus the orientation (now baked in).
        // The nested TIFF/EXIF copies must be scrubbed too, or strict readers
        // rotate the already-rotated pixels again.
        var properties = originalProperties(from: data)
        properties[kCGImagePropertyOrientation as String] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            properties[kCGImagePropertyExifDictionary as String] = exif
        }

        let out = NSMutableData()
        let type = UTType.heic.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        var options = properties
        options[kCGImageDestinationLossyCompressionQuality as String] = 0.9
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func originalProperties(from data: Data) -> [String: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return [:] }
        return props
    }
}
