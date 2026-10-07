// AnimatedArtwork.h says what each function promises. Apple Music's state (the token, the answers, the
// pause) lives on the main thread; the cache's files are written on the main thread (downloads) and on
// one serial queue (crops, eviction), and a file once in place under its final name is never written again,
// only evicted, so whoever is playing one keeps reading what it opened.
#import <AVFoundation/AVFoundation.h>
#import "Core/SGCore.h"
#import "AnimatedArtwork.h"

NSString *const SGArtworkSourceAppleMusic = @"applemusic";
NSString *const SGArtworkSourceSpotify = @"spotify";

@implementation SGArtworkClip
- (NSString *)description {
    return [NSString stringWithFormat:@"%@ clip %@", _source, _identifier];
}
@end

#pragma mark - Order

static NSArray<NSString *> *cleanOrder(id value) {
    if (![value isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (id source in value) {
        if (![source isKindOfClass:NSString.class]) continue;
        if (![source isEqualToString:SGArtworkSourceAppleMusic] && ![source isEqualToString:SGArtworkSourceSpotify]) continue;
        if (![order containsObject:source]) [order addObject:source];
    }
    return order;
}

NSArray<NSString *> *SGArtworkOrderIn(NSString *key, NSArray<NSString *> *fallback) {
    return cleanOrder([NSUserDefaults.standardUserDefaults objectForKey:key]) ?: cleanOrder(fallback) ?: @[];
}

void SGArtworkSetOrderIn(NSString *key, NSArray<NSString *> *order) {
    [NSUserDefaults.standardUserDefaults setObject:cleanOrder(order) ?: @[] forKey:key];
}

#pragma mark - Names

// Letters, digits, '-' and '_' kept, anything else made '_', so the result is a file name.
static NSString *safeName(NSString *text) {
    if (![text isKindOfClass:NSString.class] || !text.length) return nil;
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    });
    NSMutableString *safe = [NSMutableString stringWithCapacity:MIN(text.length, 100)];
    for (NSUInteger i = 0; i < text.length && safe.length < 100; i++) {
        unichar c = [text characterAtIndex:i];
        [safe appendString:[allowed characterIsMember:c] ? [NSString stringWithCharacters:&c length:1] : @"_"];
    }
    return safe;
}

// A name the way two catalogues are compared: case and accents folded, punctuation and spaces gone.
static NSString *plainName(NSString *name) {
    if (![name isKindOfClass:NSString.class]) return @"";
    NSString *folded = [name stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
    NSArray<NSString *> *pieces = [folded.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet];
    return [pieces componentsJoinedByString:@""];
}

// Words that mark the part after a title's last " - " as an edition rather than the title.
static BOOL namesEdition(NSString *suffix) {
    static NSRegularExpression *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = [NSRegularExpression regularExpressionWithPattern:
                 @"\\b(single|ep|deluxe|edition|remaster(ed)?|version|expanded|anniversary|bonus|special|collector'?s|complete)\\b"
                                                          options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return [words firstMatchInString:suffix options:0 range:NSMakeRange(0, suffix.length)] != nil;
}

// The title without what editions add to it: a trailing " - Single", " - Remastered 2011" and the like,
// and trailing bracketed groups, "(Deluxe)", "[Expanded Edition]".
static NSString *withoutEdition(NSString *title) {
    if (![title isKindOfClass:NSString.class]) return @"";
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSString *bare = [title stringByTrimmingCharactersInSet:space];
    while (bare.length) {
        NSRange dash = [bare rangeOfString:@" - " options:NSBackwardsSearch];
        if (dash.location != NSNotFound && dash.location > 0 && namesEdition([bare substringFromIndex:NSMaxRange(dash)])) {
            bare = [[bare substringToIndex:dash.location] stringByTrimmingCharactersInSet:space];
            continue;
        }
        unichar last = [bare characterAtIndex:bare.length - 1];
        if (last == ')' || last == ']') {
            NSString *open = last == ')' ? @"(" : @"[";
            NSRange start = [bare rangeOfString:open options:NSBackwardsSearch];
            if (start.location != NSNotFound && start.location > 0) {
                bare = [[bare substringToIndex:start.location] stringByTrimmingCharactersInSet:space];
                continue;
            }
        }
        break;
    }
    return bare.length ? bare : title;
}

// Whether Apple Music's artist line names `artist`, alone or among the several artists it may list.
static BOOL artistMatches(NSString *artist, NSString *listed) {
    NSString *wanted = plainName(artist);
    if (!wanted.length || ![listed isKindOfClass:NSString.class]) return NO;
    if ([plainName(listed) isEqualToString:wanted]) return YES;
    static NSRegularExpression *separators;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        separators = [NSRegularExpression regularExpressionWithPattern:@"\\s*(,|&|\\+|/|\\band\\b|\\bx\\b|\\bfeat\\.?|\\bft\\.?|\\bwith\\b)\\s*"
                                                               options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSString *split = [separators stringByReplacingMatchesInString:listed options:0 range:NSMakeRange(0, listed.length) withTemplate:@"\n"];
    for (NSString *name in [split componentsSeparatedByString:@"\n"]) {
        if ([plainName(name) isEqualToString:wanted]) return YES;
    }
    return NO;
}

static NSString *stringIn(id value) {
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

#pragma mark - Network

static NSString *const kSafariAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

// Ephemeral, so nothing of Spotify's (cookies, cache, credentials) goes with a request. Low Data Mode is
// left allowed, as it is by default.
static NSURLSessionConfiguration *ephemeralConfiguration(NSTimeInterval resourceTimeout) {
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPShouldSetCookies = NO;
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    configuration.URLCache = nil;
    configuration.URLCredentialStorage = nil;
    configuration.timeoutIntervalForRequest = 20;
    configuration.timeoutIntervalForResource = resourceTimeout;
    return configuration;
}

static NSURLSession *requestSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        session = [NSURLSession sessionWithConfiguration:ephemeralConfiguration(40)];
    });
    return session;
}

// The body and the HTTP status (0 when the request failed), on the main queue.
static void fetch(NSURLRequest *request, void (^done)(NSData *data, NSInteger status)) {
    [[requestSession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = !error && [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            done(status ? data : nil, status);
        });
    }] resume];
}

