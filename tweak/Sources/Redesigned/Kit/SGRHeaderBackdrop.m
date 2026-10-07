#import "Core/SGCore.h"
#import "SGRHeaderBackdrop.h"

// Where, as a share of the backdrop's height, the black starts to fade, and how black it is above and at that
// point. No blur: the system materials tint even a black page grey, and the redesign is black throughout, so a
// black fade is what reads as the page itself running on behind the title.
static const CGFloat kFadeFrom = 0.7, kTop = 0.96, kAtFade = 0.88;

@interface SGRHeaderBackdrop : UIView
@end

@implementation SGRHeaderBackdrop {
    CAGradientLayer *_fade;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    _fade = [CAGradientLayer layer];
    _fade.colors = @[(id)[UIColor colorWithWhite:0 alpha:kTop].CGColor,
                     (id)[UIColor colorWithWhite:0 alpha:kAtFade].CGColor,
                     (id)[UIColor colorWithWhite:0 alpha:0].CGColor];
    _fade.locations = @[@0, @(kFadeFrom), @1];
    [self.layer addSublayer:_fade];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _fade.frame = self.bounds;
    [CATransaction commit];
}

@end

static char kBackdropKey;

void SGRHeaderBackdropIn(UIView *header, CGFloat fadeBelow) {
    if (!header) return;
    SGRHeaderBackdrop *backdrop = objc_getAssociatedObject(header, &kBackdropKey);
    if (!backdrop) {
        backdrop = [[SGRHeaderBackdrop alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(header, &kBackdropKey, backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign: header backdrop behind %@", NSStringFromClass(header.class)); });
    }
    if (backdrop.superview != header || header.subviews.firstObject != backdrop) [header insertSubview:backdrop atIndex:0];
    CGRect frame = CGRectMake(0, 0, header.bounds.size.width, header.bounds.size.height + fadeBelow);
    if (!CGRectEqualToRect(backdrop.frame, frame)) backdrop.frame = frame;
}
