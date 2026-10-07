// The Music app's pull on a page with a picture across its top: pulled down past the top of its list, the
// picture stays on the top of the screen and grows from its bottom edge, which moves with the list, instead of
// sliding down and leaving the page's colour above it. Used by the album's and the artist's headers.
#import <UIKit/UIKit.h>

// Follows the list above `view` while the view is in a window, and lets go of it once it leaves; call it from
// the view's -didMoveToWindow and on the header's passes, which find the list once the view is in place. The
// view carries a transform while the list is pulled, so it must be placed by bounds and centre (SGRPlaceStretched),
// never by frame, and nothing between it and the list may clip it (the views it sits in are unclipped).
void SGRStretchOnPull(UIView *view);
// Places a view SGRStretchOnPull follows at `frame` in its superview, whatever transform it carries.
void SGRPlaceStretched(UIView *view, CGRect frame);
