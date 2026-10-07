// The playing track's clip as the lock screen's animated artwork.
//
// Spotify sets the system's now playing info itself, again and again; every dictionary it sets passes
// through here and leaves with the clip's MPMediaItemAnimatedArtwork under the one animated artwork key
// this iOS supports (3:4 where it has it, else 1:1), everything else untouched. When a clip is ready the
// last dictionary is sent again so the system takes it up at once.
//
// A new track clears the clip at once and looks for its own: found (AnimatedArtwork.h), downloaded in
// the "lock" slot, cut to the key's shape, its first frame read for the still the system shows while the
// video loads. The player re-reporting the same track (a pause, shuffle) changes nothing; a canvas that
// shows up in the track's metadata after the lookup began starts it again when Spotify comes before
// whatever is showing in the order.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "AnimatedArtwork.h"
#import "LockScreenArtwork.h"

static NSString *const kSlot = @"lock";
static NSString *const kTag = @"lock screen artwork";

NSArray<NSString *> *SGLockScreenArtworkDefaultOrder(void) {
    return @[SGArtworkSourceAppleMusic, SGArtworkSourceSpotify];
}

BOOL SGLockScreenArtworkAvailable(void) {
    if (@available(iOS 26.0, *)) return NSClassFromString(@"MPMediaItemAnimatedArtwork") != nil;
    return NO;
}

// Set once in the %ctor, read from any thread after.
static NSString *sg_key;
static CGFloat sg_aspect;

// Spotify may set the info from any thread; these are read and written under the lock.
static NSObject *sg_lock;
static NSDictionary *sg_lastInfo;
static CFAbsoluteTime sg_lastInfoAt;
static id sg_artwork;
static BOOL sg_lastSentWithArtwork;

// Main thread.
static NSString *sg_trackURI;
static NSUInteger sg_generation;
static NSString *sg_shownSource;
static BOOL sg_spotifyHadClip;

static NSDictionary *metadataOf(SPTPlayerTrack *track) {
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    return [metadata isKindOfClass:NSDictionary.class] ? metadata : nil;
}

// What AnimatedArtwork.m takes for a Spotify clip: a video canvas with an address.
static BOOL hasSpotifyClip(NSDictionary *metadata) {
    id type = metadata[@"canvas.type"], url = metadata[@"canvas.url"];
    return [type isKindOfClass:NSString.class] && [[type uppercaseString] hasPrefix:@"VIDEO"] && [url isKindOfClass:NSString.class] && [url length];
}

// While the last dictionary is still the previous track's, the clip waits for Spotify to set the new one,
// which carries it anyway; it is tried again every so often in case Spotify is slow to.
static const NSTimeInterval kResendRetry = 1;
static const NSUInteger kResendTries = 6;

// The last dictionary set, again, run on to now, with the player's artist on it: another feature puts
// a lyric line in that field on a timer. Nothing is sent when that dictionary is not the player's track.
static void resendTrying(NSUInteger triesLeft) {
    NSDictionary *info;
    CFAbsoluteTime at;
    @synchronized (sg_lock) {
        info = sg_lastInfo;
        at = sg_lastInfoAt;
    }
    if (!info) return;
    SPTPlayerTrack *track = SGPlayerState().track;
    NSString *title = info[MPMediaItemPropertyTitle], *playing = track.trackTitle;
    if (title && playing && ![title isEqual:playing]) {
        if (!triesLeft) return;
        NSUInteger generation = sg_generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kResendRetry * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            BOOL pending;
            @synchronized (sg_lock) { pending = sg_artwork != nil && !sg_lastSentWithArtwork; }
            if (generation == sg_generation && pending) resendTrying(triesLeft - 1);
        });
        return;
    }
    NSMutableDictionary *again = [info mutableCopy];
    NSNumber *elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    if (elapsed) {
        double rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
        again[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed.doubleValue + rate * (CFAbsoluteTimeGetCurrent() - at));
    }
    if (track.artistName.length) again[MPMediaItemPropertyArtist] = track.artistName;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = again;
}

static void resend(void) {
    resendTrying(kResendTries);
}

// `frame` filled into `size` (pixels), centred: the system drops a still whose shape is off the one it asked for.
static UIImage *filled(UIImage *frame, CGSize size) {
    if (size.width < 1 || size.height < 1 || frame.size.width < 1 || frame.size.height < 1) return frame;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    CGFloat scale = MAX(size.width / frame.size.width, size.height / frame.size.height);
    CGSize drawn = CGSizeMake(frame.size.width * scale, frame.size.height * scale);
    CGRect rect = CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2, drawn.width, drawn.height);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [frame drawInRect:rect];
    }];
}

