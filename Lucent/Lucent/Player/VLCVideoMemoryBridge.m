#import "VLCVideoMemoryBridge.h"

#if !TARGET_OS_TV

#import <objc/runtime.h>
#import <string.h>

#import <MobileVLCKit/VLCMediaPlayer.h>

// libVLC's <vlc/libvlc*.h> headers are excluded from the MobileVLCKit module
// map, so we can't `#import` them under modules. The C symbols themselves are
// in the framework dylib though, so forward-declare just what we need.
typedef struct libvlc_media_player_t libvlc_media_player_t;

typedef unsigned (*libvlc_video_format_cb)(void **opaque, char *chroma,
                                           unsigned *width, unsigned *height,
                                           unsigned *pitches,
                                           unsigned *lines);
typedef void (*libvlc_video_cleanup_cb)(void *opaque);
typedef void *(*libvlc_video_lock_cb)(void *opaque, void **planes);
typedef void (*libvlc_video_unlock_cb)(void *opaque, void *picture, void *const *planes);
typedef void (*libvlc_video_display_cb)(void *opaque, void *picture);

extern void libvlc_video_set_callbacks(libvlc_media_player_t *mp,
                                       libvlc_video_lock_cb lock,
                                       libvlc_video_unlock_cb unlock,
                                       libvlc_video_display_cb display,
                                       void *opaque);
extern void libvlc_video_set_format_callbacks(libvlc_media_player_t *mp,
                                              libvlc_video_format_cb setup,
                                              libvlc_video_cleanup_cb cleanup);

// Forward-declare the private LibVLCBridging category. Its implementation
// lives in MobileVLCKit's binary; declaring it here lets the Obj-C compiler
// emit an objc_msgSend for `libVLCMediaPlayer` without our needing to import
// the framework's PrivateHeaders/ directory.
@interface VLCMediaPlayer (LucentLibVLCBridging)
@property (readonly) void *libVLCMediaPlayer;
@end

static const void *kLucentSinkAssociationKey = &kLucentSinkAssociationKey;

static unsigned lucent_setup_cb(void **opaque, char *chroma,
                                unsigned *width, unsigned *height,
                                unsigned *pitches, unsigned *lines) {
    id<LucentVLCVideoSink> sink = (__bridge id<LucentVLCVideoSink>)(*opaque);
    if (!sink) return 0;

    char fourcc[4];
    memcpy(fourcc, chroma, 4);
    unsigned pitchBytes = 0;
    if (![sink videoSinkConfigureChroma:fourcc width:width height:height outPitchBytes:&pitchBytes]) {
        return 0;
    }
    memcpy(chroma, fourcc, 4);
    pitches[0] = pitchBytes;
    lines[0]   = *height;
    return 1; // one buffer per frame
}

static void lucent_cleanup_cb(void *opaque) {
    id<LucentVLCVideoSink> sink = (__bridge id<LucentVLCVideoSink>)opaque;
    [sink videoSinkCleanup];
}

static void *lucent_lock_cb(void *opaque, void **planes) {
    id<LucentVLCVideoSink> sink = (__bridge id<LucentVLCVideoSink>)opaque;
    return [sink videoSinkLockPlanes:planes];
}

static void lucent_unlock_cb(void *opaque, void *picture, void *const *planes) {
    id<LucentVLCVideoSink> sink = (__bridge id<LucentVLCVideoSink>)opaque;
    [sink videoSinkUnlockPicture:picture planes:planes];
}

static void lucent_display_cb(void *opaque, void *picture) {
    id<LucentVLCVideoSink> sink = (__bridge id<LucentVLCVideoSink>)opaque;
    [sink videoSinkDisplayPicture:picture];
}

void LucentVLCSetVideoSink(VLCMediaPlayer *player, id<LucentVLCVideoSink> sink) {
    libvlc_media_player_t *mp = (libvlc_media_player_t *)[player libVLCMediaPlayer];
    if (!mp) return;

    if (sink == nil) {
        libvlc_video_set_callbacks(mp, NULL, NULL, NULL, NULL);
        libvlc_video_set_format_callbacks(mp, NULL, NULL);
        objc_setAssociatedObject(player, kLucentSinkAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    objc_setAssociatedObject(player, kLucentSinkAssociationKey, sink, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    void *opaque = (__bridge void *)sink;
    // Order: format callbacks first, then frame callbacks. libVLC docs require
    // both be installed before play() — we do that in Swift.
    libvlc_video_set_format_callbacks(mp, lucent_setup_cb, lucent_cleanup_cb);
    libvlc_video_set_callbacks(mp, lucent_lock_cb, lucent_unlock_cb, lucent_display_cb, opaque);
}

#endif // !TARGET_OS_TV
