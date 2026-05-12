#if !os(tvOS)
import AVFoundation
import CoreVideo
import Foundation
import MobileVLCKit

/// Adapts libVLC's memory output callbacks (installed via `LucentVLCSetVideoSink`)
/// into an `AVSampleBufferDisplayLayer` enqueue stream. The same sink can fan
/// out to multiple display layers — typically two: the in-app player view and
/// the hidden host view that AVPiP migrates into its floating window.
///
/// Why memory callbacks: when the app backgrounds, iOS suspends GPU rendering
/// of foreground-only layers (Metal / EAGL), so VLC's normal view drawable
/// would stop producing frames and any view-snapshot capture would yield
/// black. Memory callbacks bypass VLC's GPU display path entirely — VLC
/// decodes into a `CVPixelBuffer` we own, which we then enqueue into the
/// display layer (a passive sink) on whatever thread VLC calls us on.
///
/// Threading: libVLC calls our methods from its video output thread. The
/// AVSampleBufferDisplayLayer's renderer is thread-safe for `enqueue`, so we
/// enqueue directly from VLC's thread. Mutable state is guarded by `lock`.
final class PIPFrameSource: NSObject, LucentVLCVideoSink, @unchecked Sendable {
    private let lock = NSLock()

    // All access guarded by `lock`.
    private var displayTargets: [WeakDisplayLayer] = []
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var width: Int = 0
    private var height: Int = 0
    private var pitch: Int = 0
    private var attachedPlayer: VLCMediaPlayer?

    override init() {
        super.init()
    }

    // MARK: - Wiring

    /// Install this sink on `player` (replacing any previous installation).
    /// MUST be called before `player.play()`. Pass `nil` to detach from the
    /// current player.
    func attach(to player: VLCMediaPlayer?) {
        lock.lock()
        let prior = attachedPlayer
        attachedPlayer = player
        lock.unlock()

        if let prior, prior !== player {
            LucentVLCSetVideoSink(prior, nil)
        }
        if let player {
            LucentVLCSetVideoSink(player, self)
        }
    }

    /// Register a display layer that should receive enqueued frames. Held
    /// weakly — caller owns the layer's lifetime.
    func addDisplayTarget(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        defer { lock.unlock() }
        displayTargets.removeAll { $0.layer == nil || $0.layer === layer }
        displayTargets.append(WeakDisplayLayer(layer: layer))
    }

    func removeDisplayTarget(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        defer { lock.unlock() }
        displayTargets.removeAll { $0.layer == nil || $0.layer === layer }
    }

    // MARK: - LucentVLCVideoSink

    /// Negotiate the decoded format. Called on VLC's setup thread when the
    /// stream starts and again any time the format changes (e.g. resolution
    /// change). We accept whatever width/height VLC reports and ask for BGRA.
    func videoSinkConfigureChroma(
        _ chroma: UnsafeMutablePointer<CChar>,
        width widthPtr: UnsafeMutablePointer<UInt32>,
        height heightPtr: UnsafeMutablePointer<UInt32>,
        outPitchBytes: UnsafeMutablePointer<UInt32>
    ) -> Bool {
        // Force BGRA — matches kCVPixelFormatType_32BGRA so we can wrap a
        // CVPixelBuffer with no conversion on the display side.
        chroma[0] = CChar(UInt8(ascii: "B"))
        chroma[1] = CChar(UInt8(ascii: "G"))
        chroma[2] = CChar(UInt8(ascii: "R"))
        chroma[3] = CChar(UInt8(ascii: "A"))

        let w = Int(widthPtr.pointee)
        let h = Int(heightPtr.pointee)
        guard w > 0, h > 0 else { return false }

        // Pitch in bytes per row — 4 bytes/pixel for BGRA, aligned to 32.
        let rowBytes = w * 4
        let alignedPitch = (rowBytes + 31) & ~31
        outPitchBytes.pointee = UInt32(alignedPitch)

        lock.lock()
        defer { lock.unlock() }
        width = w
        height = h
        pitch = alignedPitch
        rebuildPoolLocked()
        return true
    }

    /// Hand libVLC a writeable BGRA buffer. Returns the CVPixelBuffer pointer
    /// as the opaque "picture" tag, retained until `display` (or `unlock` if
    /// display is skipped — which libVLC docs say never happens, but we'd
    /// rather not leak on edge cases).
    func videoSinkLockPlanes(_ planeBaseOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer? {
        lock.lock()
        let pool = pixelBufferPool
        lock.unlock()

        guard let pool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard createStatus == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        let lockStatus = CVPixelBufferLockBaseAddress(pb, [])
        guard lockStatus == kCVReturnSuccess else { return nil }

        planeBaseOut[0] = CVPixelBufferGetBaseAddress(pb)
        // Retain so the CMSampleBuffer in display() finds a live object.
        let retained = Unmanaged.passRetained(pb).toOpaque()
        return retained
    }

    func videoSinkUnlockPicture(
        _ picture: UnsafeMutableRawPointer,
        planes: UnsafePointer<UnsafeMutableRawPointer>?
    ) {
        let pb = Unmanaged<CVPixelBuffer>.fromOpaque(picture).takeUnretainedValue()
        CVPixelBufferUnlockBaseAddress(pb, [])
    }

    func videoSinkDisplayPicture(_ picture: UnsafeMutableRawPointer) {
        // Take ownership — balances the +1 retain in lock.
        let unmanagedPB = Unmanaged<CVPixelBuffer>.fromOpaque(picture)
        let pb = unmanagedPB.takeRetainedValue()

        lock.lock()
        let fmt = formatDescription
        let targets = displayTargets.compactMap(\.layer)
        lock.unlock()

        guard let fmt, !targets.isEmpty else { return }
        guard let sb = makeSampleBuffer(from: pb, formatDescription: fmt) else { return }

        for layer in targets {
            if layer.sampleBufferRenderer.status == .failed {
                layer.sampleBufferRenderer.flush()
            }
            layer.sampleBufferRenderer.enqueue(sb)
        }
    }

    func videoSinkCleanup() {
        lock.lock()
        pixelBufferPool = nil
        formatDescription = nil
        width = 0; height = 0; pitch = 0
        lock.unlock()
    }

    // MARK: - Pool

    /// Caller must hold `lock`.
    private func rebuildPoolLocked() {
        formatDescription = nil
        var newFmt: CMVideoFormatDescription?
        // CMVideoCodecType is a FourCharCode; for pixel-buffer-backed video
        // it's the pixel format type itself (BGRA → kCVPixelFormatType_32BGRA).
        let fmtStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: CMVideoCodecType(kCVPixelFormatType_32BGRA),
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &newFmt
        )
        if fmtStatus == noErr {
            formatDescription = newFmt
        }

        let pixelBufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferBytesPerRowAlignmentKey: pitch,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        // Keep a few buffers warm so lock() never has to block on allocation
        // while VLC's decoder is waiting.
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, pixelBufferAttrs as CFDictionary, &pool)
        pixelBufferPool = pool
    }

    private func makeSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        formatDescription: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sb = sampleBuffer else { return nil }

        // Tell AVSampleBufferDisplayLayer to skip its normal back-pressure
        // queueing — we're a live source with no presentation timeline.
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

private struct WeakDisplayLayer {
    weak var layer: AVSampleBufferDisplayLayer?
}
#endif