static NSString *textOf(NSData *data) {
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

// A query value encoded the strict way: NSURLComponents leaves '&', '=' and '+' alone in its values.
static NSString *queryValue(NSString *value) {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&=+?#/"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

#pragma mark - Apple Music token

static NSString *const kTokenKey = @"spotifyglass.artwork.appleMusicToken";

// Main thread.
static NSMutableArray<void (^)(NSString *)> *sg_tokenWaiters;
static NSMutableSet<NSString *> *sg_refusedTokens;
static CFAbsoluteTime sg_appleMusicPausedUntil;
static NSString *sg_storefront;

static NSDictionary *tokenClaims(NSString *token) {
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count != 3) return nil;
    NSMutableString *payload = [[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
    [payload replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, payload.length)];
    while (payload.length % 4) [payload appendString:@"="];
    NSData *json = [[NSData alloc] initWithBase64EncodedString:payload options:0];
    id claims = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    return [claims isKindOfClass:NSDictionary.class] ? claims : nil;
}

// Good for at least another hour.
static BOOL tokenUsable(NSString *token) {
    NSNumber *expiry = tokenClaims(token)[@"exp"];
    if (![expiry isKindOfClass:NSNumber.class]) return NO;
    return expiry.doubleValue > NSDate.date.timeIntervalSince1970 + 3600 && ![sg_refusedTokens containsObject:token];
}

// The page script carries several tokens; the web player's own (issued by AMPWebPlay) is the one its
// catalog requests use, so it goes first.
static NSArray<NSString *> *tokensIn(NSString *script) {
    static NSRegularExpression *jwt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        jwt = [NSRegularExpression regularExpressionWithPattern:@"eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+" options:0 error:nil];
    });
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSTextCheckingResult *match in [jwt matchesInString:script options:0 range:NSMakeRange(0, script.length)]) {
        NSString *token = [script substringWithRange:match.range];
        if ([tokens containsObject:token]) continue;
        if ([tokenClaims(token)[@"iss"] isEqual:@"AMPWebPlay"]) [tokens insertObject:token atIndex:0];
        else [tokens addObject:token];
    }
    return tokens;
}

static void finishToken(NSString *token) {
    if (token) [NSUserDefaults.standardUserDefaults setObject:token forKey:kTokenKey];
    NSArray<void (^)(NSString *)> *waiters = sg_tokenWaiters;
    sg_tokenWaiters = nil;
    SGLog(@"apple music: token %@", token ? @"found" : @"not found");
    for (void (^waiter)(NSString *) in waiters) waiter(token);
}

// The stored token while it lasts, else one read afresh from the web player's script. Main thread.
static void appleMusicToken(void (^done)(NSString *token)) {
    NSString *stored = stringIn([NSUserDefaults.standardUserDefaults objectForKey:kTokenKey]);
    if (stored && tokenUsable(stored)) {
        done(stored);
        return;
    }
    if (sg_tokenWaiters) {
        [sg_tokenWaiters addObject:done];
        return;
    }
    sg_tokenWaiters = [NSMutableArray arrayWithObject:done];
    NSMutableURLRequest *page = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://music.apple.com/us/browse"]];
    [page setValue:kSafariAgent forHTTPHeaderField:@"User-Agent"];
    fetch(page, ^(NSData *data, NSInteger status) {
        NSString *html = textOf(data);
        NSRegularExpression *scripts = [NSRegularExpression regularExpressionWithPattern:@"src=\"(/assets/[^\"]+\\.js)\"" options:0 error:nil];
        NSString *path = nil;
        for (NSTextCheckingResult *match in html ? [scripts matchesInString:html options:0 range:NSMakeRange(0, html.length)] : @[]) {
            NSString *candidate = [html substringWithRange:[match rangeAtIndex:1]];
            if (!path || [candidate containsString:@"/index"]) path = candidate;
        }
        if (!path) {
            SGLog(@"apple music: no script on the web player's page (HTTP %ld)", (long)status);
            finishToken(nil);
            return;
        }
        NSMutableURLRequest *script = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://music.apple.com" stringByAppendingString:path]]];
        [script setValue:kSafariAgent forHTTPHeaderField:@"User-Agent"];
        fetch(script, ^(NSData *body, NSInteger scriptStatus) {
            // A few megabytes of script: searched off the main thread.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSArray<NSString *> *tokens = tokensIn(textOf(body) ?: @"");
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *token = nil;
                    for (NSString *candidate in tokens) {
                        if (!tokenUsable(candidate)) continue;
                        token = candidate;
                        break;
                    }
                    if (!token) SGLog(@"apple music: %lu tokens in the script (HTTP %ld), none usable", (unsigned long)tokens.count, (long)scriptStatus);
                    finishToken(token);
                });
            });
        });
    });
}

#pragma mark - Apple Music catalog

static NSString *storefront(void) {
    if (sg_storefront) return sg_storefront;
    NSString *region = [stringIn([NSLocale.currentLocale objectForKey:NSLocaleCountryCode]) lowercaseString];
    sg_storefront = region.length == 2 ? region : @"us";
    return sg_storefront;
}

static BOOL appleMusicPaused(void) {
    return CFAbsoluteTimeGetCurrent() < sg_appleMusicPausedUntil;
}

