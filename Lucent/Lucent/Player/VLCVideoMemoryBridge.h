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
/// may be modified to ask libVLC to rescale. The sink fills `pitches[i]`
/// (bytes per row) and `lines[i]` for each plane it will provide and returns
/// the plane count (1 for packed formats, 2 for NV12). Return 0 to refuse.
- (unsigned)videoSinkConfigureChroma:(char * _Nonnull)chroma
                               width:(unsigned int * _Nonnull)width
                              height:(unsigned int * _Nonnull)height
                             pitches:(unsigned int * _Nonnull)pitches
                               lines:(unsigned int * _Nonnull)lines;

/// Provide plane base addresses for libVLC to write the next frame into.
/// Return value is an opaque "picture" token handed back to
/// `-videoSinkUnlockPicture:planes:` and `-videoSinkDisplayPicture:`.
/// Return `NULL` if no buffer is available (libVLC drops the frame).
- (void * _Nullable)videoSinkLockPlanes:(void * _Nullable * _Nonnull)planesOut;

/// libVLC has finished writing into the buffer identified by `picture`.
- (void)videoSinkUnlockPicture:(void * _Nonnull)picture
                        planes:(void * _Nonnull const * _Nullable)planes;

/// libVLC's media clock says it is time to display `picture`.
- (void)videoSinkDisplayPicture:(void * _Nonnull)picture;

/// Stream is ending. Release per-stream resources.
- (void)videoSinkCleanup;
@end

/// Install or remove `sink` as `player`'s video output. Pass `nil` to remove.
/// MUST be called before `-play`; libVLC ignores changes to the video output
/// configuration once playback has started.
FOUNDATION_EXPORT
void LucentVLCSetVideoSink(VLCMediaPlayer *player, id<LucentVLCVideoSink> _Nullable sink);

NS_ASSUME_NONNULL_END

#endif // !TARGET_OS_TV

#endif /* VLCVideoMemoryBridge_h */
