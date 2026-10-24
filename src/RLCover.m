// Apple Music animated covers, same lookup as radiant-lyrics-luna (ama.trainswift.net): ISRC first, then title/artist.
#import "RL.h"
#import <AVFoundation/AVFoundation.h>

static NSCache *gCovers;
static NSMutableArray<NSArray *> *gISRCs;
static NSString *gTitle, *gArtist, *gAlbum, *gKey, *gURL, *gPlaying;
static double gDuration;
static CGFloat gPx;
static NSUInteger gSeq;
static BOOL gWaiting;
static AVQueuePlayer *gPlayer;
static AVPlayerLooper *gLooper;
static AVPlayerLayer *gLayer;

static id RLAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static NSArray *RLSeen(NSString *title, double duration) {
	NSString *want = RLLineKey(title ?: @"");
	if (!want.length) return nil;
	for (int loose = 0; loose < 2; loose++)
		for (NSArray *e in gISRCs.reverseObjectEnumerator) {
			NSString *got = e[0];
			double d = [e[2] doubleValue];
			BOOL name = loose ? [got containsString:want] || [want containsString:got] : [got isEqualToString:want];
			if (name && !(duration > 0 && d > 0 && fabs(d - duration) > 3)) return e;
		}
	return nil;
}

static NSString *RLCoverISRCFor(NSString *title, double duration) { return RLSeen(title, duration)[1]; }

static NSString *RLCoverLookup(NSString *query, BOOL *answered) {
	NSData *d;
	NSInteger st = RLGet([@"https://ama.trainswift.net/api/v1/artwork/search?" stringByAppendingString:query], nil, 10, &d);
	*answered &= st == 200 || st == 404;
	NSDictionary *j = st == 200 && d ? RLAs([NSJSONSerialization JSONObjectWithData:d options:0 error:nil], NSDictionary.class) : nil;
	NSString *url = RLAs(j[@"url"], NSString.class);
	return url.length ? url : nil;
}

static void RLCoverResolve(NSUInteger seq) {
	if (seq != gSeq || !gWaiting) return;
	gWaiting = NO;
	NSString *isrc = RLCoverISRCFor(gTitle, gDuration), *key = gKey, *title = gTitle;
	NSString *q = [NSString stringWithFormat:@"title=%@&artist=%@", RLEnc(gTitle), RLEnc(gArtist)];
	NSString *withAlbum = gAlbum.length ? [NSString stringWithFormat:@"%@&album=%@", q, RLEnc(gAlbum)] : nil;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		BOOL answered = YES;
		NSString *url = isrc ? RLCoverLookup([@"isrc=" stringByAppendingString:RLEnc(isrc)], &answered) : nil;
		if (!url && withAlbum) url = RLCoverLookup(withAlbum, &answered);
		if (!url) url = RLCoverLookup(q, &answered);
		// ama's title search has been answering 404 for everything, so a miss without the ISRC isn't kept:
		// the ISRC arriving late (RLTrackSeen) looks again
		dispatch_async(dispatch_get_main_queue(), ^{
			if (answered && (url || isrc)) [gCovers setObject:url ?: NSNull.null forKey:key];
			RLLog(@"animated cover for %@ (ISRC %@): %@", title, isrc ?: @"unknown", url ? @"found" : answered ? @"none" : @"lookup failed");
			if (seq != gSeq) return;
			gURL = url;
			gWaiting = !url && !isrc;
		});
	});
}

static void RLCoverStop(void) {
	[gLooper disableLooping];
	[gPlayer pause];
	[gLayer removeFromSuperlayer];
	gPlayer = nil;
	gLooper = nil;
	gLayer = nil;
	gPlaying = gURL = nil;
	gWaiting = NO;
}

void RLTrackSeen(NSString *title, NSString *isrc, double duration, NSString *trackId) {
	if (!title.length || !isrc.length) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!gISRCs) gISRCs = [NSMutableArray array];
		[gISRCs addObject:@[ RLLineKey(title), isrc, @(duration), trackId ?: @"" ]];
		if (gISRCs.count > 50) [gISRCs removeObjectAtIndex:0];
		if (gWaiting && RLCoverISRCFor(gTitle, gDuration)) RLCoverResolve(gSeq);
	});
}

