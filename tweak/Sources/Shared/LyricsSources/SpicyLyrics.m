// Spicy Lyrics (developers.spicylyrics.org): the community's word by word syncs, then Apple Music's and
// Spotify's, matched by Spotify's own track id, so it needs no name to ask with. Its terms shape this file:
//
//   - a key is one person's and may not be shared or published, so the mod ships none: the user makes a
//     publishable one (sl_pk_, with requests without an Origin allowed, which is what an app sends) and
//     pastes it on the Lyrics page;
//   - attribution is a condition of use and goes wherever the lyrics are, a community sync crediting and
//     linking its uploader and maker. Only the redesign's lyrics view can show that, so the source answers
//     only under Redesigned UI, and the view shows its credit whatever Show source says (SGLyricsCreditLink);
//   - answers may be kept 30 days at most; the chain keeps them for the session only.
//
// The answer's Body is one of three shapes, times in seconds:
//   Syllable  Content[] of { OppositeAligned, Lead: { Syllables[] }, Background[]: { Syllables[] } }, each
//             syllable { Text, StartTime, EndTime, IsPartOfWord } -- IsPartOfWord runs it into the next one;
//   Line      Content[] of { OppositeAligned, Text, StartTime, EndTime };
//   Static    Lines[] of { Text }.
#import "Core/SGCore.h"
#import "LyricsSources.h"

static NSString *const kLyrics = @"https://api.spicylyrics.org/v1/lyrics/";
// A pause longer than this between two timed lines is a break of its own rather than the line held.
static const NSInteger kBreakGap = 1500;

NSString *SGSpicyLyricsKey(void) {
    NSString *key = [NSUserDefaults.standardUserDefaults stringForKey:SGKeySpicyLyricsKey];
    key = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return key.length ? key : nil;
}

void SGSetSpicyLyricsKey(NSString *key) {
    key = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (key.length) [NSUserDefaults.standardUserDefaults setObject:key forKey:SGKeySpicyLyricsKey];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySpicyLyricsKey];
}

static NSInteger ms(id seconds) {
    return [seconds respondsToSelector:@selector(doubleValue)] ? lround([seconds doubleValue] * 1000) : 0;
}

static NSString *textOf(id value) {
    return [value isKindOfClass:NSString.class] ? [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
}

// One voice's syllables as a line, each syllable a word, run into the one before it where that one was
// part of the same word.
static SGKaraokeLine *lineOf(id syllables) {
    if (![syllables isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
    BOOL runOn = NO;
    for (id syllable in syllables) {
        if (![syllable isKindOfClass:NSDictionary.class]) continue;
        NSString *text = textOf(syllable[@"Text"]);
        if (!text.length) continue;
        SGKaraokeWord *word = [SGKaraokeWord new];
        word.text = text;
        word.start = ms(syllable[@"StartTime"]);
        word.end = MAX(word.start, ms(syllable[@"EndTime"]));
        word.joined = runOn && words.count > 0;
        runOn = [syllable[@"IsPartOfWord"] boolValue];
        [words addObject:word];
    }
    if (!words.count) return nil;
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = words.firstObject.start;
    line.end = words.lastObject.end;
    line.timing = SGKaraokeTimingWords;
    return line;
}

static NSArray<SGKaraokeLine *> *syllableLines(NSArray *content) {
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (id entry in content) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        id lead = entry[@"Lead"];
        SGKaraokeLine *line = lineOf([lead isKindOfClass:NSDictionary.class] ? lead[@"Syllables"] : nil);
        if (!line) continue;
        line.align = [entry[@"OppositeAligned"] boolValue] ? SGKaraokeAlignTrailing : SGKaraokeAlignLeading;
        // Every background part under the line, as the one backing line the view draws.
        NSMutableArray *backing = [NSMutableArray array];
        id background = entry[@"Background"];
        if ([background isKindOfClass:NSArray.class]) {
            for (id part in background) {
                id syllables = [part isKindOfClass:NSDictionary.class] ? part[@"Syllables"] : nil;
                if ([syllables isKindOfClass:NSArray.class]) [backing addObjectsFromArray:syllables];
            }
        }
        line.backing = lineOf(backing);
        line.backing.align = line.align;
        [lines addObject:line];
    }
    return lines.count ? lines : nil;
}

// Timed by the line: the words estimated inside each, a break where the singing stops for a while.
static NSArray<SGKaraokeLine *> *lineLines(NSArray *content) {
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSMutableArray<NSNumber *> *trailing = [NSMutableArray array];
    NSInteger lastEnd = -1;
    for (id entry in content) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *text = textOf(entry[@"Text"]);
        if (!text.length) continue;
        NSInteger start = ms(entry[@"StartTime"]), end = ms(entry[@"EndTime"]);
        if (lastEnd >= 0 && start - lastEnd > kBreakGap) {
            [starts addObject:@(lastEnd)];
            [texts addObject:@""];
            [trailing addObject:@NO];
        }
        [starts addObject:@(start)];
        [texts addObject:text];
        [trailing addObject:@([entry[@"OppositeAligned"] boolValue])];
        lastEnd = MAX(start, end);
    }
    if (lastEnd >= 0) {
        [starts addObject:@(lastEnd)];
        [texts addObject:@""];
    }
    NSArray<SGKaraokeLine *> *lines = SGKaraokeEstimatedLines(starts, texts);
    // The estimate drops the breaks; the duet sides are put back on the lines it kept, by start.
    NSMutableDictionary<NSNumber *, NSNumber *> *sides = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < trailing.count; i++) if ([trailing[i] boolValue]) sides[starts[i]] = @YES;
    for (SGKaraokeLine *line in lines) if (sides[@(line.start)]) line.align = SGKaraokeAlignTrailing;
    return lines.count ? lines : nil;
}

