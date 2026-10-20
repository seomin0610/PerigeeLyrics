#import "RL.h"
#import <os/log.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <NaturalLanguage/NaturalLanguage.h>

@implementation RLSyl
@end
@implementation RLLine
@end

static id RLAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static NSMutableArray<NSString *> *gLog;

void RLLogLine(NSString *line) {
	os_log(OS_LOG_DEFAULT, "[RadiantTidal] %{public}@", line);
	static NSDateFormatter *f;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		gLog = [NSMutableArray array];
		f = [NSDateFormatter new];
		f.dateFormat = @"HH:mm:ss";
	});
	@synchronized(gLog) {
		[gLog addObject:[NSString stringWithFormat:@"%@ %@", [f stringFromDate:NSDate.date], line]];
		if (gLog.count > 60) [gLog removeObjectAtIndex:0];
	}
}

NSArray<NSString *> *RLLogLines(void) {
	if (!gLog) return @[];
	@synchronized(gLog) { return [gLog copy]; }
}

NSString *RLCollapse(NSString *s) {
	static NSRegularExpression *re;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil]; });
	return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@" "];
}

NSArray<RLSyl *> *RLWords(NSString *text, double t) {
	NSMutableArray *out = [NSMutableArray array];
	NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\S+\\s*" options:0 error:nil];
	for (NSTextCheckingResult *m in [re matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
		RLSyl *s = [RLSyl new];
		s.text = [text substringWithRange:m.range];
		s.start = s.end = t;
		[out addObject:s];
	}
	return out;
}

NSArray<NSNumber *> *RLSides(NSArray *singers, NSDictionary<NSString *, NSString *> *types) {
	NSMutableDictionary<NSString *, NSNumber *> *map = [NSMutableDictionary dictionary];
	NSInteger persons = 0;
	for (NSString *sid in singers) {
		if (!RLAs(sid, NSString.class) || map[sid]) continue;
		NSString *type = types[sid];
		if (!type) type = [sid isEqualToString:@"v1000"] ? @"group" : [sid isEqualToString:@"v2000"] ? @"other" : @"person";
		map[sid] = @(!([type isEqualToString:@"group"] || [type isEqualToString:@"other"]) && ++persons == 2);
	}
	NSMutableArray *sides = [NSMutableArray array];
	NSInteger right = 0, total = 0;
	for (NSString *sid in singers) {
		BOOL has = RLAs(sid, NSString.class) != nil, r = has && [map[sid] boolValue];
		if (has) total++;
		if (r) right++;
		[sides addObject:@(r)];
	}
	if (total && llround(right * 100.0 / total) >= 85)
		for (NSUInteger i = 0; i < sides.count; i++) sides[i] = @(![sides[i] boolValue]);
	return sides;
}

// rl-api also "translates" a line already in the target language (Korean into reworded Korean), so such a
// line gets none. Mixed lines count as the language NaturalLanguage finds most of.
BOOL RLInLang(RLLine *l, NSString *lang) {
	if (!l.lang) {
		NLLanguageRecognizer *r = [NLLanguageRecognizer new];
		[r processString:[[l.main valueForKey:@"text"] componentsJoinedByString:@""]];
		l.lang = r.dominantLanguage ?: @"";
	}
	return [l.lang hasPrefix:lang];
}

NSString *RLLineKey(NSString *s) {
	return [[s.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
}

RLSyl *RLMakeSyl(NSString *text, double start, double end) {
	RLSyl *s = [RLSyl new];
	s.text = text;
	s.start = start;
	s.end = MAX(start, end);
	return s;
}

RLLine *RLMakeLine(double start, double end, NSMutableArray<RLSyl *> *main, NSMutableArray<RLSyl *> *bg, NSString *keyText, BOOL right) {
	if (!main.count) { [main addObjectsFromArray:bg]; [bg removeAllObjects]; }
	for (RLSyl *b in bg.copy) {
		b.text = [[b.text stringByReplacingOccurrencesOfString:@"(" withString:@""] stringByReplacingOccurrencesOfString:@")" withString:@""];
		if (![b.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length) [bg removeObject:b];
	}
	NSString *joined = [[main valueForKey:@"text"] componentsJoinedByString:@""];
	if (![joined stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return nil;
	RLLine *line = [RLLine new];
	line.start = start;
	line.end = end;
	for (RLSyl *x in [main arrayByAddingObjectsFromArray:bg]) line.end = MAX(line.end, x.end);
	line.main = main;
	line.bg = bg;
	line.key = RLLineKey(keyText.length ? keyText : joined);
	line.right = right;
	return line;
}

NSArray<RLLine *> *RLParse(NSDictionary *json, BOOL romanize) {
	NSArray *data = RLAs(json[@"data"], NSArray.class);
	if (!data || ![@[ @"Word", @"Line" ] containsObject:json[@"type"] ?: @"Line"]) return nil;
	NSDictionary *agents = RLAs(RLAs(json[@"metadata"], NSDictionary.class)[@"agents"], NSDictionary.class);
	NSMutableArray *singers = [NSMutableArray array];
	NSMutableDictionary *types = [NSMutableDictionary dictionary];
	for (NSDictionary *l in data) [singers addObject:RLAs(RLAs(RLAs(l, NSDictionary.class)[@"element"], NSDictionary.class)[@"singer"], NSString.class) ?: NSNull.null];
	for (NSString *sid in agents) {
		NSString *type = RLAs(RLAs(agents[sid], NSDictionary.class)[@"type"], NSString.class);
		if (type) types[sid] = type;
	}
	NSArray *sides = RLSides(singers, types);
	BOOL translated = [RLAs(json[@"_translated"], NSNumber.class) boolValue];
	NSMutableArray *lines = [NSMutableArray array];
	[data enumerateObjectsUsingBlock:^(NSDictionary *l, NSUInteger i, BOOL *stop) {
		if (!RLAs(l, NSDictionary.class)) return;
		double start = [RLAs(l[@"startTime"], NSNumber.class) doubleValue];
		NSNumber *end = RLAs(l[@"endTime"], NSNumber.class);
		NSMutableArray *main = [NSMutableArray array], *bg = [NSMutableArray array];
		for (NSDictionary *s in RLAs(l[@"syllabus"], NSArray.class)) {
			if (!RLAs(s, NSDictionary.class)) continue;
			NSString *text = RLAs(s[@"text"], NSString.class);
			NSString *roman = RLAs(s[@"romanized"], NSString.class);
			if (romanize && roman.length) text = RLCollapse(roman);
			if (!text.length) continue;
			double t = [RLAs(s[@"time"], NSNumber.class) doubleValue] / 1000.0;
			[[RLAs(s[@"isBackground"], NSNumber.class) boolValue] ? bg : main addObject:RLMakeSyl(text, t, t + [RLAs(s[@"duration"], NSNumber.class) doubleValue] / 1000.0)];
		}
		if (!main.count && !bg.count) {
			NSString *text = RLAs(l[@"text"], NSString.class);
			NSString *roman = RLAs(l[@"romanized"], NSString.class);
			if (romanize && roman.length) text = RLCollapse(roman);
			if (text) [main addObjectsFromArray:RLWords(text, start)];
		}
		RLLine *line = RLMakeLine(start, end ? end.doubleValue : start + [RLAs(l[@"duration"], NSNumber.class) doubleValue], main, bg, RLAs(l[@"text"], NSString.class), [sides[i] boolValue]);
		if (!line) return;
		NSString *trText = translated ? RLAs(l[@"translation"], NSString.class) : nil;
		if (trText.length && ![RLLineKey(trText) isEqualToString:line.key]) {
			// translationSyllabus words carry their own timing and are not in time order
			NSMutableArray *words = [NSMutableArray array];
			for (NSDictionary *s in RLAs(l[@"translationSyllabus"], NSArray.class)) {
				NSString *text = RLAs(RLAs(s, NSDictionary.class)[@"text"], NSString.class);
				double t = [RLAs(s[@"time"], NSNumber.class) doubleValue] / 1000.0;
				if (text.length) [words addObject:RLMakeSyl(text, t, t + [RLAs(s[@"duration"], NSNumber.class) doubleValue] / 1000.0)];
			}
			RLSyl *one = words.count == 1 ? words[0] : nil;
			if (one && line.end - line.start > one.end - one.start) one.start = line.start, one.end = line.end;
			line.tr = words.count ? words : RLWords(RLCollapse(trText), line.start);
		}
		[lines addObject:line];
	}];
	if ([json[@"type"] isEqual:@"Word"] && [RLAs(json[@"_synthesized"], NSNumber.class) boolValue])
		objc_setAssociatedObject(lines, @selector(RLAIType:), RLAs(json[@"_synthesisType"], NSString.class) ?: @"Synthesize", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return lines;
}

NSString *RLAIType(NSArray<RLLine *> *lines) { return lines ? objc_getAssociatedObject(lines, @selector(RLAIType:)) : nil; }
BOOL RLHasTr(NSArray<RLLine *> *lines, NSString *lang) {
	NSString *k = [@"rl." stringByAppendingString:lang];
	for (RLLine *l in lines)
		if (l.mx[k]) return YES;
	return NO;
}

#pragma mark - Network

static NSInteger RLSend(NSString *url, NSDictionary *headers, NSData *post, NSTimeInterval timeout, NSData **out) {
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
	[headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [req setValue:v forHTTPHeaderField:k]; }];
	if (post) req.HTTPMethod = @"POST", req.HTTPBody = post;
	__block NSInteger status = 0;
	__block NSData *body;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	[[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
		status = e ? 0 : ((NSHTTPURLResponse *)r).statusCode;
		body = d;
		dispatch_semaphore_signal(sem);
	}] resume];
	dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
	if (out) *out = body;
	return status;
}

NSInteger RLGet(NSString *url, NSDictionary *headers, NSTimeInterval timeout, NSData **out) { return RLSend(url, headers, nil, timeout, out); }

NSString *RLEnc(NSString *s) {
	static NSCharacterSet *ok;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ ok = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"]; });
	return [s stringByAddingPercentEncodingWithAllowedCharacters:ok] ?: @"";
}

static NSString *RLReplace(NSString *s, NSString *pattern) {
	NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
	s = [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
	return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

// Same endpoints/token as radiant-lyrics-luna api.ts (the token is public by design); its x-client-ip
// (from api.ipify.org) is left out, the API answers without it.
static NSCache *gLyricsCache;

void RLClearCache(void) { [gLyricsCache removeAllObjects]; }

static const NSUInteger kRLDiskMax = 1000;

static void RLPruneDisk(NSString *dir) {
	NSFileManager *fm = NSFileManager.defaultManager;
	NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:dir] includingPropertiesForKeys:@[ NSURLContentModificationDateKey ] options:0 error:nil];
	if (files.count <= kRLDiskMax) return;
	NSDate *(^date)(NSURL *) = ^NSDate *(NSURL *u) { NSDate *d; [u getResourceValue:&d forKey:NSURLContentModificationDateKey error:nil]; return d ?: NSDate.distantPast; };
	files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [date(b) compare:date(a)]; }];
	for (NSURL *u in [files subarrayWithRange:NSMakeRange(kRLDiskMax, files.count - kRLDiskMax)]) [fm removeItemAtURL:u error:nil];
}

static NSString *RLDiskPath(NSString *key) {
	static NSString *dir;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"RadiantTidal"];
		[NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
		RLPruneDisk(dir);
	});
	NSData *k = [key dataUsingEncoding:NSUTF8StringEncoding];
	unsigned char h[CC_SHA256_DIGEST_LENGTH];
	CC_SHA256(k.bytes, (CC_LONG)k.length, h);
	NSMutableString *name = [NSMutableString string];
	for (int i = 0; i < 16; i++) [name appendFormat:@"%02x", h[i]];
	return [dir stringByAppendingPathComponent:name];
}

#define kRLSources (@[ @"radiant", @"spicy", @"unison", @"binilyrics", @"musixmatch" ])

static NSString *RLDiskFile(NSString *base, NSString *source) {
	return [base stringByAppendingPathExtension:[source isEqualToString:@"radiant"] ? @"json" : source];
}

static NSArray<RLLine *> *RLParseAs(NSString *source, NSData *d, BOOL romanize) {
	if (!d.length) return nil;
	NSAttributedString *credit;
	NSArray *lines = [source isEqualToString:@"radiant"] ? RLParse(RLAs([NSJSONSerialization JSONObjectWithData:d options:0 error:nil], NSDictionary.class), romanize)
		: [source isEqualToString:@"musixmatch"] ? RLParseMxm(d)
		: [source isEqualToString:@"spicy"] ? RLParseSpicy(d, romanize, &credit)
		: RLParseTTML(d, romanize);
	if (!lines.count) return nil;
	NSString *name = @{ @"radiant": @"Radiant Lyrics", @"spicy": @"Spicy Lyrics", @"unison": @"Unison", @"binilyrics": @"BiniLyrics", @"musixmatch": @"Musixmatch" }[source];
	objc_setAssociatedObject(lines, @selector(RLSourceName:), name, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	objc_setAssociatedObject(lines, @selector(RLCredit:), credit, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	if ([source isEqualToString:@"radiant"]) objc_setAssociatedObject(lines, @selector(RLSyllaInput:), d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return lines;
}

NSString *RLSourceName(NSArray<RLLine *> *lines) { return lines ? objc_getAssociatedObject(lines, @selector(RLSourceName:)) : nil; }
NSAttributedString *RLCredit(NSArray<RLLine *> *lines) { return lines ? objc_getAssociatedObject(lines, @selector(RLCredit:)) : nil; }

static NSArray<RLLine *> *RLFromDisk(NSString *base, BOOL romanize) {
	for (NSString *source in kRLSources) {
		NSString *path = RLDiskFile(base, source);
		NSArray *lines = RLParseAs(source, [NSData dataWithContentsOfFile:path], romanize);
		if (!lines) continue;
		[NSFileManager.defaultManager setAttributes:@{ NSFileModificationDate: NSDate.date } ofItemAtPath:path error:nil];
		RLLog(@"%lu lines from disk cache (%@)", (unsigned long)lines.count, source);
		return lines;
	}
	return nil;
}

static void RLDiskWrite(NSString *base, NSString *source, NSData *d) {
	for (NSString *s in kRLSources) [NSFileManager.defaultManager removeItemAtPath:RLDiskFile(base, s) error:nil];
	[d writeToFile:RLDiskFile(base, source) atomically:YES];
}

double RLClock(NSString *s) {
	double t = 0;
	for (NSString *p in [s componentsSeparatedByString:@":"]) t = t * 60 + p.doubleValue;
	return t;
}

// A name in another script (米津玄師 for Kenshi Yonezu) can't be compared, so it passes.
static BOOL RLSameName(NSString *got, NSString *want) {
	NSString *a = RLLineKey(got ?: @""), *b = RLLineKey(want ?: @"");
	if (!a.length || !b.length || [a containsString:b] || [b containsString:a]) return YES;
	return [a canBeConvertedToEncoding:NSASCIIStringEncoding] != [b canBeConvertedToEncoding:NSASCIIStringEncoding];
}

static BOOL RLSameSong(NSDictionary *json, NSString *title, NSString *artist, double duration) {
	NSDictionary *meta = RLAs(json[@"metadata"], NSDictionary.class);
	NSNumber *ms = RLAs(meta[@"durationMs"], NSNumber.class);
	double got = ms ? ms.doubleValue / 1000 : RLClock(RLAs(meta[@"totalDuration"], NSString.class));
	BOOL same = !(duration > 0 && got > 0 && fabs(got - duration) > MAX(20, duration * 0.12))
		&& RLSameName(RLAs(meta[@"title"], NSString.class), title) && RLSameName(RLAs(meta[@"artist"], NSString.class), artist);
	if (!same) RLLog(@"rejected: Radiant sent %@ — %@ (%.0fs) for %@ — %@ (%.0fs)", meta[@"title"], meta[@"artist"], got, title, artist, duration);
	return same;
}

#define kRLAuth (@{ @"P-Access-Token-Id": @"58hy4s86", @"P-Access-Token": @"xjehy2lfg5h5mjwotoxrcqugam" })

// rl-api translates into these itself (?language=), word-timed; other languages are left to RLTranslate.
static NSString *RLTrAPI(NSString *lang) {
	return @{ @"en": @"english", @"es": @"spanish", @"fr": @"french", @"de": @"german", @"pt": @"portuguese", @"it": @"italian", @"ru": @"russian", @"ja": @"japanese", @"ko": @"korean", @"zh": @"chinese" }[lang];
}

// "0" is where the old synth flag was, so lyrics cached before RL 2.0 still hit
static NSString *RLFetchKey(NSString *title, NSString *artist) {
	return [NSString stringWithFormat:@"%@\n%@\n%d0%@", title, artist, RLBool(@"romanize", NO), RLBool(@"allowAI", YES) ? @"" : @"n"];
}

static NSData *RLRadiantGet(NSString *title, NSString *artist, NSString *isrc, double duration, BOOL romanize, NSString *tr, BOOL flush, BOOL *answered) {
	NSDictionary *auth = kRLAuth;
	NSString *cleanTitle = RLReplace(RLReplace(title, @"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]"), @"\\s+-\\s+.*$");
	NSString *firstArtist = RLReplace(artist, @"\\s*(,|&|\\sfeat\\.?\\s|\\sft\\.?\\s|\\swith\\s).*$");
	NSOrderedSet *cands = [NSOrderedSet orderedSetWithArray:@[ @[title, artist], @[cleanTitle, artist], @[cleanTitle, firstArtist] ]];
	*answered = NO;
	for (NSArray *c in cands) {
		if (![c[0] length] || ![c[1] length]) continue;
		NSString *qs = [NSString stringWithFormat:@"?title=%@&artist=%@%@%@%@&ai-preference=%@%@&platform=rl", RLEnc(c[0]), RLEnc(c[1]),
		                isrc.length ? [@"&isrc=" stringByAppendingString:RLEnc(isrc)] : @"",
		                romanize ? @"&romanize=true" : @"", flush && c == cands.firstObject ? @"&flush=true" : @"",
		                RLBool(@"allowAI", YES) ? @"true" : @"false", tr ? [@"&translate=true&language=" stringByAppendingString:tr] : @""];
		BOOL notFound = NO;
		for (NSString *base in @[ @"https://api.atomix.one/rl-api", @"https://rl-api.kineticsand.net/lyrics" ]) {
			NSData *d;
			NSInteger st = RLGet([base stringByAppendingString:qs], [base containsString:@"atomix"] ? auth : nil, 30, &d);
			RLLog(@"%ld %@ — %@ (%@)", (long)st, c[0], c[1], base);
			if (st == 404) { notFound = YES; break; }
			if (st != 200) continue;
			NSDictionary *json = d ? RLAs([NSJSONSerialization JSONObjectWithData:d options:0 error:nil], NSDictionary.class) : nil;
			NSString *note = RLAs(json[@"_flush"], NSString.class);
			if (note.length) RLLog(@"flush: %@", note);
			if ([RLAs(json[@"_translated"], NSNumber.class) isEqual:@NO]) RLLog(@"translation failed: %@", json[@"_translationError"]);
			if (RLSameSong(json, title, artist, duration) && RLParse(json, romanize).count) { *answered = YES; return d; }
			notFound = YES;
			break;
		}
		if (!notFound) return nil;
	}
	*answered = YES;
	return nil;
}

static NSInteger RLScore(NSArray<RLLine *> *lines, NSString *source) {
	if ([[lines valueForKeyPath:@"@max.start"] doubleValue] <= 0) return -1;
	BOOL word = NO;
	for (RLLine *l in lines)
		for (RLSyl *s in l.main)
			if (s.end - s.start > 0.001) word = YES;
	return (word ? (RLAIType(lines) ? 1 : 2) : 0) * 2 + [source isEqualToString:@"radiant"];
}

static NSSet<NSString *> *RLGrams(NSArray<RLLine *> *lines) {
	NSMutableSet *g = [NSMutableSet set];
	for (RLLine *l in lines)
		for (NSUInteger i = 0; i + 3 <= l.key.length; i++) [g addObject:[l.key substringWithRange:NSMakeRange(i, 3)]];
	return g;
}

// Measured on 9 songs: the same song from two sources shares >= 93% of its trigrams, two different songs <= 39%.
static BOOL RLSameWords(NSSet *a, NSSet *b) {
	if (!a.count || !b.count) return YES;
	NSMutableSet *both = [a mutableCopy];
	[both intersectSet:b];
	return both.count >= 0.6 * MIN(a.count, b.count);
}

@interface RLJob : NSObject
@property (nonatomic) NSMutableArray *dones;
@property (nonatomic) NSArray<RLLine *> *lines;
@property (nonatomic, copy) NSString *source;
@property (nonatomic) NSData *payload;
@property (nonatomic) NSInteger score;
@property (nonatomic) NSMutableArray<RLJob *> *seen;
@property (nonatomic) NSSet<NSString *> *grams;
@end
@implementation RLJob
@end

// rl-api's translations are a second request, so the lyrics never wait on them. Merged line by line, which only
// lines up when the lyrics on screen are Radiant's own.
void RLRadiantTranslate(NSArray<RLLine *> *lines, NSString *title, NSString *artist, NSString *lang, void (^done)(BOOL found)) {
	NSString *api = RLTrAPI(lang);
	if (!api || ![RLSourceName(lines) isEqualToString:@"Radiant Lyrics"]) { done(NO); return; }
	if (RLHasTr(lines, lang)) { done(YES); return; }
	BOOL romanize = RLBool(@"romanize", NO);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		BOOL answered;
		NSData *d = RLRadiantGet(title, artist, nil, 0, romanize, api, NO, &answered);
		NSArray<RLLine *> *got = d ? RLParse(RLAs([NSJSONSerialization JSONObjectWithData:d options:0 error:nil], NSDictionary.class), romanize) : nil;
		dispatch_async(dispatch_get_main_queue(), ^{
			NSString *k = [@"rl." stringByAppendingString:lang];
			for (NSUInteger i = 0; got.count == lines.count && i < got.count; i++) {
				if (![got[i].key isEqualToString:lines[i].key]) continue;
				if (!lines[i].mx) lines[i].mx = [NSMutableDictionary dictionary];
				lines[i].mx[k] = got[i].tr ?: @[];
			}
			RLLog(@"rl-api %@ translation: %@", lang, RLHasTr(lines, lang) ? @"merged" : got ? @"lines don't line up" : @"none");
			done(RLHasTr(lines, lang));
		});
	});
}

#pragma mark - Sylla

// Sylla (rl-api's AI) can drop the space after a word; put it back from the line text, as rl-mobile does.
static void RLRespace(NSDictionary *lyrics, NSArray *summary) {
	NSCharacterSet *alnum = NSCharacterSet.alphanumericCharacterSet, *space = NSCharacterSet.whitespaceCharacterSet;
	[RLAs(lyrics[@"data"], NSArray.class) enumerateObjectsUsingBlock:^(NSDictionary *line, NSUInteger li, BOOL *stop) {
		NSArray<NSMutableDictionary *> *syl = RLAs(RLAs(line, NSDictionary.class)[@"syllabus"], NSArray.class);
		for (NSUInteger i = 0; i + 1 < syl.count; i++)
			if (![syl[i] isKindOfClass:NSMutableDictionary.class] || [RLAs(syl[i][@"text"], NSString.class) hasSuffix:@" "]) return;
		NSString *ref = RLAs(line[@"text"], NSString.class);
		for (NSDictionary *l in summary)
			if (![ref containsString:@" "] && [RLAs(l, NSDictionary.class)[@"index"] isEqual:@(li)]) ref = RLAs(l[@"text"], NSString.class);
		if (syl.count < 2 || ![ref containsString:@" "]) return;
		ref = ref.lowercaseString;
		NSMutableIndexSet *ends = [NSMutableIndexSet indexSet];
		NSUInteger pos = 0;
		for (NSUInteger i = 0; i < syl.count; i++) {
			NSString *st = [RLAs(syl[i][@"text"], NSString.class) lowercaseString];
			for (NSUInteger k = 0; k < st.length; k++) {
				unichar c = [st characterAtIndex:k];
				if (![alnum characterIsMember:c]) continue;
				while (pos < ref.length && ![alnum characterIsMember:[ref characterAtIndex:pos]]) pos++;
				if (pos >= ref.length || [ref characterAtIndex:pos] != c) return;
				pos++;
			}
			for (NSUInteger k = pos; k < ref.length; k++) {
				unichar c = [ref characterAtIndex:k];
				if ([space characterIsMember:c]) { [ends addIndex:i]; break; }
				if ([alnum characterIsMember:c]) break;
			}
		}
		[ends enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *st) {
			NSString *t = RLAs(syl[i][@"text"], NSString.class);
			if (t && i + 1 < syl.count) syl[i][@"text"] = [t stringByAppendingString:@" "];
		}];
	}];
}

// rl-api's own shape: the Radiant response as it came (original script, not romanized), else built from the lines.
static NSDictionary *RLSyllaInput(NSArray<RLLine *> *lines, NSString *title) {
	NSData *raw = objc_getAssociatedObject(lines, @selector(RLSyllaInput:));
	NSDictionary *src = raw ? RLAs([NSJSONSerialization JSONObjectWithData:raw options:0 error:nil], NSDictionary.class) : nil;
	if (RLAs(src[@"data"], NSArray.class)) return @{ @"type": src[@"type"] ?: @"Line", @"data": src[@"data"], @"metadata": src[@"metadata"] ?: @{} };
	NSMutableArray *data = [NSMutableArray array];
	for (RLLine *l in lines) {
		NSString *text = [[[l.main valueForKey:@"text"] componentsJoinedByString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		[data addObject:@{ @"text": text, @"startTime": @(l.start), @"endTime": @(l.end), @"duration": @(l.end - l.start),
		                   @"element": @{ @"key": [NSString stringWithFormat:@"L%lu", (unsigned long)data.count + 1], @"singer": @"v1" } }];
	}
	return @{ @"type": @"Line", @"data": data, @"metadata": @{ @"title": title, @"language": @"", @"totalDuration": [NSString stringWithFormat:@"%.3f", lines.lastObject.end] } };
}

// sylla-align retimes the given lyrics to the audio, sylla-gen (no lyrics) transcribes them; both answer rl-api's
// Word shape, already romanized like the request. Same calls as radiant-lyrics-luna api.ts.
static NSData *RLSyllaPost(NSDictionary *lyrics, NSArray<NSString *> *ref, NSString *title, NSString *artist) {
	NSString *label = lyrics ? @"sylla-align" : @"sylla-gen";
	NSString *url = [NSString stringWithFormat:@"https://api.atomix.one/%@?romanize=%@&translate=false&language=english&ai-preference=true", label, RLBool(@"romanize", NO) ? @"true" : @"false"];
	NSMutableDictionary *body = [@{ @"tidal_id": ref[1], @"isrc": ref[0], @"title": title, @"artist": artist } mutableCopy];
	body[@"lyrics"] = lyrics;
	NSMutableDictionary *headers = [kRLAuth mutableCopy];
	headers[@"Content-Type"] = @"application/json";
	NSData *d;
	NSInteger st = RLSend(url, headers, [NSJSONSerialization dataWithJSONObject:body options:0 error:nil], 180, &d);
	NSDictionary *json = d ? RLAs([NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil], NSDictionary.class) : nil;
	NSMutableDictionary *out = RLAs(json[@"lyrics"], NSMutableDictionary.class);
	NSString *why = st < 200 || st > 299 ? [NSString stringWithFormat:@"%ld %@", (long)st, json[@"message"] ?: json[@"verdict"] ?: json[@"detail"] ?: @""]
		: [json[@"verdict"] isEqual:@"lyrics_do_not_match_audio"] ? @"lyrics don't match this version of the song"
		: ![out[@"type"] isEqual:@"Word"] || !RLAs(out[@"data"], NSArray.class) ? @"no usable lyrics" : nil;
	if (why) { RLLog(@"%@ for %@ — %@: %@", label, title, artist, why); return nil; }
	out[@"_synthesized"] = @YES;
	out[@"_synthesisType"] = lyrics ? @"Align" : @"Generate";
	out[@"_confidence"] = json[@"confidence"] ?: @0;
	RLRespace(out, RLAs(json[@"lines"], NSArray.class));
	RLLog(@"%@ for %@ — %@: %@ %@, confidence %@", label, title, artist, json[@"model"], json[@"verdict"], json[@"confidence"]);
	return [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
}

static dispatch_queue_t gFetchQ;

void RLRetime(NSString *title, NSString *artist, double duration, NSArray<RLLine *> *lines, void (^done)(NSArray<RLLine *> *lines)) {
	NSArray *ref = RLTrackRef(title, duration);
	if (!ref) { RLLog(@"sylla: no TIDAL id for %@", title); done(nil); return; }
	NSDictionary *input = lines.count ? RLSyllaInput(lines, title) : nil;
	NSString *key = RLFetchKey(title, artist);
	BOOL romanize = RLBool(@"romanize", NO);
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSData *d = RLSyllaPost(input, ref, title, artist);
		NSArray *out = RLParseAs(@"radiant", d, romanize);
		if (out) { [gLyricsCache setObject:out forKey:key]; RLDiskWrite(RLDiskPath(key), @"radiant", d); }
		dispatch_async(dispatch_get_main_queue(), ^{ done(out); });
	});
}

// Once per TIDAL track per launch, on gFetchQ: a failure is not retried, and a second fetch of the same
// track under another title (LyricsInject's vs. now playing's) waits for the same answer.
static void RLSyllaOnce(NSArray<NSString *> *ref, NSData *(^post)(void), void (^done)(NSData *d)) {
	static NSMutableDictionary<NSString *, id> *answers;
	static NSMutableDictionary<NSString *, NSMutableArray *> *waiting;
	if (!answers) answers = [NSMutableDictionary dictionary], waiting = [NSMutableDictionary dictionary];
	NSString *tid = ref[1];
	id a = answers[tid];
	if (a) { done(a == NSNull.null ? nil : a); return; }
	if (waiting[tid]) { [waiting[tid] addObject:done]; return; }
	waiting[tid] = [NSMutableArray arrayWithObject:done];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSData *d = post();
		dispatch_async(gFetchQ, ^{
			answers[tid] = d ?: NSNull.null;
			for (void (^f)(NSData *) in waiting[tid]) f(d);
			[waiting removeObjectForKey:tid];
		});
	});
}