static id artworkFor(SGArtworkClip *clip, NSURL *video, UIImage *frame) API_AVAILABLE(ios(26.0)) {
    NSString *identifier = [NSString stringWithFormat:@"glassify.%@.%ld", clip.identifier, lround(sg_aspect * 1000)];
    return [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:identifier
                                      previewImageRequestHandler:^(CGSize size, void (^completion)(UIImage *)) {
        completion(filled(frame, size));
    } videoAssetFileURLRequestHandler:^(CGSize size, void (^completion)(NSURL *)) {
        completion(video);
    }];
}

static void show(id artwork, NSString *source) {
    @synchronized (sg_lock) {
        sg_artwork = artwork;
    }
    sg_shownSource = source;
    resend();
}

// A track change: whatever was showing goes, and whatever was on its way for the last track is dropped.
static void clear(void) {
    sg_generation++;
    SGArtworkCancelDownload(kSlot);
    BOOL had;
    @synchronized (sg_lock) {
        had = sg_artwork != nil || sg_lastSentWithArtwork;
        sg_artwork = nil;
    }
    sg_shownSource = nil;
    if (had) resend();
}

// Main thread. Leaves what is showing in place until something better is ready.
static void lookUp(SPTPlayerTrack *track, NSString *uri) API_AVAILABLE(ios(26.0)) {
    NSUInteger generation = ++sg_generation;
    NSDictionary *metadata = metadataOf(track);
    sg_spotifyHadClip = hasSpotifyClip(metadata);
    if (!SGEnabled(SGKeyLockScreenAnimatedArtwork)) return;
    NSArray<NSString *> *order = SGArtworkOrderIn(SGKeyLockScreenArtworkSources, SGLockScreenArtworkDefaultOrder());
    if (!order.count) return;
    BOOL (^wanted)(void) = ^BOOL {
        return generation == sg_generation;
    };
    NSString *album = [metadata[@"album_title"] isKindOfClass:NSString.class] ? metadata[@"album_title"] : nil;
    BOOL tall = sg_aspect < 1;
    CGFloat aspect = sg_aspect;
    SGArtworkFindClip(uri, track.artistName, album, metadata, order, tall, kTag, wanted, ^(SGArtworkClip *clip) {
        if (!clip) return;
        SGArtworkDownload(kSlot, clip, ^(NSURL *file, NSString *note) {
            if (!file) {
                SGLog(@"%@: %@ not downloaded, %@", kTag, clip.identifier, note);
                return;
            }
            SGArtworkCrop(file, clip.identifier, aspect, ^(NSURL *video) {
                if (!video) {
                    SGLog(@"%@: %@ could not be cut to shape", kTag, clip.identifier);
                    return;
                }
                SGArtworkFirstFrame(video, ^(UIImage *frame) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!wanted() || !frame) return;
                        SGLog(@"%@: showing %@ (%@)", kTag, clip, video.lastPathComponent);
                        show(artworkFor(clip, video, frame), clip.source);
                    });
                });
            });
        });
    });
}

// The next track's clip, found, downloaded and cut to shape a few seconds into this one, so the clip is in
// the cache when the track changes and shows within a second instead of after a whole download (an Apple
// Music cover is several megabytes). Its own download slot, so it never cancels the playing track's; a
// track change drops it with everything else of the last track. Spotify's Data Saver stops it like the rest.
static const NSTimeInterval kPrefetchDelay = 4;
static NSString *const kPrefetchSlot = @"lock-next";
static NSString *sg_prefetchedURI;

