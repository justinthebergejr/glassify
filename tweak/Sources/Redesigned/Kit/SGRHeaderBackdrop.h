// A black fade behind a page's header (Home, Your Library): what scrolls up under the title, the buttons and
// the chips fades into the page's black instead of showing through them. Nearly opaque at the top, it fades out
// just past the header's bottom edge, short of the first row, so at rest, on the redesign's black, there is
// nothing to see. No blur: the system materials tint black grey.
//
// It stands in for the system's soft scroll edge, which reaches only as far as the status bar: UIKit sizes it
// from the bars it knows of, and these headers are Spotify's own views over the list
// (Kit/SGREdgeEffect.x keeps that edge soft; this covers the rest of the header).
//
// Ownership: the header holds it, as its backmost subview. Threading: main thread only.
#import <UIKit/UIKit.h>

// Puts the backdrop behind everything in `header`, as tall as the header plus `fadeBelow` points of fade under
// it, and keeps it there and sized on every call; cheap when nothing changed.
void SGRHeaderBackdropIn(UIView *header, CGFloat fadeBelow);
