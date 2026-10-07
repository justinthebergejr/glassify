// Player redesign: the live cover. The playing track's animated artwork -- the album's 3:4 motion cover
// from Apple Music or the track's Canvas, whichever of the Live cover's sources answers first -- plays
// across the top of the player and fades into the field under the title, the way the Music app plays
// one. While it shows, the cover is hidden under it; until a clip is in, and for a track with none, the
// player is as it was.
//
// The clip comes through the shared artwork service (Shared/AnimatedArtwork/AnimatedArtwork.h), the lock
// screen's too, under a download slot of its own, so neither cancels the other's download. It plays muted and
// looped in the artwork field (PlayerField.x), over the moving colours, and goes while the lyrics are
// open and when the track moves to another album. While the player opens or closes it dissolves into the
// cover the morph flies (PlayerMorph.x), following the transition's progress, so a drag down crossfades
// from the clip to the cover and a cancelled drag crossfades back. A paused song, Reduce Motion, the app
// in the background or the player out of a window holds it on its frame.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Player.h"

static NSString *const kSlot = @"player";
// Where the clip starts fading into the field, as a share of its height.
static const CGFloat kFadeFrom = 0.68;
// How far past the bottom of the cover's band -- the top of the title -- the clip runs before it is gone.
static const CGFloat kRunOn = 72;

@interface SGRLiveCoverView : UIView
// Called on the main thread once the first frame of a clip can be shown.
@property (nonatomic, copy) void (^onReady)(void);
@property (nonatomic) BOOL held;
@property (nonatomic, readonly) BOOL ready;
- (void)playFile:(NSURL *)file identity:(NSString *)identity;
- (void)clear;
@end

@implementation SGRLiveCoverView {
    AVQueuePlayer *_player;
    AVPlayerLooper *_looper;
    AVPlayerLayer *_video;
    CAGradientLayer *_fade;
    NSString *_identity;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.alpha = 0;
    _video = [AVPlayerLayer layer];
    _video.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.layer addSublayer:_video];
    _fade = [CAGradientLayer layer];
    _fade.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fade.locations = @[@0, @(kFadeFrom), @1];
    self.layer.mask = _fade;
    [_video addObserver:self forKeyPath:@"readyForDisplay" options:0 context:NULL];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applyRate)
                                               name:UIApplicationWillEnterForegroundNotification object:nil];
    // Notification Centre or Control Centre over the app only makes it inactive, never backgrounded, and
    // the system pauses the clip on the way without saying so; coming back has to start it again.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(restart)
                                               name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applyRate)
                                               name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [_video removeObserver:self forKeyPath:@"readyForDisplay"];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _video.frame = self.bounds;
    _fade.frame = self.bounds;
    [CATransaction commit];
}

- (BOOL)ready {
    return _player && _video.readyForDisplay;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object != _video) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        SGLog(@"live cover: video ready %d, item status %ld, error %@", self.ready, (long)self->_player.currentItem.status,
              self->_player.currentItem.error.localizedDescription);
        if (self.ready && self.onReady) self.onReady();
    });
}

// The same clip again keeps playing where it is: the next track of an album shares its cover.
- (void)playFile:(NSURL *)file identity:(NSString *)identity {
    if (_player && [identity isEqualToString:_identity]) return;
    [self clear];
    _identity = [identity copy];
    _player = [AVQueuePlayer queuePlayerWithItems:@[]];
    _player.muted = YES;
    _player.preventsDisplaySleepDuringVideoPlayback = NO;
    _player.audiovisualBackgroundPlaybackPolicy = AVPlayerAudiovisualBackgroundPlaybackPolicyPauses;
    _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:[AVPlayerItem playerItemWithURL:file]];
    _video.player = _player;
    [self applyRate];
}

- (void)clear {
    [_looper disableLooping];
    [_player pause];
    _video.player = nil;
    _looper = nil;
    _player = nil;
    _identity = nil;
}

- (void)setHeld:(BOOL)held {
    _held = held;
    [self applyRate];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyRate];
}

- (void)applyRate {
    BOOL moving = !_held && self.window && !SGRReduceMotion()
                  && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    if (moving) [_player play];
    else [_player pause];
}

// The player can still claim to be playing while the layer shows a frozen frame, so play alone may do
// nothing: it is paused first, and picks up where it stopped.
- (void)restart {
    if (!_player) return;
    SGLog(@"live cover: active again, rate %.1f, status %ld", _player.rate, (long)_player.timeControlStatus);
    [_player pause];
    [self applyRate];
}

@end