static void prefetchNext(NSUInteger generation) API_AVAILABLE(ios(26.0)) {
    if (generation != sg_generation || !SGEnabled(SGKeyLockScreenAnimatedArtwork)) return;
    SPTPlayerState *state = SGPlayerState();
    NSArray *future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    SPTPlayerTrack *next = [future isKindOfClass:NSArray.class] ? future.firstObject : nil;
    if (![next respondsToSelector:@selector(URI)]) return;
    NSString *uri = SGURIString(next.URI);
    if (!uri.length || [uri isEqualToString:sg_trackURI] || [uri isEqualToString:sg_prefetchedURI]) return;
    NSArray<NSString *> *order = SGArtworkOrderIn(SGKeyLockScreenArtworkSources, SGLockScreenArtworkDefaultOrder());
    if (!order.count) return;
    sg_prefetchedURI = uri;
    NSDictionary *metadata = metadataOf(next);
    NSString *album = [metadata[@"album_title"] isKindOfClass:NSString.class] ? metadata[@"album_title"] : nil;
    NSString *artist = [next respondsToSelector:@selector(artistName)] ? next.artistName : nil;
    CGFloat aspect = sg_aspect;
    BOOL (^wanted)(void) = ^BOOL { return generation == sg_generation; };
    SGArtworkFindClip(uri, artist, album, metadata, order, aspect < 1, @"lock screen artwork (next)", wanted, ^(SGArtworkClip *clip) {
        if (!clip || !wanted()) return;
        SGArtworkDownload(kPrefetchSlot, clip, ^(NSURL *file, NSString *note) {
            if (!file) return;
            SGArtworkCrop(file, clip.identifier, aspect, ^(NSURL *video) {
                if (video) SGLog(@"%@: next track's clip ready ahead, %@", kTag, clip.identifier);
            });
        });
    });
}

// Main thread: a canvas that came into the playing track's metadata after its lookup began.
static void checkLateCanvas(void) API_AVAILABLE(ios(26.0)) {
    if (sg_spotifyHadClip || !sg_trackURI) return;
    SPTPlayerTrack *track = SGPlayerState().track;
    if (![SGURIString(track.URI) isEqualToString:sg_trackURI]) return;
    if (!hasSpotifyClip(metadataOf(track))) return;
    sg_spotifyHadClip = YES;
    if (!SGEnabled(SGKeyLockScreenAnimatedArtwork)) return;
    NSArray<NSString *> *order = SGArtworkOrderIn(SGKeyLockScreenArtworkSources, SGLockScreenArtworkDefaultOrder());
    NSUInteger spotify = [order indexOfObject:SGArtworkSourceSpotify];
    if (spotify == NSNotFound) return;
    if (sg_shownSource && [order indexOfObject:sg_shownSource] <= spotify) return;
    SGLog(@"%@: a canvas came late for %@, looking again", kTag, sg_trackURI);
    lookUp(track, sg_trackURI);
}

@interface SGLockArtworkWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGLockArtworkWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    if (@available(iOS 26.0, *)) {
        NSString *uri = SGURIString(state.track.URI);
        if (!uri.length) return;
        if ([uri isEqualToString:sg_trackURI]) {
            checkLateCanvas();
            return;
        }
        sg_trackURI = uri;
        clear();
        SGArtworkCancelDownload(kPrefetchSlot);
        sg_prefetchedURI = nil;
        lookUp(state.track, uri);
        NSUInteger generation = sg_generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPrefetchDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            prefetchNext(generation);
        });
    }
}
@end

static SGLockArtworkWatcher *sg_watcher;

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    id artwork;
    @synchronized (sg_lock) {
        sg_lastInfo = info;
        sg_lastInfoAt = CFAbsoluteTimeGetCurrent();
        artwork = info ? sg_artwork : nil;
        sg_lastSentWithArtwork = artwork != nil;
    }
    // Spotify sets the info as the track's metadata fills in, which is when a late canvas shows.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 26.0, *)) checkLateCanvas();
    });
    if (!artwork) {
        %orig;
        return;
    }
    NSMutableDictionary *withArtwork = [info mutableCopy];
    withArtwork[sg_key] = artwork;
    %orig(withArtwork);
}
%end

%ctor {
    if (@available(iOS 26.0, *)) {
        if (!SGLockScreenArtworkAvailable()) return;
        NSArray<NSString *> *keys = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys;
        if ([keys containsObject:MPNowPlayingInfoProperty3x4AnimatedArtwork]) {
            sg_key = MPNowPlayingInfoProperty3x4AnimatedArtwork;
            sg_aspect = 3.0 / 4.0;
        } else if ([keys containsObject:MPNowPlayingInfoProperty1x1AnimatedArtwork]) {
            sg_key = MPNowPlayingInfoProperty1x1AnimatedArtwork;
            sg_aspect = 1;
        }
        SGLog(@"%@: supported keys %@, using %@", kTag, [keys componentsJoinedByString:@", "], sg_key ?: @"none");
        if (!sg_key) return;
        sg_lock = [NSObject new];
        %init;
        sg_watcher = [SGLockArtworkWatcher new];
        SGAddPlayerStateObserver(sg_watcher);
    }
}
