#if !os(tvOS)
import AVFoundation
import CoreVideo
import QuartzCore
import UIKit

/// Captures frames from a live `UIView` (the VLC drawable) and enqueues them
/// onto an `AVSampleBufferDisplayLayer` so AVKit's PIP can display them.
///
/// Why this exists: HDHR streams are MPEG-TS, decoded by VLC. AVPictureInPicture
/// needs an AVPlayerLayer or a sample-buffer-fed display layer; we use the
/// latter and pump VLC frames in via `UIView.drawHierarchy(in:afterScreenUpdates:)`,
/// which is the only public API path that reliably captures GPU-rendered
/// sublayer content (CAEAGLLayer / CAMetalLayer).
@MainActor
final class PIPFrameSource {
    /// Last render size reported by AVPiP. Used to bias capture sizing in the
    /// future if we want to track the PIP window's aspect ratio precisely.
    var targetRenderSize: CMVideoDimensions = CMVideoDimensions(width: 640, height: 360)

    private weak var sourceView: UIView?
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    private var displayLink: CADisplayLink?
    private var pixelBufferPool: CVPixelBufferPool?
    private var poolDimensions: (width: Int, height: Int) = (0, 0)

    func start(target: UIView?, into layer: AVSampleBufferDisplayLayer) {
        stop()
        self.sourceView = target
        self.displayLayer = layer

        let proxy = PIPDisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(PIPDisplayLinkProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true) { }
        displayLayer = nil
        sourceView = nil
        pixelBufferPool = nil
        poolDimensions = (0, 0)
    }

    fileprivate func tick() {
        guard let sourceView, let displayLayer else { return }
        let bounds = sourceView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Cap capture at 640x360 to keep snapshot cost predictable on iPhone.
        let scale = min(640 / bounds.width, 360 / bounds.height, 1)
        let width = max(2, Int(floor(bounds.width * scale)))
        let height = max(2, Int(floor(bounds.height * scale)))

        ensurePool(width: width, height: height)
        guard let pool = pixelBufferPool,
              let pixelBuffer = makePixelBuffer(from: pool) else { return }

        let captureSize = CGSize(width: width, height: height)
        guard render(view: sourceView, into: pixelBuffer, size: captureSize) else { return }
        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else { return }

        if displayLayer.sampleBufferRenderer.status == .failed {
            displayLayer.sampleBufferRenderer.flush()
        }
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
    }

    private func ensurePool(width: Int, height: Int) {
        if pixelBufferPool != nil, poolDimensions == (width, height) { return }
        let pixelBufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, pixelBufferAttrs as CFDictionary, &pool)
        self.pixelBufferPool = pool
        self.poolDimensions = (width, height)
    }

    private func makePixelBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func render(view: UIView, into pixelBuffer: CVPixelBuffer, size: CGSize) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: baseAddress,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return false }

        // CGBitmapContext has a bottom-up Y axis but UIKit drawing assumes
        // top-down. UIGraphicsPushContext doesn't apply the flip that
        // UIGraphicsImageRenderer does internally, so apply it manually —
        // otherwise drawHierarchy produces a vertically mirrored frame.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        // drawHierarchy expects the current UIGraphics context to render into.
        // afterScreenUpdates: false uses the most recent on-screen content,
        // which is what VLC has just composited. Passing true forces a sync
        // redraw and tanks FPS.
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        return view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        )
        guard formatStatus == noErr, let fmt = formatDesc else { return nil }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let bufferStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: fmt,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard bufferStatus == noErr, let sb = sampleBuffer else { return nil }

        // Live source: tell the display layer not to queue this buffer behind
        // a back-pressure window — show it now.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [CFMutableDictionary],
           let attach = attachments.first {
            CFDictionarySetValue(
                attach,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sb
    }
}

/// CADisplayLink retains its target. Use a tiny NSObject proxy with a weak
/// owner reference so the source can be deinit'd cleanly.
@MainActor
private final class PIPDisplayLinkProxy: NSObject {
    weak var owner: PIPFrameSource?
    init(owner: PIPFrameSource) { self.owner = owner }
    @objc func tick() { owner?.tick() }
}
#endif