static char kLiveKey;
static __weak SGRLiveCoverView *sg_live;
static NSString *sg_wanted;       // the track a clip is looked for
static NSString *sg_wantedAlbum;  // its artist and album, which name the Apple Music cover
static NSURL *sg_clip;            // the clip on disk once it is in
static NSString *sg_clipIdentity;
static NSString *sg_clipAlbum;    // the album an Apple Music clip is the cover of; nil for a Canvas
static BOOL sg_shown;
// The clip's first frame, which the field takes its colours from while the clip shows: a white cover with a
// green motion cover would otherwise keep the white field under the green clip.
static UIImage *sg_frame;
static NSString *sg_frameIdentity;

UIImage *SGRPlayerLiveCoverFrame(NSString **identity) {
    if (!sg_shown || !sg_frame) return nil;
    if (identity) *identity = sg_frameIdentity;
    return sg_frame;
}

// The clip's frame read off the main thread, once per clip; the field follows it once it is in.
static void readFrame(NSURL *file, NSString *clipIdentity) {
    NSString *identity = [@"live:" stringByAppendingString:clipIdentity ?: @""];
    if ([identity isEqualToString:sg_frameIdentity] && sg_frame) return;
    SGArtworkFirstFrame(file, ^(UIImage *image) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!image || ![clipIdentity isEqualToString:sg_clipIdentity]) return;
            sg_frame = image;
            sg_frameIdentity = identity;
            if (sg_shown) SGRPlayerFieldRefresh();
        });
    });
}

NSArray<NSString *> *SGRPlayerLiveCoverOrder(void) {
    return SGArtworkOrderIn(SGRKeyPlayerLiveCoverSources, @[SGArtworkSourceAppleMusic, SGArtworkSourceSpotify]);
}

void SGRPlayerSetLiveCoverOrder(NSArray<NSString *> *order) {
    SGArtworkSetOrderIn(SGRKeyPlayerLiveCoverSources, order);
}

static void setShown(BOOL shown, BOOL animated) {
    if (shown == sg_shown) return;
    sg_shown = shown;
    SGRLiveCoverView *live = sg_live;
    SGRPlayerSetCoverMuted(shown, animated);
    void (^apply)(void) = ^{ live.alpha = shown ? 1 : 0; };
    if (animated) SGRAnimate(SGRMotionFade, apply, nil);
    else apply();
    // The field's colours follow what is on screen: the clip's frame while it shows, the cover's again after.
    SGRPlayerFieldRefresh();
}

// The share of the open or close past which the clip has dissolved into the flown cover: it fades over
// the first stretch of a close and the last stretch of an open, while the cover is still the player's size.
static const CGFloat kMorphGone = 0.55, kMorphFull = 0.95;

CGFloat SGRPlayerLiveCoverMorph(CGFloat progress) {
    SGRLiveCoverView *live = sg_live;
    // Nothing to dissolve into: the flown cover carries the whole way, as without a live cover.
    if (!sg_clip || !live.ready || SGRPlayerLyricsOpen()) return 0;
    CGFloat x = MIN(1, MAX(0, (progress - kMorphGone) / (kMorphFull - kMorphGone)));
    CGFloat shown = x * x * (3 - 2 * x);
    // The clip owns the cover's place for the whole move, so the player's cover never pops in between.
    if (!sg_shown) {
        sg_shown = YES;
        SGRPlayerSetCoverMuted(YES, NO);
        SGRPlayerFieldRefresh();
    }
    live.alpha = shown;
    return shown;
}

void SGRPlayerLiveCoverRefresh(void) {
    SGRLiveCoverView *live = sg_live;
    BOOL moving = SGRPlayerIsTransitioning(), lyrics = SGRPlayerLyricsOpen();
    // While the player opens or closes the morph sets the clip's fade from the transition's progress
    // (SGRPlayerLiveCoverMorph); the end of the move settles it here.
    if (moving && live.window) return;
    BOOL wanted = sg_clip && live.window && !moving && !lyrics;
    if (wanted) [live playFile:sg_clip identity:sg_clipIdentity];
    BOOL shown = wanted && live.ready;
    // Logged when the answer or its reason changes, not on every layout pass.
    static NSString *said;
    NSString *why = [NSString stringWithFormat:@"%@ (clip %d, view %d, in window %d, ready %d, moving %d, lyrics %d, frame %@)",
                     shown ? @"shown" : @"hidden", sg_clip != nil, live != nil, live.window != nil, live.ready, moving, lyrics,
                     NSStringFromCGRect(live.frame)];
    if (![why isEqualToString:said]) {
        said = why;
        SGLog(@"live cover: %@", why);
    }
    setShown(shown, live.window && !moving);
}

static void forget(void) {
    sg_clip = nil;
    sg_clipIdentity = nil;
    sg_clipAlbum = nil;
    sg_frame = nil;
    sg_frameIdentity = nil;
}