static NSArray<SGKaraokeLine *> *staticLines(NSArray *rows) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (id row in rows) {
        NSString *text = [row isKindOfClass:NSDictionary.class] ? textOf(row[@"Text"]) : nil;
        if (text.length) [texts addObject:text];
    }
    return texts.count ? SGKaraokeStaticLines(texts) : nil;
}

static NSString *nameOf(id person) {
    return [person isKindOfClass:NSDictionary.class] ? textOf(person[@"username"]) : nil;
}

static NSURL *linkOf(id person) {
    NSString *url = [person isKindOfClass:NSDictionary.class] ? textOf(person[@"url"]) : nil;
    return url.length ? [NSURL URLWithString:url] : nil;
}

// The credit the terms ask for: the provider that answered, and for a community sync who uploaded it and
// who made it, the uploader's page as the link.
static NSString *creditFor(NSDictionary *body, NSURL **link) {
    NSString *source = textOf(body[@"source"]);
    if ([source isEqualToString:@"apple_music"]) return @"Spicy Lyrics, from Apple Music";
    if ([source isEqualToString:@"spotify"]) return @"Spicy Lyrics, from Spotify";
    id attribution = body[@"UploadAttribution"];
    NSDictionary *people = [attribution isKindOfClass:NSDictionary.class] ? attribution : nil;
    NSString *uploader = nameOf(people[@"Uploader"]), *maker = nameOf(people[@"Maker"]);
    *link = linkOf(people[@"Uploader"]) ?: linkOf(people[@"Maker"]);
    // Both names kept, as the terms require, without the words around them: "Spicy Lyrics · uploader, maker".
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (uploader.length) [names addObject:uploader];
    if (maker.length && ![maker isEqualToString:uploader]) [names addObject:maker];
    return names.count ? [NSString stringWithFormat:@"Spicy Lyrics · %@", [names componentsJoinedByString:@", "]] : @"Spicy Lyrics";
}

SGLyricsAsk SGSpicyLyricsAsk = ^(SGLyricsQuery *query, void (^done)(SGLyricsResult *result)) {
    NSString *key = SGSpicyLyricsKey();
    if (!SGRedesignedUI() || !key || !query.trackID.length) {
        // Never the key itself: only whether there is one.
        SGLog(@"lyrics: Spicy Lyrics skipped for %@: %@", query.trackID,
              !SGRedesignedUI() ? @"only under Redesigned UI" : !key ? @"no key set on the Lyrics page" : @"no track id");
        done(nil);
        return;
    }
    NSURL *url = [NSURL URLWithString:[kLyrics stringByAppendingString:query.trackID]];
    SGLyricsGetJSON(url, @{@"Authorization": [@"Bearer " stringByAppendingString:key],
                           @"User-Agent": @"Glassify " @SG_VERSION @" (personal build of spoti.pw)"}, ^(id root) {
        id body = [root isKindOfClass:NSDictionary.class] ? root[@"Body"] : nil;
        if (![body isKindOfClass:NSDictionary.class]) {
            done(nil);
            return;
        }
        NSString *type = textOf(body[@"Type"]);
        NSArray<SGKaraokeLine *> *lines = nil;
        id content = body[@"Content"];
        if ([type isEqualToString:@"Syllable"] && [content isKindOfClass:NSArray.class]) lines = syllableLines(content);
        else if ([type isEqualToString:@"Line"] && [content isKindOfClass:NSArray.class]) lines = lineLines(content);
        else if ([type isEqualToString:@"Static"] && [body[@"Lines"] isKindOfClass:NSArray.class]) lines = staticLines(body[@"Lines"]);
        if (!lines.count) {
            SGLog(@"lyrics: Spicy Lyrics has no %@ lines for %@", type ?: @"readable", query.trackID);
            done(nil);
            return;
        }
        SGLyricsResult *result = [SGLyricsResult new];
        result.karaokeLines = lines;
        result.wordTimed = SGKaraokeLinesTiming(lines) == SGKaraokeTimingWords;
        result.synced = SGKaraokeLinesTiming(lines) != SGKaraokeTimingNone;
        // No text for Spotify's own page: the credit can only be shown in the redesign's view.
        NSURL *link = nil;
        result.credit = creditFor(body, &link);
        result.creditLink = link;
        done(result);
    });
};
