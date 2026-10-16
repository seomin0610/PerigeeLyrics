#import "RL.h"

static id RLAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }
static double RLNumOf(id v) { return [RLAs(v, NSNumber.class) doubleValue]; }
static id RLJSON(NSData *d) { return d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil; }

static id RLDig(id o, NSArray<NSString *> *path) {
	for (NSString *k in path) o = RLAs(o, NSDictionary.class)[k];
	return o;
}

static NSString *RLQuery(NSDictionary<NSString *, NSString *> *q) {
	NSMutableArray *parts = [NSMutableArray array];
	[q enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [parts addObject:[NSString stringWithFormat:@"%@=%@", k, RLEnc(v)]]; }];
	return [parts componentsJoinedByString:@"&"];
}

static NSString *RLTrim(NSString *s) { return [s ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }

static void RLSpaceAfter(RLSyl *s) {
	if (s && ![s.text hasSuffix:@" "]) s.text = [s.text stringByAppendingString:@" "];
}

// Word timing only lands on the beat when the recording is the same take.
static const double kRLSlack = 4;

static BOOL RLSameLength(double got, double want) { return got <= 0 || want <= 0 || fabs(got - want) <= kRLSlack; }

#pragma mark - Apple TTML (Unison, BiniLyrics)

@interface RLTTML : NSObject <NSXMLParserDelegate> {
	@public
	NSMutableDictionary<NSString *, NSString *> *_agents, *_trans;
	NSMutableArray<NSMutableDictionary *> *_ps;
	NSMutableDictionary<NSString *, NSMutableDictionary *> *_roman;
	NSMutableDictionary *_cur;
	NSMutableArray<NSMutableDictionary *> *_spans;
	RLSyl *_last;
	NSInteger _section;
	BOOL _enTrans;
}
@end

@implementation RLTTML
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)qn attributes:(NSDictionary<NSString *, NSString *> *)attrs {
	NSString *xid = attrs[@"xml:id"] ?: attrs[@"id"], *lang = attrs[@"xml:lang"] ?: attrs[@"lang"];
	if ([name hasSuffix:@"agent"] && xid) { _agents[xid] = attrs[@"type"] ?: @"person"; return; }
	if ([name isEqualToString:@"transliteration"]) { _section = _roman.count ? 3 : 1; return; }
	if ([name isEqualToString:@"translation"]) { _section = 2; _enTrans = [lang hasPrefix:@"en"] && !_trans.count; return; }
	if ([name isEqualToString:@"p"] || ([name isEqualToString:@"text"] && attrs[@"for"])) {
		_cur = [@{ @"main": [NSMutableArray array], @"bg": [NSMutableArray array], @"plain": [NSMutableString string] } mutableCopy];
		_cur[@"begin"] = attrs[@"begin"];
		_cur[@"end"] = attrs[@"end"];
		_cur[@"agent"] = attrs[@"ttm:agent"];
		NSString *key = attrs[@"for"];
		for (NSString *a in attrs)
			if ([a hasSuffix:@":key"]) key = attrs[a];
		_cur[@"key"] = key;
		_last = nil;
		[_spans removeAllObjects];
		return;
	}
	if ([name isEqualToString:@"span"] && _cur) {
		_spans.lastObject[@"kids"] = @YES;
		BOOL bg = [_spans.lastObject[@"bg"] boolValue] || [attrs[@"ttm:role"] isEqualToString:@"x-bg"];
		NSMutableDictionary *f = [@{ @"bg": @(bg), @"text": [NSMutableString string] } mutableCopy];
		f[@"begin"] = attrs[@"begin"];
		f[@"end"] = attrs[@"end"];
		[_spans addObject:f];
	}
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
	if (!_cur) return;
	if (_section == 2) { [_cur[@"plain"] appendString:string]; return; }
	NSMutableDictionary *top = _spans.lastObject;
	if (top && ![top[@"kids"] boolValue]) { [top[@"text"] appendString:string]; return; }
	if (!RLTrim(string).length) {
		RLSpaceAfter(_last);
		if (!top) [_cur[@"plain"] appendString:@" "];
	} else if (!top) [_cur[@"plain"] appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)qn {
	if ([name isEqualToString:@"span"] && _cur && _spans.count) {
		NSMutableDictionary *f = _spans.lastObject;
		[_spans removeLastObject];
		if ([f[@"kids"] boolValue]) return;
		NSString *raw = f[@"text"], *text = RLTrim(raw);
		NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
		if (raw.length && [ws characterIsMember:[raw characterAtIndex:0]]) RLSpaceAfter(_last);
		if (!text.length) return;
		if (!f[@"begin"]) { [_cur[@"plain"] appendString:raw]; return; }
		BOOL space = [ws characterIsMember:[raw characterAtIndex:raw.length - 1]];
		RLSyl *s = RLMakeSyl(space ? [text stringByAppendingString:@" "] : text, RLClock(f[@"begin"]), RLClock(f[@"end"] ?: f[@"begin"]));
		[_cur[[f[@"bg"] boolValue] ? @"bg" : @"main"] addObject:s];
		_last = s;
		return;
	}
	if (([name isEqualToString:@"p"] || [name isEqualToString:@"text"]) && _cur) {
		NSString *key = _cur[@"key"];
		if ([name isEqualToString:@"p"]) [_ps addObject:_cur];
		else if (_section == 1 && key) _roman[key] = _cur;
		else if (_section == 2 && _enTrans && key) _trans[key] = _cur[@"plain"];
		_cur = nil;
		_last = nil;
		return;
	}
	if ([name isEqualToString:@"transliteration"] || [name isEqualToString:@"translation"]) _section = 0;
}
@end

NSArray<RLLine *> *RLParseTTML(NSData *d, BOOL romanize) {
	RLTTML *t = [RLTTML new];
	t->_agents = [NSMutableDictionary dictionary];
	t->_trans = [NSMutableDictionary dictionary];
	t->_ps = [NSMutableArray array];
	t->_roman = [NSMutableDictionary dictionary];
	t->_spans = [NSMutableArray array];
	NSXMLParser *parser = [[NSXMLParser alloc] initWithData:d];
	parser.delegate = t;
	[parser parse];
	NSMutableArray *singers = [NSMutableArray array];
	for (NSDictionary *c in t->_ps) [singers addObject:c[@"agent"] ?: NSNull.null];
	NSArray *sides = RLSides(singers, t->_agents);
	NSMutableArray *lines = [NSMutableArray array];
	[t->_ps enumerateObjectsUsingBlock:^(NSDictionary *c, NSUInteger i, BOOL *stop) {
		NSDictionary *src = romanize && c[@"key"] && t->_roman[c[@"key"]] ? t->_roman[c[@"key"]] : c;
		NSMutableArray *main = [src[@"main"] mutableCopy], *bg = [src[@"bg"] mutableCopy];
		NSString *plain = RLCollapse(RLTrim(c[@"plain"]));
		RLSyl *first = [c[@"main"] firstObject];
		double start = c[@"begin"] ? RLClock(c[@"begin"]) : first.start;
		if (!main.count && !bg.count) [main addObjectsFromArray:RLWords(RLCollapse(RLTrim(src[@"plain"])), start)];
		NSString *keyText = [c[@"main"] count] ? [[c[@"main"] valueForKey:@"text"] componentsJoinedByString:@""] : plain;
		RLLine *line = RLMakeLine(start, RLClock(c[@"end"]), main, bg, keyText, [sides[i] boolValue]);
		if (!line) return;
		NSString *tr = RLCollapse(RLTrim(c[@"key"] ? t->_trans[c[@"key"]] : nil));
		if (tr.length && ![RLLineKey(tr) isEqualToString:line.key]) line.tr = RLWords(tr, line.start);
		[lines addObject:line];
	}];
	return lines;
}

NSData *RLUnisonGet(NSString *title, NSString *artist, double duration) {
	NSMutableDictionary *q = [@{ @"song": title, @"artist": artist } mutableCopy];
	if (duration > 0) q[@"duration"] = @(llround(duration)).stringValue;
	NSData *d;
	NSInteger st = RLGet([@"https://unison.boidu.dev/lyrics?" stringByAppendingString:RLQuery(q)], nil, 8, &d);
	NSDictionary *data = RLAs(RLDig(RLJSON(d), @[ @"data" ]), NSDictionary.class);
	NSString *ttml = [data[@"format"] isEqual:@"ttml"] && RLSameLength(RLNumOf(data[@"duration"]), duration) ? RLAs(data[@"lyrics"], NSString.class) : nil;
	RLLog(@"unison: %ld %@", (long)st, ttml ? data[@"syncType"] : @"none");
	return [ttml dataUsingEncoding:NSUTF8StringEncoding];
}

NSData *RLBiniGet(NSString *title, NSString *artist, NSString *isrc, double duration) {
	if (duration <= 0 && !isrc.length) return nil;
	NSMutableDictionary *q = [@{ @"track": title, @"artist": artist } mutableCopy];
	if (duration > 0) q[@"duration"] = @(llround(duration)).stringValue;
	NSData *d;
	NSInteger st = RLGet([@"https://lyrics-api.binimum.org/?" stringByAppendingString:RLQuery(q)], nil, 8, &d);
	NSDictionary *best;
	NSInteger bestScore = -1;
	for (NSDictionary *r in RLAs(RLDig(RLJSON(d), @[ @"results" ]), NSArray.class)) {
		if (![RLAs(RLAs(r, NSDictionary.class)[@"lyricsUrl"], NSString.class) hasPrefix:@"https://"]) continue;
		BOOL sameIsrc = isrc.length && [RLAs(r[@"isrc"], NSString.class) isEqualToString:isrc];
		if (!sameIsrc && !RLSameLength(RLNumOf(r[@"duration"]), duration)) continue;
		NSInteger score = sameIsrc * 2 + [r[@"timing_type"] isEqual:@"word"];
		if (score > bestScore) bestScore = score, best = r;
	}
	if (!best) { RLLog(@"binilyrics: %ld, no match", (long)st); return nil; }
	NSData *ttml;
	st = RLGet(best[@"lyricsUrl"], nil, 8, &ttml);
	RLLog(@"binilyrics: %ld %@", (long)st, best[@"timing_type"]);
	return st == 200 ? ttml : nil;
}

#pragma mark - Musixmatch

static NSDictionary *RLMxmTrack(id body) { return RLAs(RLDig(body, @[ @"macro_calls", @"matcher.track.get", @"message", @"body", @"track" ]), NSDictionary.class); }

NSData *RLMxmGet(NSString *title, NSString *artist, NSString *isrc, double duration) {
	NSString *token;
	for (int attempt = 0; attempt < 2; attempt++) {
		token = RLMxmToken(token);
		if (!token) return nil;
		NSMutableDictionary *q = [@{ @"usertoken": token, @"q_track": title, @"q_artist": artist, @"namespace": @"lyrics_richsynched",
		                             @"subtitle_format": @"mxm", @"optional_calls": @"track.richsync", @"richsync_compact_type": @"words" } mutableCopy];
		if (duration > 0) q[@"q_duration"] = @(llround(duration)).stringValue;
		if (isrc.length) q[@"track_isrc"] = isrc;
		NSInteger st;
		NSDictionary *body = RLMxm(@"macro.subtitles.get", RLQuery(q), &st);
		if (st == 401) continue;
		NSDictionary *track = RLMxmTrack(body);
		BOOL ok = track && ![RLAs(track[@"instrumental"], NSNumber.class) boolValue] && RLSameLength(RLNumOf(track[@"track_length"]), duration);
		RLLog(@"musixmatch: %ld %@", (long)st, ok ? track[@"track_name"] : @"no match");
		return ok ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : nil;
	}
	return nil;
}

NSArray<RLLine *> *RLParseMxm(NSData *d) {
	NSDictionary *calls = RLAs(RLDig(RLJSON(d), @[ @"macro_calls" ]), NSDictionary.class);
	NSMutableArray *lines = [NSMutableArray array];
	NSDictionary *rich = RLAs(RLDig(calls, @[ @"track.richsync.get", @"message", @"body", @"richsync" ]), NSDictionary.class);
	if (rich && ![RLAs(rich[@"restricted"], NSNumber.class) boolValue]) {
		for (NSDictionary *e in RLAs(RLJSON([RLAs(rich[@"richsync_body"], NSString.class) dataUsingEncoding:NSUTF8StringEncoding]), NSArray.class)) {
			if (!RLAs(e, NSDictionary.class)) continue;
			double ts = RLNumOf(e[@"ts"]), te = RLNumOf(e[@"te"]);
			NSArray *parts = RLAs(e[@"l"], NSArray.class);
			NSMutableArray *main = [NSMutableArray array];
			[parts enumerateObjectsUsingBlock:^(NSDictionary *x, NSUInteger i, BOOL *stop) {
				NSString *c = RLAs(RLAs(x, NSDictionary.class)[@"c"], NSString.class);
				if (!RLTrim(c).length) { if (c.length) RLSpaceAfter(main.lastObject); return; }
				double o = RLNumOf(x[@"o"]), next = i + 1 < parts.count ? RLNumOf(RLAs(parts[i + 1], NSDictionary.class)[@"o"]) : te - ts;
				[main addObject:RLMakeSyl(c, ts + o, ts + next)];
			}];
			RLLine *line = RLMakeLine(ts, te, main, [NSMutableArray array], RLAs(e[@"x"], NSString.class), NO);
			if (line) [lines addObject:line];
		}
		if (lines.count) return lines;
	}
	NSArray *list = RLAs(RLDig(calls, @[ @"track.subtitles.get", @"message", @"body", @"subtitle_list" ]), NSArray.class);
	NSString *body = RLAs(RLDig(list.firstObject, @[ @"subtitle", @"subtitle_body" ]), NSString.class);
	NSArray *rows = RLAs(RLJSON([body dataUsingEncoding:NSUTF8StringEncoding]), NSArray.class);
	[rows enumerateObjectsUsingBlock:^(NSDictionary *r, NSUInteger i, BOOL *stop) {
		NSString *text = RLTrim(RLAs(RLAs(r, NSDictionary.class)[@"text"], NSString.class));
		double start = RLNumOf(RLDig(r, @[ @"time", @"total" ]));
		double end = i + 1 < rows.count ? RLNumOf(RLDig(rows[i + 1], @[ @"time", @"total" ])) : start + 5;
		RLLine *line = text.length ? RLMakeLine(start, end, [RLWords(text, start) mutableCopy], [NSMutableArray array], text, NO) : nil;
		if (line) [lines addObject:line];
	}];
	return lines;
}

#pragma mark - Spicy Lyrics (user's own key, Spotify track id from Musixmatch)

NSData *RLSpicyGet(NSData *mxm) {
	NSString *key = RLTrim([RLDefaults stringForKey:@"rl.spicyKey"]);
	if (![key hasPrefix:@"sl_pk_"] || !mxm) return nil;
	NSDictionary *track = RLMxmTrack(RLJSON(mxm));
	NSString *sid = RLAs(track[@"track_spotify_id"], NSString.class);
	if (sid.length != 22) sid = RLAs([RLAs(track[@"commontrack_spotify_ids"], NSArray.class) firstObject], NSString.class);
	if (sid.length != 22) { RLLog(@"spicy: no Spotify id"); return nil; }
	NSData *d;
	NSInteger st = RLGet([@"https://api.spicylyrics.org/v1/lyrics/" stringByAppendingString:sid], @{ @"Authorization": [@"Bearer " stringByAppendingString:key] }, 8, &d);
	id json = RLJSON(d);
	NSString *err = RLAs(RLDig(json, @[ @"error" ]), NSString.class) ?: RLAs(RLDig(json, @[ @"Body", @"error" ]), NSString.class);
	RLLog(@"spicy: %ld %@ %@", (long)st, sid, err ?: RLDig(json, @[ @"Body", @"source" ]) ?: @"");
	if ((st == 401 || st == 403) && err) RLSet(@"spicyRefused", err);
	return st == 200 ? d : nil;
}

static NSMutableArray<RLSyl *> *RLSpicySyls(NSArray *syls, BOOL romanize) {
	NSMutableArray *out = [NSMutableArray array];
	for (NSDictionary *s in syls) {
		if (!RLAs(s, NSDictionary.class)) continue;
		NSString *roman = RLAs(s[@"TransliteratedText"], NSString.class), *text = romanize && roman.length ? roman : RLAs(s[@"Text"], NSString.class);
		if (!text.length) continue;
		if (![RLAs(s[@"IsPartOfWord"], NSNumber.class) boolValue]) text = [text stringByAppendingString:@" "];
		[out addObject:RLMakeSyl(text, RLNumOf(s[@"StartTime"]), RLNumOf(s[@"EndTime"]))];
	}
	return out;
}

static NSAttributedString *RLSpicyCredit(NSDictionary *body) {
	NSMutableAttributedString *out = [[NSMutableAttributedString alloc] initWithString:RLL(@"Lyrics from Spicy Lyrics", @"가사 제공: Spicy Lyrics")];
	if (![body[@"source"] isEqual:@"spicy_lyrics"]) return out;
	NSArray *who = @[ @[ @"Uploader", RLL(@" · uploaded by ", @" · 업로드 ") ], @[ @"Maker", RLL(@", made by ", @", 제작 ") ] ];
	for (NSArray *w in who) {
		NSDictionary *c = RLAs(RLDig(body, @[ @"UploadAttribution", w[0] ]), NSDictionary.class);
		NSString *name = RLAs(c[@"username"], NSString.class);
		if (!name.length) continue;
		[out appendAttributedString:[[NSAttributedString alloc] initWithString:w[1]]];
		NSURL *url = [NSURL URLWithString:RLAs(c[@"url"], NSString.class) ?: @""];
		[out appendAttributedString:[[NSAttributedString alloc] initWithString:name attributes:[url.scheme hasPrefix:@"http"] ? @{ NSLinkAttributeName: url } : @{}]];
	}
	return out;
}

NSArray<RLLine *> *RLParseSpicy(NSData *d, BOOL romanize, NSAttributedString **credit) {
	NSDictionary *body = RLAs(RLDig(RLJSON(d), @[ @"Body" ]), NSDictionary.class);
	NSString *type = RLAs(body[@"Type"], NSString.class);
	NSMutableArray *lines = [NSMutableArray array];
	for (NSDictionary *c in RLAs(body[@"Content"], NSArray.class)) {
		if (!RLAs(c, NSDictionary.class)) continue;
		BOOL right = [RLAs(c[@"OppositeAligned"], NSNumber.class) boolValue];
		RLLine *line;
		if ([type isEqualToString:@"Syllable"]) {
			NSDictionary *lead = RLAs(c[@"Lead"], NSDictionary.class);
			NSArray *syls = RLAs(lead[@"Syllables"], NSArray.class);
			NSMutableArray *main = RLSpicySyls(syls, romanize), *bg = [NSMutableArray array];
			for (NSDictionary *b in RLAs(c[@"Background"], NSArray.class)) [bg addObjectsFromArray:RLSpicySyls(RLAs(RLAs(b, NSDictionary.class)[@"Syllables"], NSArray.class), romanize)];
			RLSyl *first = main.firstObject ?: bg.firstObject;
			double start = lead[@"StartTime"] ? RLNumOf(lead[@"StartTime"]) : first.start;
			line = RLMakeLine(start, RLNumOf(lead[@"EndTime"]), main, bg, [[RLSpicySyls(syls, NO) valueForKey:@"text"] componentsJoinedByString:@""], right);
		} else if ([type isEqualToString:@"Line"]) {
			NSString *text = RLAs(c[@"Text"], NSString.class), *roman = RLAs(c[@"TransliteratedText"], NSString.class);
			double start = RLNumOf(c[@"StartTime"]);
			line = RLMakeLine(start, RLNumOf(c[@"EndTime"]), [RLWords(romanize && roman.length ? roman : text ?: @"", start) mutableCopy], [NSMutableArray array], text, right);
		}
		if (line) [lines addObject:line];
	}
	if (lines.count) *credit = RLSpicyCredit(body);
	return lines;
}
