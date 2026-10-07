// The playing track's video clip as the lock screen's animated artwork, on iOS 26 and up
// (LockScreenArtwork.x). The clip comes from AnimatedArtwork.h, from the sources in the order stored
// under SGKeyLockScreenArtworkSources.
#import <Foundation/Foundation.h>

// On until switched off; read at each track change, so it applies from the next track without a restart.
#define SGKeyLockScreenAnimatedArtwork @"spotifyglass.lockscreen.animatedartwork"
// An array of SGArtworkSource... constants (AnimatedArtwork.h), read and written with SGArtworkOrderIn and
// SGArtworkSetOrderIn.
#define SGKeyLockScreenArtworkSources @"spotifyglass.lockscreen.artworksources"

// Apple Music, then Spotify.
NSArray<NSString *> *SGLockScreenArtworkDefaultOrder(void);
// Whether this iOS shows animated artwork on the lock screen at all: MPMediaItemAnimatedArtwork, iOS 26.
BOOL SGLockScreenArtworkAvailable(void);