// GET /v1/catalog/<storefront>/<path>?<query> with the web player's token, the JSON on the main queue
// (nil on failure). A 401 is answered with another token, twice at most; a storefront the API refuses is
// replaced by the US one; a 403 or 429 pauses every Apple Music request for ten minutes.
static void appleMusicGET(NSString *path, NSString *query, NSUInteger attempt, void (^done)(NSDictionary *json)) {
    if (appleMusicPaused()) {
        done(nil);
        return;
    }
    appleMusicToken(^(NSString *token) {
        if (!token) {
            done(nil);
            return;
        }
        NSString *front = storefront();
        NSString *address = [NSString stringWithFormat:@"https://amp-api.music.apple.com/v1/catalog/%@/%@?%@", front, path, query];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        [request setValue:@"https://music.apple.com" forHTTPHeaderField:@"Origin"];
        [request setValue:@"https://music.apple.com/" forHTTPHeaderField:@"Referer"];
        [request setValue:kSafariAgent forHTTPHeaderField:@"User-Agent"];
        fetch(request, ^(NSData *data, NSInteger status) {
            if (status == 401 && attempt < 2) {
                SGLog(@"apple music: token refused, reading a new one");
                if (!sg_refusedTokens) sg_refusedTokens = [NSMutableSet set];
                [sg_refusedTokens addObject:token];
                [NSUserDefaults.standardUserDefaults removeObjectForKey:kTokenKey];
                appleMusicGET(path, query, attempt + 1, done);
                return;
            }
            if (status == 400 && ![front isEqualToString:@"us"] && attempt < 2) {
                SGLog(@"apple music: storefront %@ refused, asking the US one", front);
                sg_storefront = @"us";
                appleMusicGET(path, query, attempt + 1, done);
                return;
            }
            if (status == 403 || status == 429) {
                SGLog(@"apple music: HTTP %ld, pausing lookups for 10 minutes", (long)status);
                sg_appleMusicPausedUntil = CFAbsoluteTimeGetCurrent() + 600;
            }
            id json = status == 200 && data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (status != 200) SGLog(@"apple music: %@ answered HTTP %ld", path, (long)status);
            done([json isKindOfClass:NSDictionary.class] ? json : nil);
        });
    });
}

static NSArray<NSDictionary *> *searchResults(NSDictionary *json, NSString *type) {
    id data = json[@"results"][type][@"data"];
    return [data isKindOfClass:NSArray.class] ? data : @[];
}

#pragma mark - HLS

// A tag's attribute list, quoted values (which may hold commas) unquoted.
static NSDictionary<NSString *, NSString *> *attributesOf(NSString *list) {
    NSMutableDictionary<NSString *, NSString *> *attributes = [NSMutableDictionary dictionary];
    NSScanner *scanner = [NSScanner scannerWithString:list];
    scanner.charactersToBeSkipped = nil;
    while (!scanner.isAtEnd) {
        NSString *name = nil, *value = nil;
        if (![scanner scanUpToString:@"=" intoString:&name] || ![scanner scanString:@"=" intoString:NULL]) break;
        if ([scanner scanString:@"\"" intoString:NULL]) {
            [scanner scanUpToString:@"\"" intoString:&value];
            [scanner scanString:@"\"" intoString:NULL];
        } else {
            [scanner scanUpToString:@"," intoString:&value];
        }
        attributes[[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]] = value ?: @"";
        [scanner scanString:@"," intoString:NULL];
    }
    return attributes;
}

static NSArray<NSString *> *linesOf(NSString *playlist) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [playlist componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) [lines addObject:trimmed];
    }
    return lines;
}

// The variant stream nearest 1000 px wide, HEVC where there is any, SDR only, the lighter of two alike.
static NSURL *chooseVariant(NSString *playlist, NSURL *base) {
    NSArray<NSString *> *lines = linesOf(playlist);
    NSMutableArray<NSDictionary *> *variants = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < lines.count; i++) {
        if (![lines[i] hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;
        NSDictionary<NSString *, NSString *> *attributes = attributesOf([lines[i] substringFromIndex:18]);
        NSString *uri = lines[i + 1];
        if ([uri hasPrefix:@"#"]) continue;
        NSString *range = attributes[@"VIDEO-RANGE"];
        if (range && ![range isEqualToString:@"SDR"]) continue;
        NSURL *url = [NSURL URLWithString:uri relativeToURL:base].absoluteURL;
        NSInteger width = [[attributes[@"RESOLUTION"] componentsSeparatedByString:@"x"].firstObject integerValue];
        if (!url || width <= 0) continue;
        NSString *codecs = attributes[@"CODECS"] ?: @"";
        BOOL hevc = [codecs containsString:@"hvc1"] || [codecs containsString:@"hev1"];
        [variants addObject:@{@"url": url, @"width": @(width), @"hevc": @(hevc), @"bandwidth": @([attributes[@"BANDWIDTH"] integerValue])}];
    }
    BOOL anyHEVC = [[variants valueForKey:@"hevc"] containsObject:@YES];
    NSDictionary *best = nil;
    for (NSDictionary *variant in variants) {
        if (anyHEVC && ![variant[@"hevc"] boolValue]) continue;
        if (!best) {
            best = variant;
            continue;
        }
        NSInteger distance = labs([variant[@"width"] integerValue] - 1000), bestDistance = labs([best[@"width"] integerValue] - 1000);
        if (distance < bestDistance || (distance == bestDistance && [variant[@"bandwidth"] integerValue] < [best[@"bandwidth"] integerValue])) best = variant;
    }
    return best[@"url"];
}

// The one file a media playlist's segments are byte ranges of; nil when they are separate files.
static NSURL *singleFileOf(NSString *playlist, NSURL *base) {
    NSURL *file = nil;
    for (NSString *line in linesOf(playlist)) {
        NSString *uri = nil;
        if ([line hasPrefix:@"#EXT-X-MAP:"]) uri = attributesOf([line substringFromIndex:11])[@"URI"];
        else if (![line hasPrefix:@"#"]) uri = line;
        if (!uri) continue;
        NSURL *url = [NSURL URLWithString:uri relativeToURL:base].absoluteURL;
        if (!url) return nil;
        if (file && ![file isEqual:url]) return nil;
        file = url;
    }
    return file;
}

static NSURLRequest *plainRequest(NSURL *url) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:kSafariAgent forHTTPHeaderField:@"User-Agent"];
    return request;
}

