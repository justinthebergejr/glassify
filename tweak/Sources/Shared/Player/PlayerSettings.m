// The player's settings that do not depend on the look: the lock screen widget's flags, and the
// animated lock screen of Shared/AnimatedArtwork.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/AnimatedArtwork/LockScreenArtwork.h"
#import "PlayerSettings.h"

// Mirrors the stored order as an index into the list below, for the checkmark of the Sources list
// alone: the order itself is what the lock screen reads, and the index is set from it as the list opens.
#define SGKeyLockScreenArtworkSourcesPicked @"spotifyglass.lockscreen.artworksources.picked"

static NSArray<NSArray<NSString *> *> *artworkOrders(void) {
    return @[
        @[SGArtworkSourceAppleMusic, SGArtworkSourceSpotify],
        @[SGArtworkSourceSpotify, SGArtworkSourceAppleMusic],
        @[SGArtworkSourceAppleMusic],
        @[SGArtworkSourceSpotify],
    ];
}

static NSInteger artworkOrderIndex(void) {
    NSArray<NSString *> *order = SGArtworkOrderIn(SGKeyLockScreenArtworkSources, SGLockScreenArtworkDefaultOrder());
    NSUInteger index = [artworkOrders() indexOfObject:order];
    return index == NSNotFound ? -1 : (NSInteger)index;
}

// The switch and the order of the sources, or below iOS 26, which has no animated lock screen, a row
// saying so.
static NSArray<SGModRow *> *animatedArtworkRows(void) {
    if (!SGLockScreenArtworkAvailable()) {
        return @[SGStatRow(@"Animated lock screen", ^NSString *{ return @"Needs iOS 26"; })];
    }
    SGModRow *animated = SGSwitchRow(@"Animated lock screen",
                                     @"The album's animated cover or the song's Canvas behind the lock screen",
                                     SGKeyLockScreenAnimatedArtwork);
    NSArray<NSString *> *names = @[@"Apple Music, then Spotify", @"Spotify, then Apple Music", @"Apple Music only", @"Spotify only"];
    SGModRow *sources = SGChoiceRow(@"Sources", nil, SGKeyLockScreenArtworkSourcesPicked, names, 0);
    sources.value = ^NSString *{
        NSInteger index = artworkOrderIndex();
        return index >= 0 ? names[(NSUInteger)index] : @"None";
    };
    UIViewController *(^list)(void) = sources.page;
    sources.page = ^UIViewController *{
        SGSetInt(SGKeyLockScreenArtworkSourcesPicked, artworkOrderIndex());
        return list();
    };
    sources.chosen = ^(NSInteger index) {
        NSArray<NSArray<NSString *> *> *orders = artworkOrders();
        if (index >= 0 && index < (NSInteger)orders.count) SGArtworkSetOrderIn(SGKeyLockScreenArtworkSources, orders[(NSUInteger)index]);
    };
    sources.visible = ^BOOL {
        return SGEnabled(SGKeyLockScreenAnimatedArtwork);
    };
    return @[animated, sources];
}

UIViewController *SGLockScreenWidgetPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Lock screen widget" intro:SGRestartNote sections:@[
        SGSection(@"Controls", @[
            SGFlagRow(@"Like and dislike buttons", @"ios-feature-lockscreen.like_dislike_enabled"),
            SGFlagRow(@"Skip button on podcasts", @"ios-feature-lockscreen.skip_button_on_podcasts"),
            SGFlagRow(@"Chapter skip controls", @"ios-feature-lockscreen.enable_chapter_skip_controls"),
            SGFlagRow(@"Burst skip", @"ios-feature-lockscreen.burst_skip_enabled"),
        ]),
        SGNotedSection(@"Animated lock screen", animatedArtworkRows(),
                       @"Applies from the next song, without a restart. Nothing is looked up or downloaded while Spotify's Data Saver is on."),
        SGSection(@"Artwork", @[
            SGFlagRow(@"Animated artwork", @"ios-feature-lockscreen.animated_artwork_enabled"),
            SGFlagRow(@"Video artwork", @"ios-feature-lockscreen.vit_artwork_enabled"),
            SGFlagRow(@"Companion content", @"ios-feature-lockscreen.companion_content_enabled"),
        ]),
    ] footer:nil];
}
