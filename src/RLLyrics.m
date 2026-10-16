#import "RL.h"
#import <os/log.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>

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
	if (!data) return nil;
	NSDictionary *agents = RLAs(RLAs(json[@"metadata"], NSDictionary.class)[@"agents"], NSDictionary.class);
	NSMutableArray *singers = [NSMutableArray array];
	NSMutableDictionary *types = [NSMutableDictionary dictionary];
	for (NSDictionary *l in data) [singers addObject:RLAs(RLAs(RLAs(l, NSDictionary.class)[@"element"], NSDictionary.class)[@"singer"], NSString.class) ?: NSNull.null];
	for (NSString *sid in agents) {
		NSString *type = RLAs(RLAs(agents[sid], NSDictionary.class)[@"type"], NSString.class);
		if (type) types[sid] = type;
	}
	NSArray *sides = RLSides(singers, types);
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
		id tr = l[@"translation"];
		NSString *trText = RLAs(RLAs(tr, NSDictionary.class)[@"text"], NSString.class) ?: RLAs(tr, NSString.class);
		if (trText.length && ![RLLineKey(trText) isEqualToString:line.key])
			line.tr = RLWords(RLCollapse(trText), line.start);
		[lines addObject:line];
	}];
	if ([json[@"type"] isEqual:@"Word"] && [RLAs(json[@"_synthesized"], NSNumber.class) boolValue]) objc_setAssociatedObject(lines, @selector(RLIsAI:), @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return lines;
}

BOOL RLIsAI(NSArray<RLLine *> *lines) { return lines && [objc_getAssociatedObject(lines, @selector(RLIsAI:)) boolValue]; }

#pragma mark - Network

NSInteger RLGet(NSString *url, NSDictionary *headers, NSTimeInterval timeout, NSData **out) {
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:timeout];
	[headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { [req setValue:v forHTTPHeaderField:k]; }];
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

