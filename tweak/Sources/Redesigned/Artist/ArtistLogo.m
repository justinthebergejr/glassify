// The artist's logo, where Apple Music has one: the wordmark the Music app sets on an artist page in place of
// the name (Metallica, Taylor Swift, Linkin Park; most artists have none). Looked up by the name alone
// through the shared artwork service (Shared/AnimatedArtwork/AnimatedArtwork.h), as the animated covers are,
// and drawn by the header in the name's place (ArtistHeader.x).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Artist.h"

// Wide enough for the header's widest logo, about 280 pt, on a 3x screen.
static const CGFloat kLogoPixels = 900;

static NSCache<NSString *, id> *sg_pictures;   // per name: the UIImage, or NSNull for none
static NSMutableDictionary<NSString *, NSMutableArray *> *sg_asking;   // per name: who is waiting

SGModRow *SGRArtistLogosRow(void) {
    return SGWithSymbol(SGSwitchRow(@"Artist logos", @"The artist's logo from Apple Music in place of the name, where there is one",
                                    SGRKeyArtistLogos), @"signature");
}

static void answer(NSString *name, UIImage *logo) {
    [sg_pictures setObject:logo ?: (id)NSNull.null forKey:name];
    NSArray *waiting = sg_asking[name];
    [sg_asking removeObjectForKey:name];
    for (void (^waiter)(UIImage *) in waiting) waiter(logo);
}

void SGRArtistLogo(NSString *name, void (^done)(UIImage *logo)) {
    if (!SGEnabled(SGRKeyArtistLogos) || !name.length) {
        done(nil);
        return;
    }
    if (!sg_pictures) {
        sg_pictures = [NSCache new];
        sg_asking = [NSMutableDictionary dictionary];
    }
    id kept = [sg_pictures objectForKey:name];
    if (kept) {
        done(kept == NSNull.null ? nil : kept);
        return;
    }
    if (sg_asking[name]) {
        [sg_asking[name] addObject:[done copy]];
        return;
    }
    sg_asking[name] = [NSMutableArray arrayWithObject:[done copy]];
    SGAppleMusicArtistLogo(name, kLogoPixels, ^(NSURL *address) {
        SGLog(@"redesign artist: logo for \"%@\": %@", name, address ? @"found" : @"none");
        if (!address) {
            answer(name, nil);
            return;
        }
        [[NSURLSession.sharedSession dataTaskWithURL:address completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *logo = data.length ? [UIImage imageWithData:data scale:3] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!logo) SGLog(@"redesign artist: logo for \"%@\" not read: %@", name, error.localizedDescription ?: @"not a picture");
                answer(name, logo);
            });
        }] resume];
    });
}
