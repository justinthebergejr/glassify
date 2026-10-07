// The album's motion cover, where Apple Music has one: the square video the Music app plays at the top of an
// album page in place of the still cover (most new albums, EPs and singles of the bigger artists; most others
// have none). Found by the artist and the title through the shared artwork service
// (Shared/AnimatedArtwork/AnimatedArtwork.h), as the player's live cover is, under a download slot of its own,
// and played by the header's hero (AlbumHeader.x).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Album.h"

static NSString *const kSlot = @"album";
static NSString *sg_wanted;   // the album last asked for, "artist\nalbum"

SGModRow *SGRAlbumMotionRow(void) {
    return SGWithSymbol(SGSwitchRow(@"Animated album covers", @"The album's motion cover from Apple Music at the top of its page, where there is one",
                                    SGRKeyAlbumMotion), @"play.square.stack");
}

void SGRAlbumMotionClip(NSString *artist, NSString *album, void (^done)(NSURL *file)) {
    if (!SGEnabled(SGRKeyAlbumMotion) || !artist.length || !album.length) {
        done(nil);
        return;
    }
    NSString *wanted = [NSString stringWithFormat:@"%@\n%@", artist, album];
    sg_wanted = wanted;
    SGArtworkCancelDownload(kSlot);
    SGArtworkFindClip(nil, artist, album, nil, @[SGArtworkSourceAppleMusic], NO, @"album cover", ^BOOL {
        return [sg_wanted isEqualToString:wanted];
    }, ^(SGArtworkClip *clip) {
        if (!clip) {
            done(nil);
            return;
        }
        SGArtworkDownload(kSlot, clip, ^(NSURL *file, NSString *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLog(@"redesign album: motion cover for \"%@\": %@", album, note ?: (file ? @"in" : @"none"));
                done([sg_wanted isEqualToString:wanted] ? file : nil);
            });
        });
    });
}
