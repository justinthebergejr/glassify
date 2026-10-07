// The player redesign (screen key "player"): Spotify's full screen player kept, with its controller,
// units, controls and card list, and restyled from the Kit. Every control stays Spotify's own, so its
// action, state and accessibility do too; the redesign adds the artwork field behind it, glass behind
// the header buttons, bare glyphs for previous, play and next, a lyrics glyph in the footer, and one
// screen with nothing under it: every card is collapsed and the player does not scroll. The lyrics
// come to the player itself, the way the Music app shows them, when the lyrics glyph is tapped.
//
//     PlayerField.x      the switch's flags and rows, the field in the background plane, the cover it reads
//     PlayerArtwork.x    the cover's corners, shadow and paused shrink, the lyric preview under it hidden
//     PlayerHeader.x     glass behind the close and more buttons
//     PlayerControls.x   previous, play and next as bare glyphs, monospaced times
//     PlayerFooter.x     share gone, lyrics, Connect and queue as one row of three glyphs
//     PlayerCards.x      every card under the player collapsed, so the list closes up
//     PlayerScroll.x     the list held at its top, so the player is one screen and cannot be scrolled up
//     PlayerLyrics.x     the lyrics in the player: the cover as a thumbnail, the title up beside it
//     PlayerGestures.x   the gestures' hookup
//     PlayerMorph.x      the open and close grown out of the now playing bar's card, the cover flown
//     PlayerLiveCover.x  the track's animated artwork across the top of the player, the cover hidden under it
//
// Speed and pitch, once the redesign's own, are Shared/Player/SpeedPitch.h's; PlayerHeader.x still hands
// the more button over, so a menu opened from it is taken for the player's.
//
// Every hook installs only while Redesigned UI is on (SGRedesignedUI); the native look's do not then.
// Threading: main thread only.
#import <UIKit/UIKit.h>

@class SGRArtworkField;

// The artwork's colours moving behind the player (on until switched off), or the blurred artwork held
// still; the row is on the Now playing page (Redesigned/NowPlayingBar/NowPlayingBarSettings.m).
#define SGRKeyPlayerMotion @"spotifyglass.redesign.player.movingBackground"

// The field behind the player, nil until the player has laid out once (PlayerField.x).
SGRArtworkField *SGRPlayerField(void);
// Reads the field's picture again: the live cover's frame while it shows, the cover's otherwise; crossfades.
void SGRPlayerFieldRefresh(void);

#pragma mark - the cover (PlayerArtwork.x)

// The sideways list of covers behind the player, nil until one has laid out.
UIView *SGRPlayerCoverList(void);
// The cover on screen as it is drawn, its paused shrink included, in `host`'s coordinates; CGRectNull
// when no cover has laid out.
CGRect SGRPlayerCoverFrameIn(UIView *host);
// The band that cover sits in -- the room the player gives its artwork, between the header row and the
// title -- in `host`'s coordinates; CGRectNull when no cover has laid out.
CGRect SGRPlayerArtworkAreaIn(UIView *host);
// Hides the cover on screen and its shadow, or shows them again, for a stand-in to fly in its place
// (PlayerMorph.x).
void SGRPlayerSetCoverHidden(BOOL hidden);
// Hides every cover and its shadow while the live cover plays in their place, or shows them again;
// a cover hidden for a stand-in stays hidden until the stand-in is done.
void SGRPlayerSetCoverMuted(BOOL muted, BOOL animated);

#pragma mark - the live cover (PlayerLiveCover.x)

// The album's animated cover from Apple Music or the track's Canvas across the top of the player (on
// until switched off), from the sources in the order stored under the second key; the rows are on the
// Now playing page.
#define SGRKeyPlayerLiveCover @"spotifyglass.redesign.player.liveCover"
#define SGRKeyPlayerLiveCoverSources @"spotifyglass.redesign.player.liveCoverSources"

// The sources switched on, in order: Apple Music, then Spotify's Canvas until set.
NSArray<NSString *> *SGRPlayerLiveCoverOrder(void);
void SGRPlayerSetLiveCoverOrder(NSArray<NSString *> *order);
// Puts the live cover in the field and sizes it, on every layout of the field (PlayerField.x).
void SGRPlayerLiveCoverLayIn(SGRArtworkField *field);
// Shows or hides it for what the player is doing now; called when the lyrics come or go (PlayerFooter.x).
void SGRPlayerLiveCoverRefresh(void);
// Fades it for the open or close at `progress` (0 the bar, 1 the player) and answers how much of it shows,
// 0 to 1, for the morph to show the flown cover by the rest; 0 when there is no clip to show
// (PlayerMorph.x).
CGFloat SGRPlayerLiveCoverMorph(CGFloat progress);
// The clip's first frame while the live cover shows, with an identity for the field; nil otherwise, when the
// field takes the cover's colours (PlayerField.x).
UIImage *SGRPlayerLiveCoverFrame(NSString **identity);

#pragma mark - the lyrics in the player (PlayerLyrics.x)

// Whether the playing track has lyrics the player can show.
BOOL SGRPlayerLyricsAvailable(void);
// Whether the player is showing them.
BOOL SGRPlayerLyricsOpen(void);
// Shows them, or puts the cover back; does nothing when there are none to show.
void SGRPlayerToggleLyrics(void);
// Called by PlayerLyrics.x whenever either of those two changed, so the footer's lyrics glyph follows
// (PlayerFooter.x). It returns at once when nothing changed.
void SGRPlayerLyricsChanged(void);

// Alpha 0, no touches, hidden from accessibility, set again on every call: for Spotify's Swift views,
// which SGRSuppress cannot keep (PlayerControls.x).
void SGRPlayerVanish(UIView *view);
