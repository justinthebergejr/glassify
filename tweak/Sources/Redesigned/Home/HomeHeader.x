// Home redesign: the header the way the Music app has it. The filter pills (All, Music, Podcasts) go and
// a large title takes their place at the leading edge; the avatar that opens the side drawer moves to the
// trailing edge; the scrim Spotify lays behind the header goes too, the soft scroll edge (Kit/SGREdgeEffect.x)
// being what keeps the title clear of the page scrolling under it, as on every other redesigned page.
//
// Tree (trees/clean/home/10.txt:3018-3051): FunkisViewController's view holds a 402x112 UIView around
// Reprise_LiquidGlassKit LiquidGlass.GradientView (the scrim) and, at {0, 62}, an
// ElementView<HomeHeaderElement> 402x50 holding HomeHeaderView > UIStackView {0, 8} 402x34 of two arranged
// views: ListeningActivity_ElementsKit.AdaptiveFaceContainer {16, 0} 32x34 (the avatar,
// id=Components.UI.SideDrawerButton) and LiquidGlass.LeadingFadeMaskView {48, 1} 354x32 around
// Home_PillUIKit.PillScrollView.
//
// The avatar moves by the stack's layout direction rather than by a frame of ours. Right to left, the stack
// lays its first view out at the trailing edge itself on every pass, whatever width the face container
// takes when friends listening show beside the avatar; its leading margin, 16pt, is the one Spotify gives
// the header in a right to left language. The pills stay in the stack with no alpha rather than hidden,
// the way the redesign takes any view out of a stack Spotify arranges (Kit/SGRRestyle.h).
//
// The title is Spotify's own name for the tab, read off its tab bar item (id=TabBar.Item.Home, 10.txt:3100),
// so it follows the app's language.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Home.h"

// Tries at finding the tab's name before settling for the English one: a miss walks the window.
static const NSUInteger kTitleTries = 8;
// How far under the header's 112pt the backdrop fades out: past the large title, short of the first row of
// cards (about 15pt under the header, 25pt with kListGap), which would otherwise be dimmed at rest.
static const CGFloat kBackdropFade = 8;
// Room added between the large title and the first row of tiles, so the tiles do not start right under the
// backdrop's fade: on top of the inset Spotify gives the list.
static const CGFloat kListGap = 10;
static char kListInsetKey;
static __weak UIScrollView *sg_list;

