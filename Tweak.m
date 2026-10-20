#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

#define N 4

static BOOL running = NO;
static BOOL enabled[N] = {YES, YES, NO, NO};
static double delayMs[N] = {60, 60, 60, 60};
static UIView *markers[N];
static UIView *panelBody;
static UIView *panel;
static UIButton *startBtn;
static NSMutableArray<UILabel *> *labels;
static int cur = 0;
static NSUInteger runToken = 0;
static __weak UIView *cachedGL;
static id acDelegate;
static int tapMode = 1;            // 1 = لمس مباشر، 2 = حدث نظام
static UILabel *dbgLabel;
#define PANEL_H (44 + 38 * (N + 1) + 30)
static double holdMs = 80;       // مدة بقاء الزر مضغوطاً
static UILabel *holdLabel;

#define GREEN [UIColor colorWithRed:0 green:.6 blue:.2 alpha:1]

// ---------- لمسة مزيفة للطريقة 1 ----------
@interface FakeTouch : UITouch
@property (nonatomic) CGPoint pt;
@property (nonatomic) UITouchPhase ph;
@property (nonatomic, weak) UIView *tv;
@property (nonatomic) NSTimeInterval ts;
@end
@implementation FakeTouch
- (UITouchPhase)phase { return self.ph; }
- (CGPoint)locationInView:(UIView *)v {
    return v ? [v convertPoint:self.pt fromView:self.tv]
             : [self.tv convertPoint:self.pt toView:nil];
}
- (CGPoint)previousLocationInView:(UIView *)v { return [self locationInView:v]; }
- (UIView *)view { return self.tv; }
- (UIWindow *)window { return self.tv.window; }
- (NSTimeInterval)timestamp { return self.ts; }
- (NSUInteger)tapCount { return 1; }
- (UITouchType)type { return UITouchTypeDirect; }
- (CGFloat)majorRadius { return 5; }
- (CGFloat)force { return 0; }
- (NSArray *)gestureRecognizers { return @[]; }
@end

// ---------- إيجاد عرض Cocos2d ----------
static UIView *findGL(UIView *v) {
    if ([NSStringFromClass(v.class) hasPrefix:@"CCGLView"]) return v;
    for (UIView *s in v.subviews) { UIView *r = findGL(s); if (r) return r; }
    return nil;
}

static UIView *glView(void) {
    if (cachedGL && cachedGL.window) return cachedGL;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        UIView *r = findGL(w);
        if (r) { cachedGL = r; return r; }
    }
    return nil;
}

// ---------- حدث لمس حقيقي عبر UIKit (نفس مسار اللمس الفعلي) ----------
@interface UITouch (AC)
- (void)setTapCount:(NSUInteger)c;
- (void)setIsTap:(BOOL)b;
- (void)setPhase:(UITouchPhase)p;
- (void)setTimestamp:(NSTimeInterval)t;
- (void)setView:(UIView *)v;
- (void)setWindow:(UIWindow *)w;
- (void)_setLocationInWindow:(CGPoint)p resetPrevious:(BOOL)r;
- (void)_setIsFirstTouchForView:(BOOL)b;
@end
@interface UIEvent (AC)
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)t forDelayedDelivery:(BOOL)d;
- (void)_setHIDEvent:(void *)e;
@end
@interface UIApplication (AC)
- (UIEvent *)_touchesEvent;
@end

typedef void *HIDRef;

static HIDRef makeHID(CGPoint loc, UITouchPhase ph) {
    static HIDRef (*createDig)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t,
                               uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
    static HIDRef (*createFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                  double, double, double, double, double, Boolean, Boolean, uint32_t);
    static void (*appendEv)(HIDRef, HIDRef);
    static void (*setInt)(HIDRef, uint32_t, int);
    static void (*setFloat)(HIDRef, uint32_t, double);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (!h) h = RTLD_DEFAULT;
        createDig = dlsym(h, "IOHIDEventCreateDigitizerEvent");
        createFinger = dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
        appendEv = dlsym(h, "IOHIDEventAppendEvent");
        setInt = dlsym(h, "IOHIDEventSetIntegerValue");
        setFloat = dlsym(h, "IOHIDEventSetFloatValue");
    });
    if (!createDig || !createFinger || !appendEv) return NULL;

    uint64_t ts = mach_absolute_time();
    HIDRef hand = createDig(kCFAllocatorDefault, ts, 3, 0, 0, 2, 0, 0, 0, 0, 0, 0, false, false, 0);
    if (!hand) return NULL;
    if (setInt) setInt(hand, 0xB0019, 1);                    // IsDisplayIntegrated
    CGSize sc = UIScreen.mainScreen.bounds.size;
    uint32_t mask = (ph == UITouchPhaseMoved) ? 4 : (1 | 2);
    Boolean touching = (ph != UITouchPhaseEnded);
    HIDRef finger = createFinger(kCFAllocatorDefault, ts, 1, 2, mask,
                                 loc.x / sc.width, loc.y / sc.height, 0, 0, 0, touching, touching, 0);
    if (finger) {
        if (setFloat) { setFloat(finger, 0xB0004, 5.0); setFloat(finger, 0xB0005, 5.0); }
        appendEv(hand, finger);
        CFRelease(finger);
    }
    return hand;
}

