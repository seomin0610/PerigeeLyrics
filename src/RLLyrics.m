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
	os_log(OS_LOG_DEFAULT, "[PerigeeLyrics] %{public}@", line);
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

// A line already in the target language gets no translation. NaturalLanguage counts characters, so
// "Ling, ling 결국 알게 될 거야" came out English; a Hangul/kana/Han character weighs two letters and only the
// heavier side of a mixed line is recognized.
BOOL RLInLang(RLLine *l, NSString *lang) {
	if (!l.lang) {
		NSString *s = [[l.main valueForKey:@"text"] componentsJoinedByString:@""];
		NSMutableString *wide = [NSMutableString string], *rest = [NSMutableString string];
		NSUInteger letters = 0;
		for (NSUInteger i = 0; i < s.length; i++) {
			unichar c = [s characterAtIndex:i];
			BOOL cjk = (c >= 0x1100 && c <= 0x11FF) || (c >= 0x3040 && c <= 0x30FF) || (c >= 0x3130 && c <= 0x318F) || (c >= 0x3400 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7A3);
			if (!cjk && [NSCharacterSet.letterCharacterSet characterIsMember:c]) letters++;
			[cjk ? wide : rest appendFormat:@"%C", c];
		}
		NLLanguageRecognizer *r = [NLLanguageRecognizer new];
		[r processString:wide.length * 2 > letters ? wide : rest];
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

#define kRLSources (@[ @"spicy", @"unison", @"binilyrics", @"musixmatch" ])

static NSString *RLDiskFile(NSString *base, NSString *source) {
	return [base stringByAppendingPathExtension:source];
}

static NSArray<RLLine *> *RLParseAs(NSString *source, NSData *d, BOOL romanize) {
	if (!d.length) return nil;
	NSAttributedString *credit;
	NSArray *lines = [source isEqualToString:@"musixmatch"] ? RLParseMxm(d)
		: [source isEqualToString:@"spicy"] ? RLParseSpicy(d, romanize, &credit)
		: RLParseTTML(d, romanize);
	if (!lines.count) return nil;
	NSString *name = @{ @"spicy": @"Spicy Lyrics", @"unison": @"Unison", @"binilyrics": @"BiniLyrics", @"musixmatch": @"Musixmatch" }[source];
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
	if (d) [d writeToFile:RLDiskFile(base, source) atomically:YES];
}

double RLClock(NSString *s) {
	double t = 0;
	for (NSString *p in [s componentsSeparatedByString:@":"]) t = t * 60 + p.doubleValue;
	return t;
}

// "0" is where the old synth flag was, so lyrics cached before RL 2.0 still hit
static NSString *RLFetchKey(NSString *title, NSString *artist) {
	return [NSString stringWithFormat:@"%@\n%@\n%d0", title, artist, RLBool(@"romanize", NO)];
}

static NSInteger RLScore(NSArray<RLLine *> *lines) {
	if ([[lines valueForKeyPath:@"@max.start"] doubleValue] <= 0) return -1;
	for (RLLine *l in lines)
		for (RLSyl *s in l.main)
			if (s.end - s.start > 0.001) return 2;
	return 0;
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

static dispatch_queue_t gFetchQ;

// Every source is asked at once; the first answer shows and a better one (word timing over line timing)
// replaces it, so done can run more than once.
void RLFetch(NSString *title, NSString *artist, NSString *isrc, double duration, BOOL flush, void (^done)(NSArray<RLLine *> *lines)) {
	static NSMutableDictionary<NSString *, RLJob *> *jobs;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		gFetchQ = dispatch_queue_create("rl.fetch", DISPATCH_QUEUE_SERIAL);
		gLyricsCache = [NSCache new];
		jobs = [NSMutableDictionary dictionary];
	});
	dispatch_queue_t queue = gFetchQ;
	BOOL romanize = RLBool(@"romanize", NO);
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
		NSArray *hit = flush ? nil : [gLyricsCache objectForKey:key] ?: RLFromDisk(base, romanize);
		if (hit) {
			[gLyricsCache setObject:hit forKey:key];
			dispatch_async(dispatch_get_main_queue(), ^{ done(hit); });
			return;
		}
		if (flush) RLDiskWrite(base, nil, nil);
		RLJob *j = [RLJob new];
		j.dones = [NSMutableArray arrayWithObject:done];
		jobs[key] = j;
		void (^send)(NSArray *) = ^(NSArray *lines) {
			for (void (^f)(NSArray *) in j.dones) dispatch_async(dispatch_get_main_queue(), ^{ f(lines); });
		};

		void (^offer)(NSString *, NSData *) = ^(NSString *source, NSData *d) {
			NSArray *lines = RLParseAs(source, d, romanize);
			if (!lines) return;
			dispatch_async(queue, ^{
				RLJob *c = [RLJob new];
				c.lines = lines;
				c.source = source;
				c.payload = d;
				c.score = RLScore(lines);
				c.grams = RLGrams(lines);
				if (!j.seen) j.seen = [NSMutableArray array];
				[j.seen addObject:c];
				// sources agreeing outrank better timing: a source can answer another song with the same title
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
				send(best.lines);
			});
		};
		dispatch_group_t group = dispatch_group_create();
		dispatch_queue_t net = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
		dispatch_group_async(group, net, ^{ offer(@"unison", RLUnisonGet(title, artist, duration)); });
		dispatch_group_async(group, net, ^{ offer(@"binilyrics", RLBiniGet(title, artist, isrc, duration)); });
		dispatch_group_async(group, net, ^{
			NSData *mxm = RLMxmGet(title, artist, isrc, duration);
			offer(@"spicy", RLSpicyGet(mxm));
			offer(@"musixmatch", mxm);
		});
		dispatch_group_notify(group, queue, ^{
			[jobs removeObjectForKey:key];
			if (j.lines) {
				[gLyricsCache setObject:j.lines forKey:key];
				RLDiskWrite(base, j.source, j.payload);
			} else send(nil);
			RLLog(@"lyrics settled: %@", j.source ?: @"none");
		});
	});
}