// Every source is asked at once; the first answer shows and a better one (Radiant, or word timing over
// line timing) replaces it, so done can run more than once. With Radiant AI on, lyrics without word timing
// then go to Sylla (or no lyrics at all: Sylla writes them), and done waits for that.
void RLFetch(NSString *title, NSString *artist, NSString *isrc, double duration, BOOL flush, void (^done)(NSArray<RLLine *> *lines)) {
	static NSMutableDictionary<NSString *, RLJob *> *jobs;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		gFetchQ = dispatch_queue_create("rl.fetch", DISPATCH_QUEUE_SERIAL);
		gLyricsCache = [NSCache new];
		jobs = [NSMutableDictionary dictionary];
	});
	dispatch_queue_t queue = gFetchQ;
	BOOL romanize = RLBool(@"romanize", NO), sylla = RLBool(@"allowAI", YES) && RLBool(@"radiantAI", NO);
	NSString *key = RLFetchKey(title, artist);

	dispatch_async(queue, ^{
		RLJob *job = jobs[key];
		if (job) {
			[job.dones addObject:done];
			NSArray *lines = job.lines;
			if (lines) dispatch_async(dispatch_get_main_queue(), ^{ done(lines); });
			return;
		}
		NSString *base = RLDiskPath(key);
		id hit = flush ? nil : [gLyricsCache objectForKey:key] ?: RLFromDisk(base, romanize);
		RLJob *j = [RLJob new];
		j.dones = [NSMutableArray arrayWithObject:done];
		jobs[key] = j;
		void (^send)(NSArray *) = ^(NSArray *lines) {
			for (void (^f)(NSArray *) in j.dones) dispatch_async(dispatch_get_main_queue(), ^{ f(lines); });
		};
		void (^finish)(void) = ^{
			[jobs removeObjectForKey:key];
			if (!j.lines) send(nil);
		};
		void (^retime)(void) = ^{
			if (!sylla || j.score >= 2) { finish(); return; }
			__block NSArray *ref;
			dispatch_sync(dispatch_get_main_queue(), ^{ ref = RLTrackRef(title, duration); });
			if (!ref) { RLLog(@"sylla: no TIDAL id for %@", title); finish(); return; }
			NSDictionary *input = j.lines ? RLSyllaInput(j.lines, title) : nil;
			RLSyllaOnce(ref, ^NSData *{ return RLSyllaPost(input, ref, title, artist); }, ^(NSData *d) {
				NSArray *lines = RLBool(@"radiantAI", NO) ? RLParseAs(@"radiant", d, romanize) : nil;
				if (lines) {
					j.lines = lines;
					j.source = @"radiant";
					j.score = RLScore(lines, @"radiant");
					[gLyricsCache setObject:lines forKey:key];
					RLDiskWrite(base, @"radiant", d);
					send(lines);
				}
				finish();
			});
		};
		if (hit) {
			[gLyricsCache setObject:hit forKey:key];
			if (hit != NSNull.null) {
				j.lines = hit;
				j.score = RLScore(hit, @"");
				send(hit);
			}
			retime();
			return;
		}
		if (flush) RLDiskWrite(base, @"radiant", nil);

		void (^offer)(NSString *, NSData *) = ^(NSString *source, NSData *d) {
			NSArray *lines = RLParseAs(source, d, romanize);
			if (!lines) return;
			dispatch_async(queue, ^{
				RLJob *c = [RLJob new];
				c.lines = lines;
				c.source = source;
				c.payload = d;
				c.score = RLScore(lines, source);
				c.grams = RLGrams(lines);
				if (!j.seen) j.seen = [NSMutableArray array];
				[j.seen addObject:c];
				// sources agreeing outrank better timing: Radiant can answer another song with the same title
				RLJob *best;
				NSInteger bestRank = NSIntegerMin, cur = NSIntegerMin, agree = 0;
				for (RLJob *x in j.seen) {
					NSInteger n = 0;
					for (RLJob *y in j.seen) n += y != x && RLSameWords(x.grams, y.grams);
					if (x.lines == j.lines) cur = n * 10 + x.score;
					if (n * 10 + x.score > bestRank) bestRank = n * 10 + x.score, best = x, agree = n;
				}
				if (j.lines && bestRank <= cur) return;
				RLLog(@"%@: %lu lines (score %ld, %ld agree)%@", best.source, (unsigned long)best.lines.count, (long)best.score, (long)agree, j.lines ? [@" replacing " stringByAppendingString:j.source] : @"");
				j.lines = best.lines;
				j.source = best.source;
				j.payload = best.payload;
				j.score = best.score;
				send(best.lines);
			});
		};
		__block BOOL answered = NO;
		dispatch_group_t group = dispatch_group_create();
		dispatch_queue_t net = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
		void (^others)(void) = ^{
			dispatch_group_async(group, net, ^{ offer(@"unison", RLUnisonGet(title, artist, duration)); });
			dispatch_group_async(group, net, ^{ offer(@"binilyrics", RLBiniGet(title, artist, isrc, duration)); });
			dispatch_group_async(group, net, ^{
				NSData *mxm = RLMxmGet(title, artist, isrc, duration);
				offer(@"spicy", RLSpicyGet(mxm));
				offer(@"musixmatch", mxm);
			});
		};
		dispatch_group_async(group, net, ^{
			BOOL a;
			offer(@"radiant", RLRadiantGet(title, artist, isrc, duration, romanize, nil, flush, &a));
			answered = a;
			if (flush && a) others();
		});
		if (!flush) others();
		// cached only when Radiant itself answered, so a Radiant outage doesn't pin a fallback forever
		dispatch_group_notify(group, queue, ^{
			if (answered) {
				[gLyricsCache setObject:j.lines ?: NSNull.null forKey:key];
				if (j.lines) RLDiskWrite(base, j.source, j.payload);
			}
			RLLog(@"lyrics settled: %@", j.source ?: @"none");
			retime();
		});
	});
}