static void deliver(UITouch *t, UITouchPhase ph, CGPoint wp) {
    UIApplication *app = UIApplication.sharedApplication;
    [t setPhase:ph];
    [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
    if (ph != UITouchPhaseBegan) [t _setLocationInWindow:wp resetPrevious:NO];
    UIEvent *ev = [app _touchesEvent];
    [ev _clearTouches];
    HIDRef h = makeHID(wp, ph);
    if (h) { [ev _setHIDEvent:h]; CFRelease(h); }
    [ev _addTouch:t forDelayedDelivery:NO];
    [app sendEvent:ev];
}

static BOOL privateOK(void) {
    UIApplication *a = UIApplication.sharedApplication;
    return [a respondsToSelector:@selector(_touchesEvent)]
        && [UIEvent instancesRespondToSelector:@selector(_clearTouches)]
        && [UIEvent instancesRespondToSelector:@selector(_addTouch:forDelayedDelivery:)]
        && [UITouch instancesRespondToSelector:@selector(_setLocationInWindow:resetPrevious:)]
        && [UITouch instancesRespondToSelector:@selector(setView:)]
        && [UITouch instancesRespondToSelector:@selector(setPhase:)];
}

static void setDbg(NSString *t) { dbgLabel.text = t; }

// الطريقة 1: لمس مباشر على العنصر الموجود تحت النقطة
static void tapDirect(UIView *target, CGPoint wp) {
    CGPoint lp = [target convertPoint:wp fromView:nil];
    FakeTouch *t = [FakeTouch new];
    t.tv = target; t.pt = lp; t.ph = UITouchPhaseBegan;
    t.ts = NSProcessInfo.processInfo.systemUptime;
    NSSet *set = [NSSet setWithObject:t];
    UIApplication *app = UIApplication.sharedApplication;
    UIEvent *ev = nil;
    if ([app respondsToSelector:@selector(_touchesEvent)]) ev = [app _touchesEvent];
    UIControl *ctl = nil;
    UIView *vv = target;
    for (int d = 0; vv && d < 4; d++, vv = vv.superview)
        if ([vv isKindOfClass:UIControl.class]) { ctl = (UIControl *)vv; break; }
    setDbg([NSString stringWithFormat:@"m1 %@ ctl:%@ hold:%.0f", NSStringFromClass(target.class),
            ctl ? NSStringFromClass(ctl.class) : @"-", holdMs]);
    @try {
        if (ctl) [ctl sendActionsForControlEvents:UIControlEventTouchDown];
        else [target touchesBegan:set withEvent:ev];
    } @catch (NSException *e) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(holdMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        t.ph = UITouchPhaseEnded;
        t.ts = NSProcessInfo.processInfo.systemUptime;
        @try {
            if (ctl) [ctl sendActionsForControlEvents:UIControlEventTouchUpInside];
            else [target touchesEnded:set withEvent:ev];
        } @catch (NSException *e) {}
    });
}

// الطريقة 2: حدث لمس عبر نظام iOS
static void tapSystem(UIWindow *w, UIView *target, CGPoint wp) {
    if (!privateOK()) { setDbg(@"m2: الدوال الخاصة غير متوفرة"); return; }
    @try {
        UITouch *t = [[UITouch alloc] init];
        [t setTapCount:1];
        [t setIsTap:YES];
        [t setPhase:UITouchPhaseBegan];
        [t _setLocationInWindow:wp resetPrevious:YES];
        [t setView:target];
        [t setWindow:w];
        [t _setIsFirstTouchForView:YES];
        deliver(t, UITouchPhaseBegan, wp);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(holdMs * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            @try { deliver(t, UITouchPhaseEnded, wp); } @catch (NSException *e) {}
        });
    } @catch (NSException *e) { setDbg([@"m2 exc: " stringByAppendingString:e.name]); }
}

