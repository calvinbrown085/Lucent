#if !os(tvOS)
import AVFoundation
import CoreVideo
import Foundation
import MobileVLCKit

/// Adapts libVLC's memory output callbacks (installed via `LucentVLCSetVideoSink`)
/// into an `AVSampleBufferDisplayLayer` enqueue stream. One sink fans out to
/// every registered layer — the fullscreen view, the guide hero tile, the
/// iPad dock — and to the layer AVKit migrates into the PiP window.
///
/// Why memory callbacks: when the app backgrounds, iOS suspends GPU rendering
/// of foreground-only layers (Metal / EAGL), so VLC's normal view drawable
/// stops producing frames. Memory callbacks bypass VLC's GPU display path:
/// VLC decodes into a `CVPixelBuffer` we own, which we enqueue into the
/// display layer (a passive sink) on whatever thread VLC calls us on.
///
/// Format: we ask VLC for NV12 (bi-planar 4:2:0), which is what the
/// VideoToolbox decoder produces natively, so the hand-off is a copy rather
/// than a colour-space conversion. The display layer takes NV12 directly.
///
/// Threading: libVLC calls us from its video output thread. The display
/// layer's renderer is thread-safe for `enqueue`. Mutable state is guarded
/// by `lock`. The class is `nonisolated` because the project defaults every
/// type to `@MainActor`; without it the runtime's isolation assertion fires
/// on the first callback from VLC's thread (EXC_BREAKPOINT in
/// `dispatch_assert_queue`), which is exactly what shipped in build
/// 202609130158.
nonisolated final class PIPFrameSource: NSObject, LucentVLCVideoSink, @unchecked Sendable {
    private let lock = NSLock()

    // All access guarded by `lock`.
    private var displayTargets: [WeakDisplayLayer] = []
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var width: Int = 0
    private var height: Int = 0
    private var attachedPlayer: VLCMediaPlayer?

    /// Set once frames have started flowing for the current stream. AVKit's
    /// "is PiP possible" flag only flips true after the layer has content.
    private(set) var hasDeliveredFrame = false

    // MARK: - Wiring

    /// Install this sink on `player` (replacing any previous installation).
    /// MUST be called before `player.play()`. Pass `nil` to detach.
    func attach(to player: VLCMediaPlayer?) {
        lock.lock()
        let prior = attachedPlayer
        attachedPlayer = player
        hasDeliveredFrame = false
        lock.unlock()

        if let prior, prior !== player {
            LucentVLCSetVideoSink(prior, nil)
        }
        if let player {
            LucentVLCSetVideoSink(player, self)
        }
    }

    /// Register a display layer that should receive frames. Held weakly.
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

    /// Chroma we ask libVLC for. MPEG-2 (every ATSC 1.0 channel) decodes in
    /// software to planar I420, and VLC's deinterlacers output I420, so
    /// asking for I420 makes the hand-off a plane copy. Asking for NV12 made
    /// VLC insert swscale (~17% of app CPU in the iPhone trace: hscale +
    /// yuv2nv12cX_c, the latter plain C). CoreVideo displays y420 natively.
    private static let chroma: (fourcc: String, cvFormat: OSType, planes: Int) = {
        #if DEBUG
        // A/B hook for on-device profiling: LUCENT_CHROMA=NV12 restores the
        // swscale path so its cost can be measured against I420.
        if ProcessInfo.processInfo.environment["LUCENT_CHROMA"] == "NV12" {
            return ("NV12", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 2)
        }
        #endif
        return ("I420", kCVPixelFormatType_420YpCbCr8Planar, 3)
    }()

    private var frameCount = 0
    private var firstFrameAt: CFAbsoluteTime = 0
    private var lastLoggedAt: CFAbsoluteTime = 0
    private var loggedRendererFailure = false

    func videoSinkConfigureChroma(
        _ chroma: UnsafeMutablePointer<CChar>,
        width widthPtr: UnsafeMutablePointer<UInt32>,
        height heightPtr: UnsafeMutablePointer<UInt32>,
        pitches: UnsafeMutablePointer<UInt32>,
        lines: UnsafeMutablePointer<UInt32>
    ) -> UInt32 {
        let incoming = String(cString: [chroma[0], chroma[1], chroma[2], chroma[3], 0].map { UInt8(bitPattern: $0) })
        for (i, c) in Self.chroma.fourcc.utf8.enumerated() { chroma[i] = CChar(bitPattern: c) }

        let w = Int(widthPtr.pointee)
        let h = Int(heightPtr.pointee)
        guard w > 0, h > 0 else { return 0 }

        lock.lock()
        defer { lock.unlock() }
        width = w
        height = h
        rebuildPoolLocked()

        // Report the pitch CoreVideo actually allocates rather than guessing
        // an alignment: a mismatch here skews every row of the picture.
        guard let pool = pixelBufferPool else { return 0 }
        var probe: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &probe) == kCVReturnSuccess, let pb = probe else { return 0 }
        let planeCount = max(1, CVPixelBufferGetPlaneCount(pb))
        for i in 0..<planeCount {
            pitches[i] = UInt32(CVPixelBufferGetBytesPerRowOfPlane(pb, i))
            lines[i] = UInt32(CVPixelBufferGetHeightOfPlane(pb, i))
        }
        frameCount = 0
        firstFrameAt = 0
        loggedRendererFailure = false
        print("[Lucent][PIP] vout format: vlc offered \(incoming) \(w)x\(h), using \(Self.chroma.fourcc) planes=\(planeCount) pitches=\((0..<planeCount).map { pitches[$0] })")
        return UInt32(planeCount)
    }

    func videoSinkLockPlanes(_ planesOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer? {
        lock.lock()
        let pool = pixelBufferPool
        lock.unlock()
        guard let pool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer,
              CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess
        else { return nil }

        for i in 0..<CVPixelBufferGetPlaneCount(pb) {
            planesOut[i] = CVPixelBufferGetBaseAddressOfPlane(pb, i)
        }
        // +1 retain; balanced in display().
        return Unmanaged.passRetained(pb).toOpaque()
    }

    func videoSinkUnlockPicture(
        _ picture: UnsafeMutableRawPointer,
        planes: UnsafePointer<UnsafeMutableRawPointer>?
    ) {
        let pb = Unmanaged<CVPixelBuffer>.fromOpaque(picture).takeUnretainedValue()
        CVPixelBufferUnlockBaseAddress(pb, [])
    }

    func videoSinkDisplayPicture(_ picture: UnsafeMutableRawPointer) {
        let pb = Unmanaged<CVPixelBuffer>.fromOpaque(picture).takeRetainedValue()

        lock.lock()
        let fmt = formatDescription
        let targets = displayTargets.compactMap(\.layer)
        hasDeliveredFrame = true
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if firstFrameAt == 0 { firstFrameAt = now; lastLoggedAt = now }
        let shouldLog = now - lastLoggedAt >= 10
        if shouldLog { lastLoggedAt = now }
        let count = frameCount
        let elapsed = now - firstFrameAt
        lock.unlock()

        guard let fmt, !targets.isEmpty, let sb = makeSampleBuffer(from: pb, formatDescription: fmt) else { return }
        for layer in targets {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                if !loggedRendererFailure {
                    loggedRendererFailure = true
                    print("[Lucent][PIP] renderer failed: \(String(describing: renderer.error))")
                }
                renderer.flush()
            }
            renderer.enqueue(sb)
        }
        #if DEBUG
        if shouldLog, elapsed > 0 {
            let cpu = ProcessCPUSampler.shared.sample()
            let thermal = ProcessInfo.processInfo.thermalState
            print(String(format: "[Lucent][PIP] %d frames, %.1f fps, %d layers, process cpu %.0f%%, thermal %d",
                         count, Double(count) / elapsed, targets.count, cpu, thermal.rawValue))
            fflush(stdout) // stdout is a pipe under devicectl --console; don't let SIGTERM eat the numbers
        }
        #endif
    }

    func videoSinkCleanup() {
        lock.lock()
        pixelBufferPool = nil
        formatDescription = nil
        width = 0; height = 0
        hasDeliveredFrame = false
        lock.unlock()
    }

    // MARK: - Pool

    /// Caller must hold `lock`.
    private func rebuildPoolLocked() {
        formatDescription = nil
        var newFmt: CMVideoFormatDescription?
        if CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: CMVideoCodecType(Self.chroma.cvFormat),
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &newFmt
        ) == noErr {
            formatDescription = newFmt
        }

        let pixelBufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Self.chroma.cvFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
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
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sb = sampleBuffer else { return nil }

        // Live source with no presentation timeline: display as it arrives.
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

/// Process-wide CPU usage (% of one core) between successive calls, from
/// per-thread user+system time via `task_threads`. Diagnostics only.
nonisolated final class ProcessCPUSampler: @unchecked Sendable {
    static let shared = ProcessCPUSampler()
    private let lock = NSLock()
    private var lastCPUSeconds: Double = 0
    private var lastWall: CFAbsoluteTime = 0

    func sample() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.size))
        }
        var total: Double = 0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            total += Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        let deltaCPU = total - lastCPUSeconds
        let deltaWall = now - lastWall
        lastCPUSeconds = total
        lastWall = now
        guard lastWall > 0, deltaWall > 0, deltaCPU >= 0 else { return 0 }
        return 100 * deltaCPU / deltaWall
    }
}

nonisolated private struct WeakDisplayLayer {
    weak var layer: AVSampleBufferDisplayLayer?
}
#endif
