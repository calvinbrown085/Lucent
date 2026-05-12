#ifndef VLCVideoMemoryBridge_h
#define VLCVideoMemoryBridge_h

#import <Foundation/Foundation.h>

#if !TARGET_OS_TV

@class VLCMediaPlayer;

NS_ASSUME_NONNULL_BEGIN

/// Receives decoded video frames from a `VLCMediaPlayer` via libVLC's memory
/// output callbacks. All methods may be invoked on libVLC's video output
/// thread — implementations must be thread-safe.
@protocol LucentVLCVideoSink <NSObject>

/// libVLC has decoded the stream and reports its natural format. `chroma`
/// points to a mutable 4-byte FourCC the sink may overwrite. `width`/`height`
/// may be modified to ask libVLC to rescale. `outPitchBytes` must be set
/// (bytes per row of the buffer the sink will hand back in `-lockPlanes:`).
/// Return YES to accept; NO refuses and stops decoding.
- (BOOL)videoSinkConfigureChroma:(char * _Nonnull)chroma
                           width:(unsigned int * _Nonnull)width
                          height:(unsigned int * _Nonnull)height
                   outPitchBytes:(unsigned int * _Nonnull)outPitchBytes;

/// Provide a pixel buffer base address for libVLC to write the next frame
/// into. Return value is an opaque "picture" token that libVLC will hand back
/// to `-videoSinkUnlockPicture:planes:` and `-videoSinkDisplayPicture:`;
/// implementations typically retain a `CVPixelBuffer` and pass its pointer.
/// Return `NULL` if no buffer is available (libVLC will drop the frame).
- (void * _Nullable)videoSinkLockPlanes:(void * _Nullable * _Nonnull)planeBaseOut;

/// libVLC has finished writing into the buffer identified by `picture`. The
/// sink may now read the pixels (e.g. wrap and enqueue for display).
- (void)videoSinkUnlockPicture:(void * _Nonnull)picture
                        planes:(void * _Nonnull const * _Nullable)planes;

/// libVLC's media clock says it is time to display the picture identified by
/// `picture`. The sink should enqueue the frame to its output layer(s) here.
- (void)videoSinkDisplayPicture:(void * _Nonnull)picture;

/// Stream is ending. Sink should release any per-stream resources (the
/// CVPixelBufferPool, etc).
- (void)videoSinkCleanup;
@end

/// Install or remove `sink` as `player`'s video output. Pass `nil` to remove.
/// MUST be called before `-play` on the player; libVLC ignores changes to the
/// video output configuration once playback has started.
///
/// The bridge keeps a strong reference to `sink` via an objc association on
/// `player`, so the caller does not need to retain it just for the callbacks
/// to stay valid — but a callback already in flight when this is called with
/// `nil` will complete with the old sink.
FOUNDATION_EXPORT
void LucentVLCSetVideoSink(VLCMediaPlayer *player, id<LucentVLCVideoSink> _Nullable sink);

NS_ASSUME_NONNULL_END

#endif // !TARGET_OS_TV

#endif /* VLCVideoMemoryBridge_h */
