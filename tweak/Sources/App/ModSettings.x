// Settings: a Glassify row at the top of Spotify's settings list opens the mod's own page: the
// Appearance card with Redesigned UI and the app icon, then Features, a page per part of Spotify, each
// holding what that part offers in the stored look (App/Pages.m: Navbar, Player, and Home & Library for the
// native look), Audio effects (Shared/AudioEffects, in either look and applying straight away) and the Live
// Activity; Advanced, Privacy & clutter, Labs and All flags (a searchable list of every flag with an override
// per flag); and About, the build, its licences, the tour and the settings backup. Holding Home on the tab bar
// opens it too. This build checks for no updates and asks for nothing: no update notice, no donation sheet, no
// links out. The tweaks read the switches when they run, so a change shows after Spotify restarts; the tab
// editor on the Navbar page applies as soon as the bar lays out again.
//
// Tree (trees/settings.txt): SettingsListViewController.view > SettingsListCollectionView of
//   Element_List cells 402x56: 24pt icon at x 12, 13pt white title and 11pt grey subtitle at
//   x 48, 12pt chevron on the right. A pushed page (trees/settings notifications opened.txt) is a
//   UITableView bg #121212: header with an 11pt grey description at (16, 24), 53pt cells with the
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Settings/SGModPage.h"
#import "Native/Home/Home.h"
#import "Shared/Privacy/Privacy.h"
#import "Shared/Flags/Flags.h"
#import "Shared/AudioEffects/AudioEffectsPage.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "App/About/About.h"
#import "Pages.h"

static const CGFloat kRowHeight = 56;
static char kRowKey, kInsetKey;

static SGModRow *pageRow(NSString *title, NSString *symbol, UIViewController *(^page)(void)) {
    return SGWithSymbol(SGPageRow(title, page), symbol);
}

static UIViewController *modSettingsPage(void) {
    NSMutableArray<SGModSection *> *sections = [NSMutableArray array];
    // A build the lock screen cannot open leads the page, above the tweaks: it is the one thing here
    // that no switch can put right, and it is worth reading before anything else.
    SGModRow *signing = SGSigningWarningRow();
    if (signing) [sections addObject:SGSection(nil, @[signing])];
    SGModRow *about = pageRow(@"About", @"info.circle", ^UIViewController *{ return SGAboutPage(); });
    about.value = ^NSString *{ return @(SG_VERSION); };
    // The audio effects work on the sound, so both looks have them, with what they are doing beside the chevron.
    SGModRow *audioEffects = pageRow(@"Audio effects", @"slider.vertical.3", ^UIViewController *{ return SGDSPSettingsPage(); });
    audioEffects.value = ^NSString *{ return SGDSPSummary(); };
    // Home & Library holds only the native look's switches, so the redesign has no such page; the
    // Live Activity works under both, and only where ActivityKit's card does.
    NSMutableArray<SGModRow *> *parts = [NSMutableArray arrayWithArray:@[
        pageRow(@"Navbar", @"dock.rectangle", ^UIViewController *{ return SGNavbarPage(); }),
        pageRow(@"Player", @"play.circle", ^UIViewController *{ return SGPlayerSettingsPage(); }),
        audioEffects,
    ]];
    if (@available(iOS 17.0, *)) {
        SGModRow *liveActivity = pageRow(@"Live Activity", @"platter.filled.top.iphone", ^UIViewController *{ return SGLiveActivitySettingsPage(); });
        liveActivity.value = ^NSString *{ return SGLiveActivitySummary(); };
        [parts addObject:liveActivity];
    }
    if (!SGRedesignedUIStored()) [parts addObject:pageRow(@"Home & Library", @"house", ^UIViewController *{ return SGHomeSettingsPage(); })];
    [sections addObjectsFromArray:@[
        SGAppearanceSection(),
        SGSection(@"Features", parts),
        SGSection(@"Advanced", @[
            pageRow(@"Privacy & clutter", @"hand.raised", ^UIViewController *{ return SGPrivacySettingsPage(); }),
            pageRow(@"Labs", @"testtube.2", ^UIViewController *{ return SGLabsPage(); }),
            pageRow(@"All flags", @"flag", ^UIViewController *{ return SGAllFlagsPage(); }),
        ]),
        SGSection(nil, @[about]),
    ]];
    return [[SGModPage alloc] initWithTitle:@"Glassify" intro:nil sections:sections footer:nil];
}

#pragma mark - row in the settings list

// The first row of Spotify's settings list, drawn like its own rows, chevron and all: the waveform of
// Glassify's icon, and its name.
@interface SGModSettingsRow : UIControl
@end