// The MP4 under an HLS master playlist, on the main queue; nil when it is not one file or unreachable.
static void mp4UnderPlaylist(NSURL *master, void (^done)(NSURL *mp4, BOOL reached)) {
    fetch(plainRequest(master), ^(NSData *data, NSInteger status) {
        NSURL *variant = status == 200 ? chooseVariant(textOf(data) ?: @"", master) : nil;
        if (!variant) {
            done(nil, status == 200);
            return;
        }
        fetch(plainRequest(variant), ^(NSData *media, NSInteger mediaStatus) {
            NSURL *file = mediaStatus == 200 ? singleFileOf(textOf(media) ?: @"", variant) : nil;
            done(file, mediaStatus == 200);
        });
    });
}

#pragma mark - Apple Music album covers

// Main thread. An answer is an SGArtworkClip or NSNull.
static NSMutableDictionary<NSString *, id> *sg_albumAnswers;
static NSMutableDictionary<NSString *, NSMutableArray<void (^)(SGArtworkClip *)> *> *sg_albumWaiters;

static NSString *videoIn(NSDictionary *album, BOOL tall) {
    NSDictionary *videos = album[@"attributes"][@"editorialVideo"];
    if (![videos isKindOfClass:NSDictionary.class]) return nil;
    NSArray<NSString *> *tallKeys = @[@"motionTallVideo3x4", @"motionDetailTall"];
    NSArray<NSString *> *squareKeys = @[@"motionSquareVideo1x1", @"motionDetailSquare"];
    NSArray<NSString *> *keys = tall ? [tallKeys arrayByAddingObjectsFromArray:squareKeys] : [squareKeys arrayByAddingObjectsFromArray:tallKeys];
    for (NSString *key in keys) {
        id entry = videos[key];
        NSString *video = [entry isKindOfClass:NSDictionary.class] ? stringIn(entry[@"video"]) : nil;
        if (video) return video;
    }
    return nil;
}

// The album by `artist` called `album` that has a cover video: the exact title first, then the titles
// with their editions taken off.
static NSDictionary *matchAlbum(NSArray<NSDictionary *> *albums, NSString *artist, NSString *album, BOOL tall) {
    NSString *exact = plainName(album), *bare = plainName(withoutEdition(album));
    for (NSUInteger pass = 0; pass < 2; pass++) {
        for (NSDictionary *candidate in albums) {
            if (![candidate isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *attributes = candidate[@"attributes"];
            if (![attributes isKindOfClass:NSDictionary.class] || !artistMatches(artist, attributes[@"artistName"])) continue;
            NSString *name = stringIn(attributes[@"name"]);
            BOOL same = pass == 0 ? [plainName(name) isEqualToString:exact] : [plainName(withoutEdition(name)) isEqualToString:bare];
            if (same && videoIn(candidate, tall)) return candidate;
        }
    }
    return nil;
}

static void finishAlbum(NSString *key, SGArtworkClip *clip, BOOL remember) {
    if (remember) sg_albumAnswers[key] = clip ?: (id)NSNull.null;
    NSArray<void (^)(SGArtworkClip *)> *waiters = sg_albumWaiters[key];
    [sg_albumWaiters removeObjectForKey:key];
    for (void (^waiter)(SGArtworkClip *) in waiters) waiter(clip);
}

// Main thread, `done` on it.
static void appleMusicAlbumClip(NSString *artist, NSString *album, BOOL tall, NSString *tag, void (^done)(SGArtworkClip *clip)) {
    if (!sg_albumAnswers) {
        sg_albumAnswers = [NSMutableDictionary dictionary];
        sg_albumWaiters = [NSMutableDictionary dictionary];
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@|%d", plainName(artist), plainName(album), tall];
    id answer = sg_albumAnswers[key];
    if (answer) {
        done([answer isKindOfClass:SGArtworkClip.class] ? answer : nil);
        return;
    }
    if (appleMusicPaused()) {
        SGLog(@"%@: apple music paused after a refusal", tag);
        done(nil);
        return;
    }
    if (sg_albumWaiters[key]) {
        [sg_albumWaiters[key] addObject:done];
        return;
    }
    sg_albumWaiters[key] = [NSMutableArray arrayWithObject:done];
    NSString *term = [NSString stringWithFormat:@"%@ %@", withoutEdition(album), artist];
    NSString *query = [NSString stringWithFormat:@"term=%@&types=albums&limit=25&extend=editorialVideo", queryValue(term)];
    appleMusicGET(@"search", query, 0, ^(NSDictionary *json) {
        if (!json) {
            finishAlbum(key, nil, NO);
            return;
        }
        NSDictionary *match = matchAlbum(searchResults(json, @"albums"), artist, album, tall);
        NSURL *master = match ? [NSURL URLWithString:videoIn(match, tall)] : nil;
        if (!master) {
            SGLog(@"%@: apple music has no cover video for \"%@\" by %@", tag, album, artist);
            finishAlbum(key, nil, YES);
            return;
        }
        mp4UnderPlaylist(master, ^(NSURL *mp4, BOOL reached) {
            if (!mp4) {
                SGLog(@"%@: apple music's cover video for \"%@\" is not one file", tag, album);
                finishAlbum(key, nil, reached);
                return;
            }
            SGArtworkClip *clip = [SGArtworkClip new];
            clip.identifier = [@"am-" stringByAppendingString:safeName(mp4.URLByDeletingPathExtension.lastPathComponent) ?: safeName(stringIn(match[@"id"])) ?: @"album"];
            clip.remoteURL = mp4;
            clip.source = SGArtworkSourceAppleMusic;
            SGLog(@"%@: apple music album %@ \"%@\", %@", tag, match[@"id"], match[@"attributes"][@"name"], mp4.lastPathComponent);
            finishAlbum(key, clip, YES);
        });
    });
}

#pragma mark - Spotify canvas

static SGArtworkClip *spotifyClip(NSDictionary *metadata) {
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    NSString *type = stringIn(metadata[@"canvas.type"]).uppercaseString;
    if (![type hasPrefix:@"VIDEO"]) return nil;
    NSString *address = stringIn(metadata[@"canvas.url"]);
    NSURL *url = address ? [NSURL URLWithString:address] : nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return nil;
    NSString *identity = stringIn(metadata[@"canvas.id"]) ?: stringIn(metadata[@"canvas.fileId"]) ?: url.URLByDeletingPathExtension.lastPathComponent;
    SGArtworkClip *clip = [SGArtworkClip new];
    clip.identifier = [@"sp-" stringByAppendingString:safeName(identity) ?: @"canvas"];
    clip.remoteURL = url;
    clip.source = SGArtworkSourceSpotify;
    return clip;
}

#pragma mark - Finding a clip

@interface SGClipSearch : NSObject
@property (nonatomic, copy) NSString *artist, *album, *tag;
@property (nonatomic, copy) NSDictionary *metadata;
@property (nonatomic, copy) NSArray<NSString *> *order;
@property (nonatomic) BOOL tall;
@property (nonatomic, copy) BOOL (^wanted)(void);
@property (nonatomic, copy) void (^done)(SGArtworkClip *clip);
@end

@implementation SGClipSearch
@end

static BOOL stillWanted(SGClipSearch *search) {
    return !search.wanted || search.wanted();
}

// Always later on the main queue, so `done` never runs before SGArtworkFindClip returns.
static void finishSearch(SGClipSearch *search, SGArtworkClip *clip) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (stillWanted(search) && search.done) search.done(clip);
    });
}