static NSString *albumOf(SPTPlayerTrack *track) {
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    NSString *artist = metadata[@"artist_name"] ?: track.artistName, *album = metadata[@"album_title"];
    return artist.length && album.length ? [NSString stringWithFormat:@"%@\n%@", artist, album] : nil;
}

static void resolve(SPTPlayerTrack *track) {
    // Read on every track, so the switch needs no restart.
    if (!SGEnabled(SGRKeyPlayerLiveCover)) {
        if (sg_wanted || sg_clip) {
            sg_wanted = nil;
            forget();
            SGArtworkCancelDownload(kSlot);
            SGRPlayerLiveCoverRefresh();
            [sg_live clear];
            SGLog(@"live cover: switched off");
        }
        return;
    }
    NSString *uri = SGURIString(track.URI);
    if (!uri || [uri isEqualToString:sg_wanted]) return;
    sg_wanted = uri;
    sg_wantedAlbum = albumOf(track);
    SGArtworkCancelDownload(kSlot);
    // Another track of the album whose cover is playing keeps it while its own lookup runs, which comes
    // back with the same clip; anything else goes now, and the cover comes back until the next clip is in.
    if (!sg_clipAlbum || ![sg_clipAlbum isEqualToString:sg_wantedAlbum]) {
        forget();
        SGRPlayerLiveCoverRefresh();
    }
    NSDictionary *metadata = [track respondsToSelector:@selector(metadata)] ? track.metadata : nil;
    SGLog(@"live cover: looking for %@ in %@", uri, [SGRPlayerLiveCoverOrder() componentsJoinedByString:@", "]);
    id artistName = metadata[@"artist_name"] ?: track.artistName, albumTitle = metadata[@"album_title"];
    SGArtworkFindClip(uri, [artistName isKindOfClass:NSString.class] ? artistName : nil,
                      [albumTitle isKindOfClass:NSString.class] ? albumTitle : nil, metadata,
                      SGRPlayerLiveCoverOrder(), YES, @"live cover", ^BOOL {
        return [sg_wanted isEqualToString:uri];
    }, ^(SGArtworkClip *found) {
        NSString *source = found.source;
        if (!found) {
            forget();
            SGRPlayerLiveCoverRefresh();
            return;
        }
        NSString *album = [source isEqualToString:SGArtworkSourceAppleMusic] ? albumOf(track) : nil;
        SGArtworkDownload(kSlot, found, ^(NSURL *file, NSString *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLog(@"live cover: %@ from %@, %@", uri, source, note);
                if (![sg_wanted isEqualToString:uri]) return;
                if (!file) {
                    forget();
                    SGRPlayerLiveCoverRefresh();
                    return;
                }
                sg_clip = file;
                sg_clipIdentity = found.identifier;
                sg_clipAlbum = album;
                readFrame(file, found.identifier);
                SGRPlayerLiveCoverRefresh();
            });
        });
    });
}

void SGRPlayerLiveCoverLayIn(SGRArtworkField *field) {
    if (!field) return;
    SGRLiveCoverView *live = objc_getAssociatedObject(field, &kLiveKey);
    if (!live) {
        if (!SGEnabled(SGRKeyPlayerLiveCover)) return;
        live = [[SGRLiveCoverView alloc] initWithFrame:CGRectZero];
        live.held = SGPlayerState().isPaused;
        live.onReady = ^{ SGRPlayerLiveCoverRefresh(); };
        objc_setAssociatedObject(field, &kLiveKey, live, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"live cover: in the field");
    }
    sg_live = live;
    // The field draws in layers of its own, all made with it, so a subview stays over them.
    if (live.superview != field) [field addSubview:live];
    // Full width from the top of the player, down past the title, at least a 3:4 cover's height.
    CGFloat width = field.bounds.size.width;
    CGRect band = SGRPlayerArtworkAreaIn(field);
    CGFloat height = round(width * 4 / 3);
    if (!CGRectIsNull(band)) height = MAX(height, round(CGRectGetMaxY(band) + kRunOn));
    height = MIN(height, field.bounds.size.height);
    CGRect frame = CGRectMake(0, 0, width, height);
    if (!CGRectEqualToRect(live.frame, frame)) live.frame = frame;
}

@interface SGRLiveCoverWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGRLiveCoverWatcher

- (void)playerStateDidChange:(SPTPlayerState *)state {
    sg_live.held = state.isPaused;
    resolve(state.track);
}

@end

static SGRLiveCoverWatcher *sg_liveWatcher;

%ctor {
    if (!SGRedesignedUI()) return;
    sg_liveWatcher = [SGRLiveCoverWatcher new];
    SGAddPlayerStateObserver(sg_liveWatcher);
    SGRObservePlayerTransition(sg_liveWatcher, ^(id owner) {
        SGRPlayerLiveCoverRefresh();
    }, ^(id owner) {
        SGRPlayerLiveCoverRefresh();
    });
}
