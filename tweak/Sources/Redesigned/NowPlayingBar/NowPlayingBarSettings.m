// The Now playing page of the redesign, under Player (App/Pages.m puts it there): the bar and the
// player behind it.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "NowPlayingBar.h"
#import "Redesigned/Player/Player.h"

// Mirrors the stored order as an index into the list below, for the Sources list's checkmark alone: the
// order itself is what the live cover reads, and the index is set from it as the list opens.
#define SGRKeyPlayerLiveCoverSourcesPicked @"spotifyglass.redesign.player.liveCoverSources.picked"

static NSArray<NSArray<NSString *> *> *liveCoverOrders(void) {
    return @[
        @[SGArtworkSourceAppleMusic, SGArtworkSourceSpotify],
        @[SGArtworkSourceSpotify, SGArtworkSourceAppleMusic],
        @[SGArtworkSourceAppleMusic],
        @[SGArtworkSourceSpotify],
    ];
}

static NSInteger liveCoverOrderIndex(void) {
    NSUInteger index = [liveCoverOrders() indexOfObject:SGRPlayerLiveCoverOrder()];
    return index == NSNotFound ? -1 : (NSInteger)index;
}

static NSArray<SGModRow *> *liveCoverRows(void) {
    SGModRow *live = SGSwitchRow(@"Live cover", @"The album's animated cover or the song's Canvas across the top of the player",
                                 SGRKeyPlayerLiveCover);
    NSArray<NSString *> *names = @[@"Apple Music, then Spotify", @"Spotify, then Apple Music", @"Apple Music only", @"Spotify only"];
    SGModRow *sources = SGChoiceRow(@"Sources", nil, SGRKeyPlayerLiveCoverSourcesPicked, names, 0);
    sources.value = ^NSString *{
        NSInteger index = liveCoverOrderIndex();
        return index >= 0 ? names[(NSUInteger)index] : @"None";
    };
    UIViewController *(^list)(void) = sources.page;
    sources.page = ^UIViewController *{
        SGSetInt(SGRKeyPlayerLiveCoverSourcesPicked, liveCoverOrderIndex());
        return list();
    };
    sources.chosen = ^(NSInteger index) {
        NSArray<NSArray<NSString *> *> *orders = liveCoverOrders();
        if (index >= 0 && index < (NSInteger)orders.count) SGRPlayerSetLiveCoverOrder(orders[(NSUInteger)index]);
    };
    sources.visible = ^BOOL { return SGEnabled(SGRKeyPlayerLiveCover); };
    return @[live, sources];
}

UIViewController *SGRNowPlayingBarSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Now playing" intro:SGRestartNote sections:@[
        SGSection(nil, @[
            SGHideRow(@"Hide the device button", nil, SGRHideBarConnect),
        ]),
        SGSection(nil, @[
            SGSwitchRow(@"Moving background", nil, SGRKeyPlayerMotion),
        ]),
        SGSection(nil, liveCoverRows()),
    ] footer:nil];
}