static NSData *RLRadiantGet(NSString *title, NSString *artist, NSString *isrc, double duration, BOOL romanize, BOOL synth, BOOL flush, BOOL *answered) {
	NSDictionary *auth = @{ @"P-Access-Token-Id": @"58hy4s86", @"P-Access-Token": @"xjehy2lfg5h5mjwotoxrcqugam" };
	NSString *cleanTitle = RLReplace(RLReplace(title, @"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]"), @"\\s+-\\s+.*$");
	NSString *firstArtist = RLReplace(artist, @"\\s*(,|&|\\sfeat\\.?\\s|\\sft\\.?\\s|\\swith\\s).*$");
	NSOrderedSet *cands = [NSOrderedSet orderedSetWithArray:@[ @[title, artist], @[cleanTitle, artist], @[cleanTitle, firstArtist] ]];
	*answered = NO;
	for (NSArray *c in cands) {
		if (![c[0] length] || ![c[1] length]) continue;
		NSString *qs = [NSString stringWithFormat:@"?title=%@&artist=%@%@%@%@%@&platform=rl", RLEnc(c[0]), RLEnc(c[1]),
		                isrc.length ? [@"&isrc=" stringByAppendingString:RLEnc(isrc)] : @"",
		                romanize ? @"&romanize=true" : @"", synth ? @"&synthesize=true" : @"",
		                flush && c == cands.firstObject ? @"&flush=true" : @""];
		BOOL notFound = NO;
		for (NSString *base in @[ @"https://api.atomix.one/rl-api", @"https://rl-api.kineticsand.net/lyrics" ]) {
			NSData *d;
			NSInteger st = RLGet([base stringByAppendingString:qs], [base containsString:@"atomix"] ? auth : nil, 12, &d);
			RLLog(@"%ld %@ — %@ (%@)", (long)st, c[0], c[1], base);
			if (st == 404) { notFound = YES; break; }
			if (st != 200) continue;
			NSDictionary *json = d ? RLAs([NSJSONSerialization JSONObjectWithData:d options:0 error:nil], NSDictionary.class) : nil;
			NSString *note = RLAs(json[@"_flush"], NSString.class);
			if (note.length) RLLog(@"flush: %@", note);
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
	BOOL word = NO;
	for (RLLine *l in lines)
		for (RLSyl *s in l.main)
			if (s.end - s.start > 0.001) word = YES;
	return (word ? (RLIsAI(lines) ? 1 : 2) : 0) * 2 + [source isEqualToString:@"radiant"];
}

@interface RLJob : NSObject
@property (nonatomic) NSMutableArray *dones;
@property (nonatomic) NSArray<RLLine *> *lines;
@property (nonatomic, copy) NSString *source;
@property (nonatomic) NSData *payload;
@property (nonatomic) NSInteger score;
@end
@implementation RLJob
@end

// Every source is asked at once; the first answer shows and a better one (Radiant, or word timing over
// line timing) replaces it, so done can run more than once.
void RLFetch(NSString *title, NSString *artist, NSString *isrc, double duration, BOOL flush, void (^done)(NSArray<RLLine *> *lines)) {
	static dispatch_queue_t queue;
	static NSMutableDictionary<NSString *, RLJob *> *jobs;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		queue = dispatch_queue_create("rl.fetch", DISPATCH_QUEUE_SERIAL);
		gLyricsCache = [NSCache new];
		jobs = [NSMutableDictionary dictionary];
	});
	BOOL romanize = RLBool(@"romanize", NO), synth = RLBool(@"synth", NO);
	NSString *key = [NSString stringWithFormat:@"%@\n%@\n%d%d", title, artist, romanize, synth];

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
		if (hit) {
			[gLyricsCache setObject:hit forKey:key];
			dispatch_async(dispatch_get_main_queue(), ^{ done(hit == NSNull.null ? nil : hit); });
			return;
		}
		if (flush) RLDiskWrite(base, @"radiant", nil);
		RLJob *j = [RLJob new];
		j.dones = [NSMutableArray arrayWithObject:done];
		jobs[key] = j;

		void (^offer)(NSString *, NSData *) = ^(NSString *source, NSData *d) {
			NSArray *lines = RLParseAs(source, d, romanize);
			if (!lines) return;
			dispatch_async(queue, ^{
				NSInteger score = RLScore(lines, source);
				if (j.lines && score <= j.score) return;
				RLLog(@"%@: %lu lines (score %ld)%@", source, (unsigned long)lines.count, (long)score, j.lines ? [@" replacing " stringByAppendingString:j.source] : @"");
				j.lines = lines;
				j.source = source;
				j.payload = d;
				j.score = score;
				for (void (^f)(NSArray *) in j.dones) dispatch_async(dispatch_get_main_queue(), ^{ f(lines); });
			});
		};
		__block BOOL answered = NO;
		dispatch_group_t group = dispatch_group_create();
		dispatch_queue_t net = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
		dispatch_group_async(group, net, ^{ BOOL a; offer(@"radiant", RLRadiantGet(title, artist, isrc, duration, romanize, synth, flush, &a)); answered = a; });
		dispatch_group_async(group, net, ^{ offer(@"unison", RLUnisonGet(title, artist, duration)); });
		dispatch_group_async(group, net, ^{ offer(@"binilyrics", RLBiniGet(title, artist, isrc, duration)); });
		dispatch_group_async(group, net, ^{
			NSData *mxm = RLMxmGet(title, artist, isrc, duration);
			offer(@"spicy", RLSpicyGet(mxm));
			offer(@"musixmatch", mxm);
		});
		// cached only when Radiant itself answered, so a Radiant outage doesn't pin a fallback forever
		dispatch_group_notify(group, queue, ^{
			[jobs removeObjectForKey:key];
			if (answered) {
				[gLyricsCache setObject:j.lines ?: NSNull.null forKey:key];
				if (j.lines) RLDiskWrite(base, j.source, j.payload);
			}
			RLLog(@"lyrics settled: %@", j.source ?: @"none");
			if (!j.lines)
				for (void (^f)(NSArray *) in j.dones) dispatch_async(dispatch_get_main_queue(), ^{ f(nil); });
		});
	});
}
