import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MCP

// The argument access, schema building, result constructors and MCPToolError this file used to
// carry live in MCPToolSupport.swift (shared with the headless MCP server). What is left here is
// the app-only image plumbing: CGImage in and out.

// MARK: - Image helpers

nonisolated enum MCPImages {
    /// PNG data for an image, downscaled to fit `maxWidth` when it is wider.
    static func pngData(_ image: CGImage, maxWidth: Int? = nil) throws -> Data {
        if let maxWidth, image.width > maxWidth {
            let scale = CGFloat(maxWidth) / CGFloat(image.width)
            let width = max(1, Int(CGFloat(image.width) * scale))
            let height = max(1, Int(CGFloat(image.height) * scale))
            guard let source = CGImageSourceCreateWithData(encodePNG(image) as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else {
                throw ExportError.encode
            }
            return encodePNG(thumbnail)
        }
        return encodePNG(image)
    }

    static func encodePNG(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        if let destination {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return data as Data
    }

    /// A tool result carrying the image as MCP image content.
    static func content(_ image: CGImage, maxWidth: Int? = nil) throws -> Tool.Content {
        let data = try pngData(image, maxWidth: maxWidth)
        return .image(data: data.base64EncodedString(), mimeType: "image/png", metadata: nil)
    }

    /// Reads an image file, whatever its color setup; masks get converted to 8-bit grayscale.
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageImportError.unreadable
        }
        return image
    }

    /// Redraws any image as 8-bit grayscale, so an RGBA PNG works as a layer mask.
    static func grayscale(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ExportError.render
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    /// "#RRGGBB" or "RRGGBB" into 0–1 components.
    static func color(_ hex: String) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let color = MCPColor.parse(hex) else { return nil }
        return (CGFloat(color.red), CGFloat(color.green), CGFloat(color.blue))
    }
}