@implementation SGModSettingsRow {
    UIImageView *_icon;
    UILabel *_title;
    UIImageView *_chevron;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _icon = SGSymbolView(@"waveform", 20, UIImageSymbolWeightRegular, 24);
    _title = [UILabel new];
    _title.text = @"Glassify";
    _title.textColor = UIColor.whiteColor;
    _chevron = SGSymbolView(@"chevron.right", 11, UIImageSymbolWeightSemibold, 12);
    for (UIView *v in @[_icon, _title, _chevron]) [self addSubview:v];
    [self addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _title.font = SGTitleFont();
    CGFloat width = self.bounds.size.width, height = self.bounds.size.height;
    _icon.frame = CGRectMake(12, (height - 24) / 2, 24, 24);
    _title.frame = CGRectMake(48, 0, width - 96, height);
    _chevron.frame = CGRectMake(width - 24, (height - 12) / 2, 12, 12);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1;
}

static UINavigationController *navigationIn(UIViewController *page) {
    if ([page isKindOfClass:UINavigationController.class]) return (UINavigationController *)page;
    for (UIViewController *child in page.childViewControllers) {
        UINavigationController *found = navigationIn(child);
        if (found) return found;
    }
    return nil;
}

- (void)open {
    UIViewController *owner = nil;
    for (UIResponder *r = self; r && !owner; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    }
    SGShowPage(owner, modSettingsPage());
}

@end

// The tab bar's controller holds no stack itself; the selected tab's sits among its parent's children.
void SGOpenModSettings(UIView *source) {
    UIViewController *owner = nil;
    for (UIResponder *r = source; r && !owner; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
    }
    UINavigationController *nav = nil;
    for (UIViewController *page = owner; page && !nav; page = page.parentViewController) nav = navigationIn(page);
    SGShowPage(nav.topViewController ?: SGTopController(), modSettingsPage());
}

// Above the settings list's first row, in room added to its top inset, added again whenever Spotify resets
// the inset. A list resting at its top follows the new inset, so the row shows rather than scrolling off.
static void placeRow(UICollectionView *list, SGModSettingsRow *row) {
    SGAdoptFonts(list, row);
    row.hidden = list.contentSize.height <= 0;
    row.frame = CGRectMake(0, -kRowHeight, list.bounds.size.width, kRowHeight);

    UIEdgeInsets inset = list.contentInset;
    NSValue *applied = objc_getAssociatedObject(list, &kInsetKey);
    if (applied && UIEdgeInsetsEqualToEdgeInsets(inset, applied.UIEdgeInsetsValue)) return;
    BOOL atTop = list.contentOffset.y <= -list.adjustedContentInset.top + 1;
    inset.top += kRowHeight;
    objc_setAssociatedObject(list, &kInsetKey, [NSValue valueWithUIEdgeInsets:inset], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    list.contentInset = inset;
    if (atTop) list.contentOffset = CGPointMake(list.contentOffset.x, -list.adjustedContentInset.top);
}

// Media quality, Playback, Account and most of the rest of settings are the same controller class
// as the list they were opened from, which is why the row turned up at the end of all of them.
// What is on the navigation stack is not that controller though: every page in the app is wrapped
// in a MusicAppPageHostingViewController (trees/settings notifications opened.txt), and Spotify
// pushes a settings sub page as a page of its own, leaving the list it came from on the stack
// underneath. So the settings list inside the lowest wrapper that holds one is the list the row
// belongs at the end of, and a controller with no stack to be found on keeps the row rather than
// losing it.
static UIViewController *settingsListIn(UIViewController *page, Class kind) {
    if ([page isKindOfClass:kind]) return page;
    for (UIViewController *child in page.childViewControllers) {
        UIViewController *found = settingsListIn(child, kind);
        if (found) return found;
    }
    return nil;
}

static BOOL isSettingsRoot(UIViewController *list) {
    for (UIViewController *page in list.navigationController.viewControllers) {
        UIViewController *found = settingsListIn(page, list.class);
        if (found) return found == list;
    }
    return YES;
}

%hook _TtC21Settings_PlatformImpl26SettingsListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    BOOL root = isSettingsRoot((UIViewController *)self);
    for (UIView *sub in ((UIViewController *)self).view.subviews) {
        if (![sub isKindOfClass:UICollectionView.class]) continue;
        SGModSettingsRow *row = objc_getAssociatedObject(sub, &kRowKey);
        // A page that laid itself out before it was on the stack looked like the list for as long
        // as that took; the row goes again as soon as it can be seen for what it is.
        if (!root) {
            [row removeFromSuperview];
            objc_setAssociatedObject(sub, &kRowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            continue;
        }
        if (row) continue;
        row = [[SGModSettingsRow alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(sub, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sub addSubview:row];
    }
}
%end

// The lists lay out after their controllers and again whenever their content changes.
%hook UICollectionView
- (void)layoutSubviews {
    %orig;
    SGModSettingsRow *row = objc_getAssociatedObject(self, &kRowKey);
    if (row) placeRow(self, row);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC21Settings_PlatformImpl26SettingsListViewController"]);
    SGRegisterPages();
    SGCheckSigningOnce();
}