static void askSource(SGClipSearch *search, NSUInteger index) {
    if (!stillWanted(search)) return;
    if (index >= search.order.count) {
        SGLog(@"%@: no clip from %@", search.tag, [search.order componentsJoinedByString:@", "]);
        finishSearch(search, nil);
        return;
    }
    NSString *source = search.order[index];
    if ([source isEqualToString:SGArtworkSourceSpotify]) {
        SGArtworkClip *clip = spotifyClip(search.metadata);
        SGLog(@"%@: spotify canvas %@", search.tag, clip ? clip.identifier : [NSString stringWithFormat:@"none (%@)", stringIn(search.metadata[@"canvas.type"]) ?: @"no canvas"]);
        if (clip) finishSearch(search, clip);
        else askSource(search, index + 1);
        return;
    }
    if ([source isEqualToString:SGArtworkSourceAppleMusic]) {
        if (!stringIn(search.artist) || !stringIn(search.album)) {
            SGLog(@"%@: apple music skipped, no artist or album", search.tag);
            askSource(search, index + 1);
            return;
        }
        appleMusicAlbumClip(search.artist, search.album, search.tall, search.tag, ^(SGArtworkClip *clip) {
            if (!stillWanted(search)) return;
            if (clip) finishSearch(search, clip);
            else askSource(search, index + 1);
        });
        return;
    }
    askSource(search, index + 1);
}

void SGArtworkFindClip(NSString *trackURI, NSString *artist, NSString *album, NSDictionary *metadata,
                       NSArray<NSString *> *order, BOOL tall, NSString *tag,
                       BOOL (^wanted)(void), void (^done)(SGArtworkClip *clip)) {
    SGClipSearch *search = [SGClipSearch new];
    search.artist = artist;
    search.album = album;
    search.metadata = metadata;
    search.order = cleanOrder(order) ?: @[];
    search.tall = tall;
    search.tag = tag.length ? tag : @"artwork";
    search.wanted = wanted;
    search.done = done;
    if (SGSpotifyDataSaverOn()) {
        SGLog(@"%@: Spotify's Data Saver is on, no clip looked for", search.tag);
        finishSearch(search, nil);
        return;
    }
    SGLog(@"%@: looking for a %@ clip for %@ (%@)", search.tag, tall ? @"tall" : @"square", trackURI, [search.order componentsJoinedByString:@", "]);
    askSource(search, 0);
}

#pragma mark - Cache

static const unsigned long long kCacheBytes = 120ull * 1024 * 1024;
// Files touched this recently are never evicted: something may be playing them.
static const NSTimeInterval kInUse = 10 * 60;
static NSString *const kTempPrefix = @"tmp-";