static void tapAtWindowPoint(CGPoint wp) {
    UIView *gl = glView();
    UIWindow *w = gl.window;
    if (!w) { setDbg(@"لا يوجد CCGLView"); return; }
    UIView *target = [w hitTest:wp withEvent:nil];
    if (!target || target == w) target = gl;
    setDbg([NSString stringWithFormat:@"m%d  %@  p:%d", tapMode,
            NSStringFromClass(target.class), privateOK()]);
    if (tapMode == 2) tapSystem(w, target, wp);
    else tapDirect(target, wp);
}

// ---------- الحلقة المتسلسلة 1 ← 2 ← 3 ← 4 ----------
static void step(NSUInteger token) {
    if (!running || token != runToken) return;
    int tries = 0;
    while (!enabled[cur] && tries++ < N) cur = (cur + 1) % N;
    if (!enabled[cur]) return;
    int i = cur;
    UIView *m = markers[i];
    tapAtWindowPoint([m.superview convertPoint:m.center toView:nil]);
    cur = (cur + 1) % N;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(delayMs[i], holdMs + 10) * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ step(token); });
}

static void refreshMarkers(void) {
    for (int i = 0; i < N; i++) {
        markers[i].hidden = !enabled[i];
        markers[i].userInteractionEnabled = !running;   // أثناء التشغيل لا تبلع اللمسات
        markers[i].alpha = running ? 0.35 : 1.0;
    }
}

// ---------- الواجهة ----------
@interface ACUI : NSObject <UIGestureRecognizerDelegate>
+ (void)start:(UIButton *)b;
+ (void)toggle:(UIButton *)b;
+ (void)slide:(UISlider *)s;
+ (void)pan:(UIPanGestureRecognizer *)g;
+ (void)collapse:(UIButton *)b;
+ (void)mode:(UIButton *)b;
@end

@implementation ACUI
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return ![t.view isKindOfClass:UIControl.class];
}
+ (void)start:(UIButton *)b {
    running = !running;
    runToken++;
    [b setTitle:running ? @"STOP" : @"START" forState:UIControlStateNormal];
    b.backgroundColor = running ? UIColor.redColor : GREEN;
    refreshMarkers();
    if (running) { cur = 0; step(runToken); }
}
+ (void)toggle:(UIButton *)b {
    int i = (int)b.tag;
    enabled[i] = !enabled[i];
    b.backgroundColor = enabled[i] ? GREEN : UIColor.grayColor;
    refreshMarkers();
}
+ (void)slide:(UISlider *)s {
    if (s.tag == 100) {
        holdMs = round(s.value);
        holdLabel.text = [NSString stringWithFormat:@"%.0fms", holdMs];
        return;
    }
    int i = (int)s.tag;
    delayMs[i] = round(s.value);
    labels[i].text = [NSString stringWithFormat:@"%.0fms", delayMs[i]];
}
+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint d = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
+ (void)mode:(UIButton *)b {
    tapMode = (tapMode == 1) ? 2 : 1;
    [b setTitle:[NSString stringWithFormat:@"M%d", tapMode] forState:UIControlStateNormal];
}
+ (void)collapse:(UIButton *)b {
    BOOL hide = !panelBody.hidden;
    panelBody.hidden = hide;
    CGRect f = panel.frame;
    f.size.height = hide ? 44 : PANEL_H;
    panel.frame = f;
    [b setTitle:hide ? @"+" : @"–" forState:UIControlStateNormal];
}
@end

