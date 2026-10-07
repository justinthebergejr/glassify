// Spotify's Data Saver switch, read off the controller Spotify makes for it. The controller is captured
// as it is made and again whenever it works out its state, so one made before this file's hooks were
// in place is still found the first time its state changes.
#import "Core/SGCore.h"
#import "AnimatedArtwork.h"

@protocol SGDataSaverController <NSObject>
- (BOOL)userEnabledDataSaver;
@end

static __weak id<SGDataSaverController> sg_dataSaver;

BOOL SGSpotifyDataSaverOn(void) {
    id<SGDataSaverController> controller = sg_dataSaver;
    if (![controller respondsToSelector:@selector(userEnabledDataSaver)]) return NO;
    return controller.userEnabledDataSaver;
}

static void capture(id controller) {
    if (!controller) return;
    BOOL first = sg_dataSaver == nil;
    sg_dataSaver = controller;
    if (first) SGLog(@"data saver: controller found, user switch %d", SGSpotifyDataSaverOn());
}

%hook SPTDataSaverController
- (id)initWithPreferences:(id)preferences localSettings:(id)localSettings automaticDataSaverController:(id)automatic
     localOverrideEnabled:(BOOL)localOverride dynamicDataSaverStreamQualityEnabled:(BOOL)dynamicQuality {
    id controller = %orig;
    capture(controller);
    return controller;
}

- (void)updateDataSaverState {
    BOOL before = SGSpotifyDataSaverOn();
    %orig;
    capture(self);
    BOOL after = SGSpotifyDataSaverOn();
    if (before != after) SGLog(@"data saver: user switch %d", after);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"SPTDataSaverController"]);
}