static NSURL *cacheDirectory(void) {
    static NSURL *directory;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        directory = [caches URLByAppendingPathComponent:@"Glassify/Artwork" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return directory;
}

// Crops, first frames' reads of the folder, and eviction.
static dispatch_queue_t cacheQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("spotifyglass.artwork.cache", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static NSURL *tempFile(void) {
    return [cacheDirectory() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.mp4", kTempPrefix, NSUUID.UUID.UUIDString]];
}

static BOOL cached(NSURL *file) {
    NSNumber *size = nil;
    [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    return size.unsignedLongLongValue > 0;
}

// Marks the file as just used, for the least recently used order.
static void touch(NSURL *file) {
    [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate: NSDate.date} ofItemAtPath:file.path error:nil];
}

// Moves `from` to `to` in one step, unless `to` is already there: a file in place is never replaced,
// so a player that has it open keeps reading the same bytes.
static BOOL place(NSURL *from, NSURL *to) {
    if (cached(to)) {
        [NSFileManager.defaultManager removeItemAtURL:from error:nil];
        return YES;
    }
    BOOL moved = rename(from.fileSystemRepresentation, to.fileSystemRepresentation) == 0;
    if (!moved) [NSFileManager.defaultManager removeItemAtURL:from error:nil];
    return moved;
}

// Main thread: slot -> file name stem handed out last, spared by eviction with all its crops.
static NSMutableDictionary<NSString *, NSString *> *sg_pinned;

static void evict(NSSet<NSString *> *pinned) {
    NSArray<NSURLResourceKey> *keys = @[NSURLFileSizeKey, NSURLContentModificationDateKey];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:cacheDirectory() includingPropertiesForKeys:keys options:0 error:nil];
    NSDate *now = NSDate.date;
    unsigned long long total = 0;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSURL *file in files) {
        NSDictionary *values = [file resourceValuesForKeys:keys error:nil];
        NSDate *date = values[NSURLContentModificationDateKey] ?: now;
        unsigned long long size = [values[NSURLFileSizeKey] unsignedLongLongValue];
        if ([file.lastPathComponent hasPrefix:kTempPrefix]) {
            // A crop or a download left behind by a crash; one still being written is younger than this.
            if ([now timeIntervalSinceDate:date] > 3600) [NSFileManager.defaultManager removeItemAtURL:file error:nil];
            continue;
        }
        total += size;
        [entries addObject:@{@"file": file, @"date": date, @"size": @(size)}];
    }
    if (total <= kCacheBytes) return;
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"date"] compare:b[@"date"]];
    }];
    for (NSDictionary *entry in entries) {
        if (total <= kCacheBytes) break;
        NSURL *file = entry[@"file"];
        if ([now timeIntervalSinceDate:entry[@"date"]] < kInUse) continue;
        NSString *name = file.lastPathComponent;
        BOOL spared = NO;
        for (NSString *stem in pinned) spared = spared || [name hasPrefix:stem];
        if (spared) continue;
        if ([NSFileManager.defaultManager removeItemAtURL:file error:nil]) {
            total -= [entry[@"size"] unsignedLongLongValue];
            SGLog(@"artwork cache: evicted %@", name);
        }
    }
}

// Main thread.
static void evictLater(void) {
    NSSet<NSString *> *pinned = [NSSet setWithArray:sg_pinned.allValues ?: @[]];
    dispatch_async(cacheQueue(), ^{
        evict(pinned);
    });
}

#pragma mark - Downloads

@interface SGArtworkFetch : NSObject
@property (nonatomic, strong) NSURLSessionDownloadTask *task;
@property (nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSURL *, NSString *)> *waiters;   // slot -> done
@end

@implementation SGArtworkFetch
@end

// Main thread: file name -> its download, shared by every slot asking for it; slot -> file name it waits on.
static NSMutableDictionary<NSString *, SGArtworkFetch *> *sg_fetches;
static NSMutableDictionary<NSString *, NSString *> *sg_slotFetches;

// Callbacks on the main queue, where the state above lives.
static NSURLSession *downloadSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        session = [NSURLSession sessionWithConfiguration:ephemeralConfiguration(180) delegate:nil delegateQueue:NSOperationQueue.mainQueue];
    });
    return session;
}

static void finishFetch(NSString *name, NSURL *location, NSURLResponse *response, NSError *error) {
    SGArtworkFetch *fetch = sg_fetches[name];
    if (!fetch) return;
    [sg_fetches removeObjectForKey:name];
    for (NSString *slot in fetch.waiters) {
        if ([sg_slotFetches[slot] isEqualToString:name]) [sg_slotFetches removeObjectForKey:slot];
    }
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    NSURL *file = [cacheDirectory() URLByAppendingPathComponent:name];
    NSString *note = nil;
    if (error) note = error.code == NSURLErrorCancelled ? @"cancelled" : error.localizedDescription;
    else if (status < 200 || status > 299) note = [NSString stringWithFormat:@"HTTP %ld", (long)status];
    else if (!location) note = @"no file";
    else {
        // The system deletes `location` when this returns, so it is moved now, beside the cache, then into place.
        NSURL *temp = tempFile();
        if (![NSFileManager.defaultManager moveItemAtURL:location toURL:temp error:nil] || !cached(temp) || !place(temp, file)) note = @"could not store";
    }
    if (note) {
        SGLog(@"artwork cache: %@ failed, %@", name, note);
        file = nil;
    } else {
        SGLog(@"artwork cache: stored %@", name);
        touch(file);
        evictLater();
    }
    for (void (^done)(NSURL *, NSString *) in fetch.waiters.allValues) done(file, note);
}

void SGArtworkCancelDownload(NSString *slot) {
    if (!slot) return;
    NSString *name = sg_slotFetches[slot];
    if (!name) return;
    [sg_slotFetches removeObjectForKey:slot];
    SGArtworkFetch *fetch = sg_fetches[name];
    [fetch.waiters removeObjectForKey:slot];
    if (fetch && !fetch.waiters.count) {
        [sg_fetches removeObjectForKey:name];
        [fetch.task cancel];
        SGLog(@"artwork cache: %@ cancelled", name);
    }
}