static void buildUI(UIWindow *w) {
    labels = [NSMutableArray new];
    UIColor *cols[N] = {UIColor.systemRedColor, UIColor.systemBlueColor,
                        UIColor.systemOrangeColor, UIColor.systemPurpleColor};

    // دوائر النقر (اسحبها فوق أزرار المود)
    for (int i = 0; i < N; i++) {
        UILabel *m = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        m.center = CGPointMake(w.bounds.size.width * (0.3 + 0.15 * i), w.bounds.size.height * 0.7);
        m.backgroundColor = [cols[i] colorWithAlphaComponent:0.55];
        m.layer.cornerRadius = 22; m.clipsToBounds = YES;
        m.textAlignment = NSTextAlignmentCenter; m.textColor = UIColor.whiteColor;
        m.text = [NSString stringWithFormat:@"%d", i + 1];
        m.userInteractionEnabled = YES;
        [m addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(pan:)]];
        [w addSubview:m];
        markers[i] = m;
    }

    // اللوحة
    panel = [[UIView alloc] initWithFrame:CGRectMake(10, 60, 262, PANEL_H)];
    panel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    panel.layer.cornerRadius = 12;
    UIPanGestureRecognizer *pg = [[UIPanGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(pan:)];
    pg.cancelsTouchesInView = NO;
    acDelegate = [ACUI new];
    pg.delegate = acDelegate;
    [panel addGestureRecognizer:pg];

    startBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    startBtn.frame = CGRectMake(8, 6, 160, 32);
    startBtn.backgroundColor = GREEN; startBtn.layer.cornerRadius = 8;
    [startBtn setTitle:@"START" forState:UIControlStateNormal];
    [startBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [startBtn addTarget:ACUI.class action:@selector(start:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:startBtn];

    UIButton *cb = [UIButton buttonWithType:UIButtonTypeSystem];
    cb.frame = CGRectMake(220, 6, 34, 32);
    cb.backgroundColor = UIColor.darkGrayColor; cb.layer.cornerRadius = 8;
    [cb setTitle:@"–" forState:UIControlStateNormal];
    [cb setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [cb addTarget:ACUI.class action:@selector(collapse:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:cb];

    UIButton *mb = [UIButton buttonWithType:UIButtonTypeSystem];
    mb.frame = CGRectMake(174, 6, 40, 32);
    mb.backgroundColor = UIColor.systemBlueColor; mb.layer.cornerRadius = 8;
    [mb setTitle:@"M1" forState:UIControlStateNormal];
    [mb setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [mb addTarget:ACUI.class action:@selector(mode:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:mb];

    panelBody = [[UIView alloc] initWithFrame:CGRectMake(0, 44, 262, 38 * (N + 1) + 30)];
    [panel addSubview:panelBody];

    for (int i = 0; i < N; i++) {
        CGFloat y = 38 * i;
        UIButton *t = [UIButton buttonWithType:UIButtonTypeSystem];
        t.frame = CGRectMake(8, y, 34, 30); t.tag = i; t.layer.cornerRadius = 15;
        t.backgroundColor = enabled[i] ? GREEN : UIColor.grayColor;
        [t setTitle:[NSString stringWithFormat:@"%d", i + 1] forState:UIControlStateNormal];
        [t setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [t addTarget:ACUI.class action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
        [panelBody addSubview:t];

        UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(48, y, 140, 30)];
        s.minimumValue = 10; s.maximumValue = 500; s.value = delayMs[i]; s.tag = i;
        [s addTarget:ACUI.class action:@selector(slide:) forControlEvents:UIControlEventValueChanged];
        [panelBody addSubview:s];

        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(194, y, 62, 30)];
        l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:13];
        l.text = [NSString stringWithFormat:@"%.0fms", delayMs[i]];
        [panelBody addSubview:l]; [labels addObject:l];
    }
    CGFloat hy = 38 * N;
    UILabel *hl = [[UILabel alloc] initWithFrame:CGRectMake(8, hy, 40, 30)];
    hl.text = @"Hold"; hl.textColor = UIColor.whiteColor; hl.font = [UIFont systemFontOfSize:13];
    [panelBody addSubview:hl];
    UISlider *hs = [[UISlider alloc] initWithFrame:CGRectMake(48, hy, 140, 30)];
    hs.minimumValue = 15; hs.maximumValue = 300; hs.value = holdMs; hs.tag = 100;
    [hs addTarget:ACUI.class action:@selector(slide:) forControlEvents:UIControlEventValueChanged];
    [panelBody addSubview:hs];
    holdLabel = [[UILabel alloc] initWithFrame:CGRectMake(194, hy, 62, 30)];
    holdLabel.textColor = UIColor.whiteColor; holdLabel.font = [UIFont systemFontOfSize:13];
    holdLabel.text = [NSString stringWithFormat:@"%.0fms", holdMs];
    [panelBody addSubview:holdLabel];

    dbgLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 38 * (N + 1) + 4, 246, 20)];
    dbgLabel.textColor = UIColor.yellowColor;
    dbgLabel.font = [UIFont systemFontOfSize:11];
    dbgLabel.text = @"جاهز";
    [panelBody addSubview:dbgLabel];
    [w addSubview:panel];
    refreshMarkers();
}

// ننتظر حتى يظهر عرض اللعبة (CCGLView) ثم نبني الواجهة
static void tryBuild(int retries) {
    UIView *gl = glView();
    if (gl.window) { buildUI(gl.window); return; }
    if (retries > 0)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ tryBuild(retries - 1); });
}

__attribute__((constructor)) static void init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ tryBuild(90); });
}