// The page's feed: the first collection view under the page taller than half of it (the shortcuts grid and
// the shelves are collection views inside it, and shorter).
static UIScrollView *listIn(UIView *view) {
    if (sg_list.window && [sg_list isDescendantOfView:view]) return sg_list;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:view];
    for (NSUInteger at = 0; at < queue.count && at < 400; at++) {
        UIView *v = queue[at];
        if (v != view && [v isKindOfClass:UICollectionView.class] && v.bounds.size.height > view.bounds.size.height / 2) {
            sg_list = (UIScrollView *)v;
            return sg_list;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

// kListGap on top of Spotify's inset, put back whenever Spotify sets its own again. A page resting at its top
// follows the new inset, so the gap shows rather than scrolling the first row under the title.
static void spaceList(UIView *view) {
    UIScrollView *list = listIn(view);
    if (!list) return;
    UIEdgeInsets inset = list.contentInset;
    NSNumber *set = objc_getAssociatedObject(list, &kListInsetKey);
    if (set && fabs(inset.top - set.doubleValue) < 0.5) return;
    BOOL atTop = list.contentOffset.y <= -list.adjustedContentInset.top + 1;
    inset.top += kListGap;
    list.contentInset = inset;
    objc_setAssociatedObject(list, &kListInsetKey, @(inset.top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (atTop) list.contentOffset = CGPointMake(list.contentOffset.x, -list.adjustedContentInset.top);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign home: %.0fpt more room above the feed, inset now %.0f", kListGap, inset.top); });
}

static char kTitleKey, kTabKey;
static NSString *sg_tabName;

static void vanish(UIView *view) {
    if (!view) return;
    if (view.alpha != 0) view.alpha = 0;
    view.userInteractionEnabled = NO;
    view.accessibilityElementsHidden = YES;
}

static UIView *childNamed(UIView *host, NSString *marker) {
    for (UIView *sub in host.subviews) {
        if ([NSStringFromClass(sub.class) containsString:marker]) return sub;
    }
    return nil;
}

static NSString *tabName(UIWindow *window) {
    if (sg_tabName || !window) return sg_tabName ?: @"Home";
    static NSUInteger tries;
    if (tries >= kTitleTries) return @"Home";
    tries++;
    UIView *item = SGRFindByIdentifier(window, @"TabBar.Item.Home", &kTabKey);
    __block NSString *name = nil;
    if (item) SGForEachView(item, ^(UIView *v) {
        if (!name && [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) name = ((UILabel *)v).text;
    });
    if (!name) {
        if (tries == kTitleTries) SGLog(@"redesign home: the Home tab's name not found, the title stays English");
        return @"Home";
    }
    sg_tabName = [name copy];
    SGLog(@"redesign home: title \"%@\" from the tab bar", sg_tabName);
    return sg_tabName;
}

static UILabel *titleIn(UIView *header) {
    UILabel *title = objc_getAssociatedObject(header, &kTitleKey);
    if (!title) {
        title = [UILabel new];
        title.textColor = SGRPrimary();
        title.accessibilityTraits = UIAccessibilityTraitHeader;
        title.adjustsFontSizeToFitWidth = YES;
        title.minimumScaleFactor = 0.6;
        title.userInteractionEnabled = NO;
        objc_setAssociatedObject(header, &kTitleKey, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (title.superview != header) [header addSubview:title];
    return title;
}

// The header's views, found once: the page lays out again as it appears, and the walk names classes.
static __weak UIView *sg_header;
static __weak UIStackView *sg_stack;
static __weak UIView *sg_scrim;

static BOOL findHeader(UIView *view) {
    if (sg_stack && [sg_stack isDescendantOfView:view]) return YES;
    for (UIView *wrapper in view.subviews) {
        UIView *scrim = childNamed(wrapper, @"GradientView");
        if (scrim) sg_scrim = scrim;
    }
    UIView *header = childNamed(childNamed(view, @"HomeHeaderElement"), @"HomeHeaderView");
    for (UIView *sub in header.subviews) {
        if ([sub isKindOfClass:UIStackView.class]) sg_stack = (UIStackView *)sub;
    }
    sg_header = header;
    if (sg_stack) return YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign home: header stack not found, header left as Spotify's"); });
    return NO;
}

static void layoutHeader(UIViewController *page) {
    UIView *view = page.viewIfLoaded;
    if (!view || !findHeader(view)) return;
    UIView *header = sg_header;
    UIStackView *stack = sg_stack;
    vanish(sg_scrim);
    // The soft edge reaches only the status bar; the Kit's black fade, in the scrim's place, covers the title.
    SGRHeaderBackdropIn(sg_scrim.superview, kBackdropFade);
    spaceList(view);

    static Class faceClass;
    if (!faceClass) faceClass = NSClassFromString(@"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer");
    UIView *face = nil;
    for (UIView *part in stack.arrangedSubviews) {
        if (faceClass && [part isKindOfClass:faceClass]) face = part;
        else vanish(part);
    }
    if (stack.semanticContentAttribute != UISemanticContentAttributeForceRightToLeft) {
        stack.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        [stack setNeedsLayout];
    }
    [stack layoutIfNeeded];

    UILabel *title = titleIn(header);
    NSString *text = tabName(header.window);
    if (![title.text isEqualToString:text]) {
        title.text = text;
        title.accessibilityLabel = text;
    }
    UIFont *font = SGRFont(UIFontTextStyleLargeTitle, UIFontWeightBold, UIContentSizeCategoryLarge);
    if (![title.font isEqual:font]) title.font = font;

    CGFloat trailing = face ? CGRectGetMinX([stack convertRect:face.frame toView:header]) - SGRGrid : header.bounds.size.width - SGRSideMargin;
    CGFloat height = ceil(font.lineHeight);
    CGRect frame = CGRectMake(SGRSideMargin, round(CGRectGetMidY(stack.frame) - height / 2), MAX(0, trailing - SGRSideMargin), height);
    if (!CGRectEqualToRect(title.frame, frame)) title.frame = frame;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"redesign home: header %@, avatar %@ in the stack %@, title %@, scrim %@", NSStringFromCGRect(header.frame),
              face ? NSStringFromCGRect(face.frame) : @"not found", NSStringFromCGRect(stack.frame), NSStringFromCGRect(frame),
              sg_scrim ? @"found" : @"not found");
    });
}

%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews {
    %orig;
    CFTimeInterval began = SGRHomeProbeBegin();
    layoutHeader((UIViewController *)self);
    SGRHomeProbeEnd(SGRHomeProbeHeader, began);
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    %orig;
    [((UIViewController *)self).viewIfLoaded setNeedsLayout];
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC19Home_FunkisPageImpl20FunkisViewController",
        @"_TtC29ListeningActivity_ElementsKit21AdaptiveFaceContainer",
    ]);
}
