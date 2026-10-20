#import <UIKit/UIKit.h>

#define RLLog(fmt, ...) RLLogLine([NSString stringWithFormat:fmt, ##__VA_ARGS__])
void RLLogLine(NSString *line);
NSArray<NSString *> *RLLogLines(void);

#define RLDefaults [NSUserDefaults standardUserDefaults]
static inline BOOL RLBool(NSString *k, BOOL d) { id v = [RLDefaults objectForKey:[@"rl." stringByAppendingString:k]]; return v ? [v boolValue] : d; }
static inline double RLNum(NSString *k, double d) { id v = [RLDefaults objectForKey:[@"rl." stringByAppendingString:k]]; return v ? [v doubleValue] : d; }
static inline void RLSet(NSString *k, id v) { [RLDefaults setObject:v forKey:[@"rl." stringByAppendingString:k]]; }

@interface RLSyl : NSObject
@property (nonatomic, copy) NSString *text; // may end with a space = word boundary
@property (nonatomic) double start, end;
@end

@interface RLLine : NSObject
@property (nonatomic) double start, end;
@property (nonatomic, copy) NSArray<RLSyl *> *main, *bg;
@property (nonatomic, copy) NSArray<RLSyl *> *tr;
@property (nonatomic) NSMutableDictionary<NSString *, NSArray<RLSyl *> *> *mx;
@property (nonatomic, copy) NSString *key;
@property (nonatomic) BOOL right;
@end

typedef NS_ENUM(NSInteger, RLStatus) { RLStatusIdle, RLStatusLoading, RLStatusOK, RLStatusMissing };

NSArray<RLLine *> *RLParse(NSDictionary *json, BOOL romanize);
NSInteger RLGet(NSString *url, NSDictionary *headers, NSTimeInterval timeout, NSData **out);
NSString *RLEnc(NSString *s);
NSString *RLLineKey(NSString *s);
NSArray<RLSyl *> *RLWords(NSString *text, double t);
void RLTranslate(NSArray<RLLine *> *lines, NSString *title, NSString *artist, NSString *lang, void (^done)(BOOL found));

#define kRLTrLangs (@[ @"ko", @"en", @"ja", @"zh", @"es", @"fr", @"de", @"pt", @"it", @"ru", @"vi", @"th", @"id", @"tr", @"tl", @"nl", @"pl", @"ar", @"hi" ])

static inline NSString *RLTrLang(void) {
	NSString *l = [RLDefaults stringForKey:@"rl.trLang"] ?: [NSLocale.preferredLanguages.firstObject substringToIndex:MIN(2, NSLocale.preferredLanguages.firstObject.length)];
	return [kRLTrLangs containsObject:l] ? l : @"en";
}

static inline NSArray<RLSyl *> *RLTrFor(RLLine *l) {
	if (!RLBool(@"tr", NO)) return nil;
	return l.tr ?: l.mx[RLTrLang()];
}
void RLFetch(NSString *title, NSString *artist, NSString *isrc, double duration, BOOL flush, void (^done)(NSArray<RLLine *> *lines));
NSString *RLAIType(NSArray<RLLine *> *lines);
BOOL RLHasTr(NSArray<RLLine *> *lines);
void RLRetime(NSString *title, NSString *artist, double duration, NSArray<RLLine *> *lines, void (^done)(NSArray<RLLine *> *lines));
NSString *RLSourceName(NSArray<RLLine *> *lines);
NSAttributedString *RLCredit(NSArray<RLLine *> *lines);
NSArray<NSNumber *> *RLSides(NSArray *singers, NSDictionary<NSString *, NSString *> *types);
RLSyl *RLMakeSyl(NSString *text, double start, double end);
RLLine *RLMakeLine(double start, double end, NSMutableArray<RLSyl *> *main, NSMutableArray<RLSyl *> *bg, NSString *keyText, BOOL right);
NSString *RLCollapse(NSString *s);
double RLClock(NSString *s);
NSDictionary *RLMxm(NSString *method, NSString *query, NSInteger *status);
NSString *RLMxmToken(NSString *rejected);
NSData *RLUnisonGet(NSString *title, NSString *artist, double duration);
NSData *RLBiniGet(NSString *title, NSString *artist, NSString *isrc, double duration);
NSData *RLMxmGet(NSString *title, NSString *artist, NSString *isrc, double duration);
NSData *RLSpicyGet(NSData *mxm);
NSArray<RLLine *> *RLParseTTML(NSData *d, BOOL romanize);
NSArray<RLLine *> *RLParseMxm(NSData *d);
NSArray<RLLine *> *RLParseSpicy(NSData *d, BOOL romanize, NSAttributedString **credit);
void RLCoverTrack(NSString *title, NSString *artist, NSString *album, double duration);
void RLTrackSeen(NSString *title, NSString *isrc, double duration, NSString *trackId);
NSArray<NSString *> *RLTrackRef(NSString *title, double duration);
void RLCoverSync(UIView *player);
void RLCoverSetting(void);

@interface RLStore : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSArray<RLLine *> *lines;
@property (nonatomic, readonly) RLStatus status;
@property (nonatomic, readonly) UIImage *artwork;
@property (nonatomic, readonly) BOOL playing;
- (double)now;
- (void)refetch;
- (void)refetch:(BOOL)flush;
- (void)refresh;
- (void)retime;
- (void)translate;
- (void)seek:(double)t;
@end

@interface RLLyricsView : UIView
@property (nonatomic, weak, readonly) UIScrollView *tidal;
+ (instancetype)attachTo:(UIScrollView *)tidal;
- (void)detach;
- (void)reload;
- (void)rebuild;
- (void)restart;
@end

@interface RLBackdrop : UIView
@property (nonatomic, weak) UIView *follow;
@property (nonatomic, readonly) BOOL ready;
@property (nonatomic, readonly) BOOL hasFrame;
@property (nonatomic, readonly) UIColor *avgColor;
- (void)setCover:(UIImage *)cover;
- (void)tick;
- (void)restart;
@end

void RLOpenSettings(UIViewController *from);
void RLSettingsChanged(NSString *key);
void RLClearCache(void);
void RLReplay(void);

static inline NSString *RLL(NSString *en, NSString *ko) {
	NSInteger lang = (NSInteger)RLNum(@"lang", 0);
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}
