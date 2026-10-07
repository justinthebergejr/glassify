#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "SGRPullStretch.h"

static char kStretchKey, kOffsetContext;

// Held by the view it stretches. The list is held only while it is watched, which is only while the view is in
// a window, so the two never keep each other alive and the observation always goes before either does.
@interface SGRPullStretcher : NSObject
@property (nonatomic, weak) UIView *view;
- (void)watch:(UIScrollView *)list;
@end

@implementation SGRPullStretcher {
    UIScrollView *_list;
}

- (void)dealloc {
    [_list removeObserver:self forKeyPath:@"contentOffset" context:&kOffsetContext];
}

- (void)watch:(UIScrollView *)list {
    if (list == _list) return;
    [_list removeObserver:self forKeyPath:@"contentOffset" context:&kOffsetContext];
    _list = list;
    [_list addObserver:self forKeyPath:@"contentOffset" options:0 context:&kOffsetContext];
    [self follow];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &kOffsetContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    [self follow];
}

// How far the list is pulled down past its top: the view grows by that much from its bottom edge, so its top
// stays where the top of the list's content was.
- (void)follow {
    UIView *view = self.view;
    if (!view) return;
    CGFloat pull = _list ? -(_list.contentOffset.y + _list.adjustedContentInset.top) : 0;
    CGFloat height = view.bounds.size.height;
    CGAffineTransform transform = CGAffineTransformIdentity;
    if (pull > 0 && height > 0) {
        CGFloat scale = (height + pull) / height;
        transform = CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale),
                                            CGAffineTransformMakeTranslation(0, -height * (scale - 1) / 2));
    }
    if (!CGAffineTransformEqualToTransform(view.transform, transform)) view.transform = transform;
}

@end

static UIScrollView *listAbove(UIView *view) {
    for (UIView *v = view.superview; v; v = v.superview) {
        if ([v isKindOfClass:UIScrollView.class]) return (UIScrollView *)v;
    }
    return nil;
}

void SGRStretchOnPull(UIView *view) {
    if (!view) return;
    SGRPullStretcher *stretcher = objc_getAssociatedObject(view, &kStretchKey);
    if (!stretcher) {
        stretcher = [SGRPullStretcher new];
        stretcher.view = view;
        objc_setAssociatedObject(view, &kStretchKey, stretcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIScrollView *list = view.window ? listAbove(view) : nil;
    // Once per kind of picture: which list it follows, or that it is in none and so never stretches.
    static NSMutableSet<NSString *> *said;
    if (!said) said = [NSMutableSet set];
    NSString *kind = NSStringFromClass(view.class);
    if (view.window && ![said containsObject:kind]) {
        [said addObject:kind];
        SGLog(@"redesign: %@ stretches on pull of %@", kind, list ? NSStringFromClass(list.class) : @"no list, so never");
    }
    if (list) {
        // The grown picture reaches above the header it sits in; whatever holds it under the list must not cut it.
        for (UIView *v = view.superview; v && v != list; v = v.superview) {
            if (v.clipsToBounds) v.clipsToBounds = NO;
        }
    }
    [stretcher watch:list];
}

void SGRPlaceStretched(UIView *view, CGRect frame) {
    if (!view || CGRectIsEmpty(frame)) return;
    CGRect bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    if (!CGRectEqualToRect(view.bounds, bounds)) view.bounds = bounds;
    CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    if (!CGPointEqualToPoint(view.center, center)) view.center = center;
}
