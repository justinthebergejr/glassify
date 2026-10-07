// Video clips for a track's artwork, from the sources the caller names, downloaded into a cache of
// their own and cut to the shape asked for. The lock screen (LockScreenArtwork.x) shows them; any other
// feature may ask for them through the functions below.
//
// Spotify: the track's own canvas, read off the metadata the player already has, no lookup.
// Apple Music: the album's animated cover from Apple Music's catalog API, reached with the developer token
// its web player ships in its script, the same way music.apple.com asks it. The cover is an HLS
// playlist whose segments are byte ranges of one MP4, so that one file is downloaded whole.
//
// Nothing is asked of the network while Spotify's own Data Saver is on. iOS Low Data Mode is not a
// gate: no request refuses a constrained network. No request carries anything of the account: the
// sessions are ephemeral and send no cookies.
#import <UIKit/UIKit.h>

extern NSString *const SGArtworkSourceAppleMusic;   // @"applemusic"
extern NSString *const SGArtworkSourceSpotify;      // @"spotify"

@interface SGArtworkClip : NSObject
@property (nonatomic, copy) NSString *identifier;   // stable per video, safe as a file name
@property (nonatomic, copy) NSURL *remoteURL;       // a single downloadable MP4
@property (nonatomic, copy) NSString *source;       // one of the two constants
@end

// The source order stored under `key` (an array of the two constants, in order, possibly one or none),
// `fallback` until something is stored; and storing one.
NSArray<NSString *> *SGArtworkOrderIn(NSString *key, NSArray<NSString *> *fallback);
void SGArtworkSetOrderIn(NSString *key, NSArray<NSString *> *order);

// Asks the sources in `order` until one has a video clip for the track, then calls `done` on the main queue
// with it, or with nil when none does. `tall` prefers a 3:4 portrait clip over a square one. `wanted` is
// checked after each asynchronous step; when it returns NO, stop and never call `done`. `tag` prefixes log
// lines. Main thread. Returns immediately (calls done(nil)) when SGSpotifyDataSaverOn() is YES.
void SGArtworkFindClip(NSString *trackURI, NSString *artist, NSString *album, NSDictionary *metadata,
                       NSArray<NSString *> *order, BOOL tall, NSString *tag,
                       BOOL (^wanted)(void), void (^done)(SGArtworkClip *clip));

// Downloads the clip into a size-capped cache (Caches/Glassify/Artwork, about 120 MB, least recently used
// files evicted) and calls `done` (any queue) with the local file, or nil and a short note. A cached file is
// answered at once. A new download in the same `slot` cancels the previous one in that slot; different
// slots never cancel each other. Two slots fetching the same clip must not corrupt or delete a file another
// slot may be playing. Main thread. A download that is cancelled never calls its `done`.
void SGArtworkDownload(NSString *slot, SGArtworkClip *clip, void (^done)(NSURL *file, NSString *note));
void SGArtworkCancelDownload(NSString *slot);

// The clip centre-cropped to `aspect` (width / height), re-encoded once and cached next to it; a clip
// already within 2% of that aspect is returned as is. `done` on any queue, nil on failure.
void SGArtworkCrop(NSURL *file, NSString *identifier, CGFloat aspect, void (^done)(NSURL *file));

// The clip's first frame (preferred transform applied), `done` on any queue, nil when unreadable.
void SGArtworkFirstFrame(NSURL *file, void (^done)(UIImage *frame));

// Apple Music's logo (wordmark) for the artist named `artist`, as a transparent PNG URL `pixelWidth` wide,
// on the main queue; nil when Apple Music has no such artist with that exact name (compare names
// case- and accent-insensitively, ignoring punctuation) or the artist has no logo. Remember answers per
// artist for the session. Nothing is asked when SGSpotifyDataSaverOn() is YES.
void SGAppleMusicArtistLogo(NSString *artist, CGFloat pixelWidth, void (^done)(NSURL *logo));

// Whether the user switched on Spotify's own Data Saver: -[SPTDataSaverController userEnabledDataSaver]
// of the controller Spotify made, captured by DataSaver.x. NO until Spotify has made one. iOS Low Data
// Mode, which the controller also follows, is not part of the answer.
BOOL SGSpotifyDataSaverOn(void);
