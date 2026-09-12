import AppKit
import CoreFoundation
import Foundation
import ImageIO

@MainActor
final class VPhoneHostScreenAdapter: VPhoneHostScreen {
    private weak var captureView: VPhoneVirtualMachineView?
    private let screenRecorder: VPhoneScreenRecorder?
    private let screenWidth: Int
    private let screenHeight: Int
    private static let compactScale = 3

    init(view: VPhoneVirtualMachineView, recorder: VPhoneScreenRecorder, width: Int, height: Int) {
        captureView = view
        screenRecorder = recorder
        screenWidth = width
        screenHeight = height
    }

    var isAvailable: Bool { captureView?.window != nil }

    func saveScreenshot(to url: URL) async throws -> URL {
        guard let view = captureView, let recorder = screenRecorder, isAvailable else {
            throw CocoaError(.featureUnsupported)
        }
        return try await recorder.saveScreenshot(view: view, to: url)
    }

    func tap(x: Double, y: Double) {
        captureView?.injectTap(pixelX: x, pixelY: y, screenWidth: screenWidth, screenHeight: screenHeight)
    }

    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) {
        captureView?.injectSwipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                                 screenWidth: screenWidth, screenHeight: screenHeight, durationMs: durationMs)
    }

    /// Capture current screen as a small JPEG, returned as base64.
    ///
    /// Defaults to a compact grayscale JPEG (the AI path: small + fast). Pass
    /// `color: true` (the `"color":true` socket flag) for an sRGB JPEG at higher
    /// quality — used by the live dashboard so its stream matches the on-screen
    /// vphone-cli window. The underlying capture is always color (32BGRA); only
    /// the encode differs.
    func captureCompactScreenshot(color: Bool = false) async -> String? {
        guard let recorder = screenRecorder, let view = captureView, view.window != nil else {
            return nil
        }

        // Reuse the existing private-API capture
        guard let cgImage = await captureStillImage(recorder: recorder, view: view) else {
            return nil
        }

        let dstW = cgImage.width / Self.compactScale
        let dstH = cgImage.height / Self.compactScale

        let ctx: CGContext?
        if color {
            // sRGB context, premultiplied alpha (BGRA-compatible).
            ctx = CGContext(
                data: nil, width: dstW, height: dstH,
                bitsPerComponent: 8, bytesPerRow: dstW * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        } else {
            // Grayscale context (compact, high-contrast — the AI default).
            ctx = CGContext(
                data: nil, width: dstW, height: dstH,
                bitsPerComponent: 8, bytesPerRow: dstW,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }
        guard let ctx else { return nil }

        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))

        guard let outImage = ctx.makeImage() else { return nil }

        // Color: a touch more quality since it's for human viewing; gray stays lean.
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let quality: CGFloat = color ? 0.6 : 0.35
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, outImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return (data as Data).base64EncodedString()
    }

    /// Access the recorder's private capture method via the existing async wrapper.
    private func captureStillImage(recorder: VPhoneScreenRecorder, view: NSView) async -> CGImage? {
        // Use the public saveScreenshot path but intercept before encoding.
        // We call the recorder's internal captureStillImage indirectly by
        // going through saveScreenshot to a temp file, then reading back.
        // This is suboptimal but avoids exposing internal API.
        //
        // Better: use the same private API directly.
        guard let vmView = view as? VPhoneVirtualMachineView,
              let display = vmView.recordingGraphicsDisplay
        else { return nil }

        return await withCheckedContinuation { continuation in
            let selector = NSSelectorFromString("_takeScreenshotWithCompletionHandler:")
            guard display.responds(to: selector),
                  let cls = object_getClass(display),
                  let method = class_getInstanceMethod(cls, selector)
            else {
                continuation.resume(returning: nil)
                return
            }

            typealias CompletionBlock = @convention(block) (AnyObject?) -> Void
            typealias IMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void

            let impl = method_getImplementation(method)
            let fn = unsafeBitCast(impl, to: IMP.self)

            let block: CompletionBlock = { imageObject in
                guard let imageObject else {
                    continuation.resume(returning: nil)
                    return
                }
                if let nsImage = imageObject as? NSImage {
                    continuation.resume(returning: nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    return
                }
                let cf = imageObject as CFTypeRef
                if CFGetTypeID(cf) == CGImage.typeID {
                    continuation.resume(returning: (cf as! CGImage))
                    return
                }
                continuation.resume(returning: nil)
            }
            let blockObj = unsafeBitCast(block, to: AnyObject.self)
            fn(display, selector, blockObj)
        }
    }

}