void SGArtworkDownload(NSString *slot, SGArtworkClip *clip, void (^done)(NSURL *file, NSString *note)) {
    if (!sg_fetches) {
        sg_fetches = [NSMutableDictionary dictionary];
        sg_slotFetches = [NSMutableDictionary dictionary];
        sg_pinned = [NSMutableDictionary dictionary];
    }
    slot = slot ?: @"";
    SGArtworkCancelDownload(slot);
    NSString *stem = safeName(clip.identifier);
    if (!stem || !clip.remoteURL) {
        done(nil, @"no clip");
        return;
    }
    NSString *name = [stem stringByAppendingPathExtension:@"mp4"];
    NSURL *file = [cacheDirectory() URLByAppendingPathComponent:name];
    sg_pinned[slot] = stem;
    if (cached(file)) {
        touch(file);
        done(file, nil);
        return;
    }
    if (SGSpotifyDataSaverOn()) {
        done(nil, @"Data Saver is on");
        return;
    }
    SGArtworkFetch *fetch = sg_fetches[name];
    if (!fetch) {
        fetch = [SGArtworkFetch new];
        fetch.waiters = [NSMutableDictionary dictionary];
        fetch.task = [downloadSession() downloadTaskWithRequest:plainRequest(clip.remoteURL)
                                              completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            finishFetch(name, location, response, error);
        }];
        sg_fetches[name] = fetch;
        [fetch.task resume];
        SGLog(@"artwork cache: downloading %@ for %@", name, slot);
    }
    fetch.waiters[slot] = [done copy];
    sg_slotFetches[slot] = name;
}

#pragma mark - Crops

// Cache queue: crop file name -> who waits on it.
static NSMutableDictionary<NSString *, NSMutableArray<void (^)(NSURL *)> *> *sg_crops;

static void exportCrop(AVAsset *asset, AVVideoComposition *composition, NSURL *output, NSArray<NSString *> *presets, void (^done)(NSURL *file)) {
    AVAssetExportSession *session = presets.count ? [[AVAssetExportSession alloc] initWithAsset:asset presetName:presets.firstObject] : nil;
    if (!session) {
        done(nil);
        return;
    }
    NSURL *temp = tempFile();
    session.outputURL = temp;
    session.outputFileType = AVFileTypeMPEG4;
    session.videoComposition = composition;
    [session exportAsynchronouslyWithCompletionHandler:^{
        if (session.status == AVAssetExportSessionStatusCompleted && cached(temp)) {
            dispatch_async(cacheQueue(), ^{
                done(place(temp, output) ? output : nil);
            });
            return;
        }
        [NSFileManager.defaultManager removeItemAtURL:temp error:nil];
        SGLog(@"artwork crop: %@ failed, %@", presets.firstObject, session.error.localizedDescription);
        exportCrop(asset, composition, output, [presets subarrayWithRange:NSMakeRange(1, presets.count - 1)], done);
    }];
}

// The centre of `file` at `aspect` into `output`, or `file` itself when it is that shape already.
static void cropInto(NSURL *file, NSURL *output, CGFloat aspect, void (^done)(NSURL *file)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
    [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        AVAssetTrack *track = tracks.firstObject;
        if (!track) {
            SGLog(@"artwork crop: no video in %@", file.lastPathComponent);
            done(nil);
            return;
        }
        NSArray<NSString *> *trackKeys = @[@"naturalSize", @"preferredTransform", @"nominalFrameRate"];
        [track loadValuesAsynchronouslyForKeys:trackKeys completionHandler:^{
            [asset loadValuesAsynchronouslyForKeys:@[@"duration"] completionHandler:^{
                for (NSString *key in trackKeys) {
                    if ([track statusOfValueForKey:key error:nil] != AVKeyValueStatusLoaded) {
                        done(nil);
                        return;
                    }
                }
                if ([asset statusOfValueForKey:@"duration" error:nil] != AVKeyValueStatusLoaded) {
                    done(nil);
                    return;
                }
                CGAffineTransform transform = track.preferredTransform;
                CGRect shown = CGRectApplyAffineTransform((CGRect){CGPointZero, track.naturalSize}, transform);
                CGFloat width = fabs(shown.size.width), height = fabs(shown.size.height);
                if (width < 2 || height < 2) {
                    done(nil);
                    return;
                }
                if (fabs(width / height / aspect - 1) <= 0.02) {
                    done(file);
                    return;
                }
                CGFloat cropWidth = width, cropHeight = height;
                if (width / height > aspect) cropWidth = height * aspect;
                else cropHeight = width / aspect;
                cropWidth = 2 * floor(cropWidth / 2);
                cropHeight = 2 * floor(cropHeight / 2);
                CGFloat x = round((width - cropWidth) / 2), y = round((height - cropHeight) / 2);
                // The track drawn upright with its origin at the top left, then moved so the centre shows.
                CGAffineTransform drawn = CGAffineTransformConcat(transform, CGAffineTransformMakeTranslation(-CGRectGetMinX(shown) - x, -CGRectGetMinY(shown) - y));
                AVMutableVideoCompositionLayerInstruction *layer = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:track];
                [layer setTransform:drawn atTime:kCMTimeZero];
                AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
                instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
                instruction.layerInstructions = @[layer];
                AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
                composition.renderSize = CGSizeMake(cropWidth, cropHeight);
                float rate = track.nominalFrameRate;
                composition.frameDuration = CMTimeMake(1, rate >= 1 ? (int32_t)lroundf(rate) : 30);
                composition.instructions = @[instruction];
                SGLog(@"artwork crop: %@ %.0fx%.0f to %.0fx%.0f", file.lastPathComponent, width, height, cropWidth, cropHeight);
                exportCrop(asset, composition, output, @[AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality], done);
            }];
        }];
    }];
}