void RLCoverTrack(NSString *title, NSString *artist, NSString *album, double duration) {
	gTitle = title, gArtist = artist, gAlbum = album, gDuration = duration;
	if (!RLBool(@"animCover", YES)) { RLCoverStop(); gKey = nil; return; }
	NSString *key = [NSString stringWithFormat:@"%@\n%@", artist, album.length ? album : [@"\n" stringByAppendingString:title]];
	if ([key isEqualToString:gKey]) return;
	RLCoverStop();
	gKey = key;
	NSUInteger seq = ++gSeq;
	if (!gCovers) gCovers = [NSCache new], gCovers.countLimit = 200;
	id hit = [gCovers objectForKey:key];
	if (hit) { gURL = hit == NSNull.null ? nil : hit; return; }
	gWaiting = YES;
	if (RLCoverISRCFor(title, duration)) RLCoverResolve(seq);
	else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ RLCoverResolve(seq); });
}

void RLCoverSetting(void) {
	gKey = nil;
	if (gTitle) RLCoverTrack(gTitle, gArtist, gAlbum, gDuration);
	else RLCoverStop();
}

static void RLCoverScan(CALayer *layer, CALayer *root, CALayer **best, CGFloat *size, BOOL *video) {
	for (CALayer *l in layer.sublayers) {
		if (l == gLayer || l.hidden || l.opacity < 0.01 || [l.delegate isKindOfClass:RLLyricsView.class]) continue;
		if ([l isKindOfClass:AVPlayerLayer.class]) { *video = YES; continue; }
		CGRect r = [l convertRect:l.bounds toLayer:root];
		if (l.contents && CFGetTypeID((__bridge CFTypeRef)l.contents) == CGImageGetTypeID() && r.size.width >= 40 && r.size.width < root.bounds.size.width * 0.95 &&
		    fabs(r.size.width - r.size.height) < 2 && r.size.width > *size && CGRectContainsPoint(root.bounds, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)))) {
			*size = r.size.width;
			*best = l;
		}
		RLCoverScan(l, root, best, size, video);
	}
}

void RLCoverSync(UIView *player) {
	CALayer *cover = nil;
	CGFloat size = 0;
	BOOL video = NO;
	if (player && gURL) RLCoverScan(player.layer, player.layer, &cover, &size, &video);
	if (!cover || video) {
		[gPlayer pause];
		[gLayer removeFromSuperlayer];
		return;
	}
	if (![gPlaying isEqualToString:gURL]) {
		[gLooper disableLooping];
		[gPlayer pause];
		[gLayer removeFromSuperlayer];
		gPlayer = [AVQueuePlayer new];
		gPlayer.muted = YES;
		gPlayer.allowsExternalPlayback = NO;
		gPlayer.preventsDisplaySleepDuringVideoPlayback = NO;
		gPlayer.audiovisualBackgroundPlaybackPolicy = AVPlayerAudiovisualBackgroundPlaybackPolicyPauses;
		gLooper = [AVPlayerLooper playerLooperWithPlayer:gPlayer templateItem:[AVPlayerItem playerItemWithURL:[NSURL URLWithString:gURL]]];
		gPx = 0;
		gLayer = [AVPlayerLayer playerLayerWithPlayer:gPlayer];
		gLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
		gLayer.opacity = 0;
		gPlaying = gURL;
		RLLog(@"animated cover on %@ %.0fpt", cover.class, size);
	}
	CGFloat px = size * UIScreen.mainScreen.scale;
	if (px > gPx) {
		gPx = px;
		for (AVPlayerItem *i in gLooper.loopingPlayerItems) i.preferredMaximumResolution = CGSizeMake(px, px);
	}
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	if (gLayer.superlayer != cover) [cover addSublayer:gLayer];
	gLayer.frame = cover.bounds;
	gLayer.cornerRadius = cover.cornerRadius;
	gLayer.cornerCurve = cover.cornerCurve;
	gLayer.masksToBounds = YES;
	if (gLayer.opacity < 1 && gLayer.readyForDisplay) {
		CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
		fade.fromValue = @0;
		fade.duration = 0.3;
		[gLayer addAnimation:fade forKey:@"fade"];
		gLayer.opacity = 1;
	}
	[CATransaction commit];
	if (gPlayer.rate == 0 && gPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay) [gPlayer play];
}
