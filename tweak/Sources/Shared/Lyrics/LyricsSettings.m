// The Lyrics page's parts; App/Pages.m assembles the page.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Lyrics.h"
#import "Shared/LockScreenLyrics/LockScreenLyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"

static NSString *const kSpicyDashboard = @"https://developers.spicylyrics.org/dashboard";

// The user's own key: Spicy Lyrics' terms give each person one and forbid shipping it, so it is pasted here.
static void askForSpicyKey(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Spicy Lyrics key"
        message:@"Make a free account at developers.spicylyrics.org, create a publishable key (sl_pk_…) and allow "
                 "requests without an origin, then paste it here. It stays on this phone and is sent only to Spicy Lyrics."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = SGSpicyLyricsKey();
        field.placeholder = @"sl_pk_…";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.secureTextEntry = YES;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Get a key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:kSpicyDashboard] options:@{} completionHandler:nil];
    }]];
    if (SGSpicyLyricsKey()) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove key" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            SGSetSpicyLyricsKey(nil);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        SGSetSpicyLyricsKey(alert.textFields.firstObject.text);
    }]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static SGModRow *spicyKeyRow(void) {
    return SGStatActionRow(@"Spicy Lyrics key", @"Needed for Spicy Lyrics, from developers.spicylyrics.org", ^NSString *{
        NSString *key = SGSpicyLyricsKey();
        return key.length > 4 ? [@"…" stringByAppendingString:[key substringFromIndex:key.length - 4]] : @"Not set";
    }, ^{ askForSpicyKey(); });
}

SGModSection *SGLyricsSourcesSection(BOOL namingSource) {
    SGModRow *sources = SGPageRow(@"Sources", ^UIViewController *{ return SGLyricsSourcesPage(); });
    sources.value = ^NSString *{
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSString *key in SGLyricsOrder()) [names addObject:SGLyricsProviderFor(key).name];
        return names.count ? [names componentsJoinedByString:@", "] : @"Off";
    };
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObjects:sources,
        SGOptionRow(@"Lyrics for every track", @"Even where Spotify has none", SGKeyLyricsAllTracks), nil];
    if (namingSource) [rows addObject:SGOptionRow(@"Show source", nil, SGKeyLyricsCredit)];
    // Spicy Lyrics answers only where its credit can be shown, the redesign's lyrics view.
    if (namingSource) [rows addObject:spicyKeyRow()];
    return SGSection(@"Sources", rows);
}

SGModRow *SGLockScreenLyricsRow(void) {
    return SGOptionRow(@"Lock screen lyrics", @"Current line in place of the artist", SGKeyLockScreenLyrics);
}

SGModRow *SGLyricsTranslationLanguageRow(void) {
    SGModRow *row = SGChoiceRow(@"Translation language", nil, SGKeyLyricsTranslationLanguage, SGLyricsTranslationLanguageNames(), 0);
    row.choiceFooter = @"Used when the lyrics come with translations. Any shows the first.";
    return row;
}

// Only the redesign's lyrics view sweeps words.
SGModRow *SGLyricsWordTimingRow(void) {
    return SGOptionRow(@"Simulate word timing", nil, SGKeyLyricsSimulateWords);
}