void SGArtworkCrop(NSURL *file, NSString *identifier, CGFloat aspect, void (^done)(NSURL *file)) {
    if (!file || !(aspect > 0)) {
        done(nil);
        return;
    }
    dispatch_async(cacheQueue(), ^{
        NSString *stem = safeName(identifier) ?: safeName(file.URLByDeletingPathExtension.lastPathComponent) ?: @"clip";
        NSString *name = [NSString stringWithFormat:@"%@-crop%ld.mp4", stem, lround(aspect * 1000)];
        NSURL *output = [cacheDirectory() URLByAppendingPathComponent:name];
        if (cached(output)) {
            touch(output);
            done(output);
            return;
        }
        if (!sg_crops) sg_crops = [NSMutableDictionary dictionary];
        if (sg_crops[name]) {
            [sg_crops[name] addObject:done];
            return;
        }
        sg_crops[name] = [NSMutableArray arrayWithObject:done];
        cropInto(file, output, aspect, ^(NSURL *result) {
            dispatch_async(cacheQueue(), ^{
                if (result) touch(result);
                NSArray<void (^)(NSURL *)> *waiters = sg_crops[name];
                [sg_crops removeObjectForKey:name];
                for (void (^waiter)(NSURL *) in waiters) waiter(result);
            });
        });
    });
}

#pragma mark - First frame

void SGArtworkFirstFrame(NSURL *file, void (^done)(UIImage *frame)) {
    if (!file) {
        done(nil);
        return;
    }
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:[AVURLAsset URLAssetWithURL:file options:nil]];
    generator.appliesPreferredTrackTransform = YES;
    generator.requestedTimeToleranceBefore = kCMTimeZero;
    generator.requestedTimeToleranceAfter = kCMTimeZero;
    // The block holds the generator until it answers.
    [generator generateCGImageAsynchronouslyForTime:kCMTimeZero completionHandler:^(CGImageRef image, CMTime actual, NSError *error) {
        (void)generator;
        if (!image) SGLog(@"artwork frame: %@ unreadable, %@", file.lastPathComponent, error.localizedDescription);
        done(image ? [UIImage imageWithCGImage:image] : nil);
    }];
}

#pragma mark - Artist logos

// Main thread: plain artist name -> @{template, width, height} or NSNull.
static NSMutableDictionary<NSString *, id> *sg_logoAnswers;
static NSMutableDictionary<NSString *, NSMutableArray<void (^)(void)> *> *sg_logoWaiters;

static NSURL *logoURL(NSDictionary *logo, CGFloat pixelWidth) {
    NSString *template = logo[@"template"];
    double width = [logo[@"width"] doubleValue], height = [logo[@"height"] doubleValue];
    long w = lround(pixelWidth > 0 ? pixelWidth : 600);
    long h = width > 0 && height > 0 ? MAX(lround(w * height / width), 1) : w;
    NSString *address = [template stringByReplacingOccurrencesOfString:@"{w}" withString:@(w).stringValue];
    address = [address stringByReplacingOccurrencesOfString:@"{h}" withString:@(h).stringValue];
    // PNG keeps the transparency around the letters.
    NSRegularExpression *extension = [NSRegularExpression regularExpressionWithPattern:@"\\.(jpe?g|webp|heic)$" options:NSRegularExpressionCaseInsensitive error:nil];
    address = [extension stringByReplacingMatchesInString:address options:0 range:NSMakeRange(0, address.length) withTemplate:@".png"];
    return [NSURL URLWithString:address];
}

static id logoIn(NSArray<NSDictionary *> *artists, NSString *artist) {
    NSString *wanted = plainName(artist);
    for (NSDictionary *candidate in artists) {
        if (![candidate isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *attributes = candidate[@"attributes"];
        if (![attributes isKindOfClass:NSDictionary.class] || ![plainName(attributes[@"name"]) isEqualToString:wanted]) continue;
        NSDictionary *artwork = attributes[@"editorialArtwork"];
        NSDictionary *logo = [artwork isKindOfClass:NSDictionary.class] ? artwork[@"musicContentColorLogoTrimmed"] : nil;
        NSString *template = [logo isKindOfClass:NSDictionary.class] ? stringIn(logo[@"url"]) : nil;
        if (!template) return NSNull.null;
        return @{@"template": template, @"width": logo[@"width"] ?: @0, @"height": logo[@"height"] ?: @0};
    }
    return NSNull.null;
}

void SGAppleMusicArtistLogo(NSString *artist, CGFloat pixelWidth, void (^done)(NSURL *logo)) {
    void (^answer)(id) = ^(id found) {
        NSURL *url = [found isKindOfClass:NSDictionary.class] ? logoURL(found, pixelWidth) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            done(url);
        });
    };
    NSString *key = plainName(artist);
    if (!key.length || SGSpotifyDataSaverOn()) {
        answer(nil);
        return;
    }
    if (!sg_logoAnswers) {
        sg_logoAnswers = [NSMutableDictionary dictionary];
        sg_logoWaiters = [NSMutableDictionary dictionary];
    }
    if (sg_logoAnswers[key]) {
        answer(sg_logoAnswers[key]);
        return;
    }
    if (appleMusicPaused()) {
        answer(nil);
        return;
    }
    void (^waiter)(void) = ^{
        answer(sg_logoAnswers[key]);
    };
    if (sg_logoWaiters[key]) {
        [sg_logoWaiters[key] addObject:waiter];
        return;
    }
    sg_logoWaiters[key] = [NSMutableArray arrayWithObject:waiter];
    NSString *query = [NSString stringWithFormat:@"term=%@&types=artists&limit=10&extend=editorialArtwork", queryValue(artist)];
    appleMusicGET(@"search", query, 0, ^(NSDictionary *json) {
        // A failed request is not remembered, so the artist is asked about again next time.
        if (json) {
            sg_logoAnswers[key] = logoIn(searchResults(json, @"artists"), artist);
            SGLog(@"apple music: logo for %@ %@", artist, [sg_logoAnswers[key] isKindOfClass:NSDictionary.class] ? @"found" : @"none");
        }
        NSArray<void (^)(void)> *waiters = sg_logoWaiters[key];
        [sg_logoWaiters removeObjectForKey:key];
        for (void (^waiting)(void) in waiters) waiting();
    });
}
