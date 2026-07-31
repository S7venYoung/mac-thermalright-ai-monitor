// FrameRenderer.swift — Protocol for display set renderers
//
// Each display set implements this protocol.
// The frame loop calls render() to get a CGImage, then encodes it to JPEG.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

// MARK: - Protocol

protocol FrameRenderer {
    /// Render a full 1920x480 frame. Returns CGImage in device orientation.
    func render() -> CGImage?
}

// MARK: - JPEG Encoding

enum JPEGEncoder {

    // Reusable context for 180° rotation — prevents CG raster data leak
    nonisolated(unsafe) private static var rotateCtx: CGContext?

    /// Encode CGImage to JPEG Data with 180° rotation and brightness adjustment.
    /// Mirrors the official TRCC pipeline: encode at high quality and only step
    /// the quality down when the frame exceeds the firmware's 450KB drop guard.
    static func encode(
        _ image: CGImage, brightness: Int = 1, rotate: Bool = true, maxBytes: Int = 450_000
    ) -> Data? {
        let w = image.width
        let h = image.height

        var finalImage: CGImage

        if !rotate {
            // Reuse rotation context
            if rotateCtx == nil || rotateCtx!.width != w || rotateCtx!.height != h {
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                rotateCtx = CGContext(
                    data: nil, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            }
            guard let rotatedCtx = rotateCtx else { return nil }

            // 180° rotation
            rotatedCtx.saveGState()
            rotatedCtx.translateBy(x: CGFloat(w), y: CGFloat(h))
            rotatedCtx.scaleBy(x: -1, y: -1)
            rotatedCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            rotatedCtx.restoreGState()

            guard let rotated = rotatedCtx.makeImage() else { return nil }
            finalImage = rotated
        } else {
            finalImage = image
        }

        // Apply brightness if needed. The official app only ever dims by
        // compositing black over the frame; it never boosts above 100%.
        if let brightened = applyBrightness(finalImage, level: brightness) {
            finalImage = brightened
        }

        // Encode to JPEG with quality reduction loop
        let qualitySteps: [Double] = [0.95, 0.85, 0.75, 0.60, 0.45, 0.30]
        var data: Data? = nil
        for quality in qualitySteps {
            data = jpegData(from: finalImage, quality: quality)
            if let data, data.count <= maxBytes {
                return data
            }
        }
        return data ?? jpegData(from: finalImage, quality: 0.3)
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // Reusable context for the dim overlay — prevents CG raster data leak.
    nonisolated(unsafe) private static var brightnessCtx: CGContext?

    /// Dim by compositing semi-transparent black over the frame, matching the
    /// official TRCC behavior. Never raises brightness above 100%.
    private static func applyBrightness(_ image: CGImage, level: Int) -> CGImage? {
        let percent = Brightness.percent(for: level)
        if percent >= 100 { return image }

        let w = image.width
        let h = image.height
        if brightnessCtx == nil || brightnessCtx!.width != w || brightnessCtx!.height != h {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            brightnessCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = brightnessCtx else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let alpha = 1.0 - CGFloat(percent) / 100.0
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: alpha))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
