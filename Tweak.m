#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
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
static BOOL editBtns = NO;
static NSMutableDictionary<NSString *, NSValue *> *hookOrig;   // الدوال الأصلية قبل هوكاتنا
static void recordOrig(Class c, SEL sel, IMP orig) {
    if (!hookOrig) hookOrig = [NSMutableDictionary new];
    hookOrig[[NSString stringWithFormat:@"%s %s", class_getName(c), sel_getName(sel)]] =
        [NSValue valueWithPointer:(const void *)orig];
}
static void installHooks(void);
static void buildModPanel(UIWindow *w);
static void modSlide(UISlider *s);
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

// ---------- سكانر: يستخرج أسماء دوال وقيم اللعبة ذات العلاقة وينسخها ----------
static void scanGame(void) {
    NSArray *keys = @[@"shoot", @"split", @"feed", @"zoom", @"scale", @"camera",
                      @"fps", @"interval", @"eject", @"cooldown", @"button",
                      @"touch", @"joystick", @"mass"];
    NSArray *gameCls = @[@"Arena", @"AgarCell", @"HUD", @"Camera", @"Joystick",
                         @"MCInput", @"CCDirectorDisplayLink", @"Zoom"];
    BOOL (^isGame)(const char *) = ^BOOL(const char *n) {
        NSString *x = [NSString stringWithUTF8String:n];
        for (NSString *k in gameCls)
            if ([x rangeOfString:k].location != NSNotFound) return YES;
        return NO;
    };
    BOOL (^hit)(const char *) = ^BOOL(const char *n) {
        if (!n) return NO;
        NSString *x = [NSString stringWithUTF8String:n];
        for (NSString *k in keys)
            if ([x rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        return NO;
    };
    NSMutableString *out = [NSMutableString new];
    unsigned n = 0;
    Class *list = objc_copyClassList(&n);
    int lines = 0;
    for (unsigned i = 0; i < n && lines < 450; i++) {
        Class c = list[i];
        const char *img = class_getImageName(c);
        if (!img || !strstr(img, ".app/") || strstr(img, "/Frameworks/")) continue;  // ملف اللعبة الرئيسي فقط
        const char *cn = class_getName(c);
        if (!isGame(cn)) continue;
        for (int meta = 0; meta < 2; meta++) {
            Class k = meta ? object_getClass(c) : c;
            unsigned mc = 0;
            Method *ms = class_copyMethodList(k, &mc);
            for (unsigned j = 0; j < mc && lines < 450; j++) {
                const char *sel = sel_getName(method_getName(ms[j]));
                if (hit(sel)) {
                    [out appendFormat:@"%c[%s %s] %s\n", meta ? '+' : '-', cn, sel,
                     method_getTypeEncoding(ms[j]) ?: ""];
                    lines++;
                }
            }
            free(ms);
        }
        unsigned ic = 0;
        Ivar *iv = class_copyIvarList(c, &ic);
        for (unsigned j = 0; j < ic && lines < 450; j++) {
            const char *nm = ivar_getName(iv[j]);
            if (hit(nm)) {
                [out appendFormat:@"ivar %s.%s %s\n", cn, nm, ivar_getTypeEncoding(iv[j]) ?: ""];
                lines++;
            }
        }
        free(iv);
    }
    free(list);
    UIPasteboard.generalPasteboard.string = out;
    setDbg([NSString stringWithFormat:@"Scan: %d سطر منسوخ للحافظة", lines]);
}

// ---------- الواجهة ----------
@interface ACUI : NSObject <UIGestureRecognizerDelegate>
+ (void)start:(UIButton *)b;
+ (void)toggle:(UIButton *)b;
+ (void)slide:(UISlider *)s;
+ (void)pan:(UIPanGestureRecognizer *)g;
+ (void)collapse:(UIButton *)b;
+ (void)mode:(UIButton *)b;
+ (void)scan:(UIButton *)b;
@end

@implementation ACUI
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    if (g.view.tag >= 1000) return editBtns;
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
    if (s.tag >= 200) { modSlide(s); return; }
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
+ (void)scan:(UIButton *)b { scanGame(); }
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
    startBtn.frame = CGRectMake(8, 6, 118, 32);
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
    mb.frame = CGRectMake(132, 6, 40, 32);
    mb.backgroundColor = UIColor.systemBlueColor; mb.layer.cornerRadius = 8;
    [mb setTitle:@"M1" forState:UIControlStateNormal];
    [mb setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [mb addTarget:ACUI.class action:@selector(mode:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:mb];

    UIButton *sb = [UIButton buttonWithType:UIButtonTypeSystem];
    sb.frame = CGRectMake(178, 6, 36, 32);
    sb.backgroundColor = UIColor.systemOrangeColor; sb.layer.cornerRadius = 8;
    [sb setTitle:@"S" forState:UIControlStateNormal];
    [sb setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [sb addTarget:ACUI.class action:@selector(scan:) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:sb];

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
    installHooks();
    buildModPanel(w);
}

// ======================= قسم المود: دوال اللعبة نفسها =======================
@interface NSObject (AC2)
- (void)onShoot;
- (void)onSplit;
@end

static __weak id arenaState;                 // حالة المباراة (تُلتقط من الهوكات)
static __weak id arenaView;                  // عرض الساحة (يحمل الكاميرا)
static CADisplayLink *frameLink;
static BOOL macroOn = NO, softOn = NO, splitOn = NO, zoomBtnOn = NO, zStatic = NO, fps120 = NO;
static BOOL macroHeld = NO, ourCall = NO;
static int shootDepth = 0, zoomDir = 0;
static double macroSpeed = 50, softStrength = 50, splitSpeed = 70, zoomSpeed = 50;
static double macroAcc = 0, softAcc = 0;
static float zMul = 1.0f, zStaticVal = 1.0f, zBase = 0.0f, zLast = NAN;
static NSString *fpsInfo = @"";
static UILabel *modLabel;
static UIView *modPanel, *menuBtn;
static UIButton *fabMacro, *fabZoomUp, *fabZoomDown;
static NSMutableArray<UIButton *> *fabSplits, *allFabs;
static NSMutableDictionary<NSNumber *, UILabel *> *valLabels;

static BOOL ownsMethod(Class c, SEL sel) {
    unsigned n = 0;
    Method *ml = class_copyMethodList(c, &n);
    BOOL own = NO;
    for (unsigned i = 0; i < n; i++) if (method_getName(ml[i]) == sel) { own = YES; break; }
    free(ml);
    return own;
}

// ---- هوك التغذية: يلتقط الحالة + سوفت ماكرو على زر اللعبة الأصلي ----
static void hookShoot(Class c) {
    SEL sel = NSSelectorFromString(@"onShoot");
    if (!c || !ownsMethod(c, sel)) return;
    IMP orig = method_getImplementation(class_getInstanceMethod(c, sel));
    recordOrig(c, sel, orig);
    method_setImplementation(class_getInstanceMethod(c, sel), imp_implementationWithBlock(^(id me) {
        arenaState = me;
        shootDepth++;
        ((void (*)(id, SEL))orig)(me, sel);
        if (shootDepth == 1 && softOn && !ourCall) {
            softAcc += softStrength / 50.0;          // 0..2 تغذية إضافية لكل ضغطة
            int n = (int)softAcc;
            softAcc -= n;
            for (int i = 0; i < n && i < 4; i++) ((void (*)(id, SEL))orig)(me, sel);
        }
        shootDepth--;
    }));
}
static void hookVoid(Class c, SEL sel) {
    if (!c || !ownsMethod(c, sel)) return;
    IMP orig = method_getImplementation(class_getInstanceMethod(c, sel));
    recordOrig(c, sel, orig);
    method_setImplementation(class_getInstanceMethod(c, sel), imp_implementationWithBlock(^(id me) {
        arenaState = me;
        ((void (*)(id, SEL))orig)(me, sel);
    }));
}
static void hookBool(Class c, SEL sel) {
    if (!c || !ownsMethod(c, sel)) return;
    IMP orig = method_getImplementation(class_getInstanceMethod(c, sel));
    recordOrig(c, sel, orig);
    method_setImplementation(class_getInstanceMethod(c, sel), imp_implementationWithBlock(^BOOL(id me) {
        arenaState = me;
        return ((BOOL (*)(id, SEL))orig)(me, sel);
    }));
}

// ---- الكاميرا: نقرأ ونكتب _cameraScale مباشرة (6 قيم float) ----
static float *camScale(id view) {
    static Ivar iv;
    static Class bv;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bv = NSClassFromString(@"BaseArenaView");
        if (bv) iv = class_getInstanceVariable(bv, "_cameraScale");
    });
    if (!iv || !view || ![view isKindOfClass:bv]) return NULL;
    return (float *)((char *)(__bridge void *)view + ivar_getOffset(iv));
}

// تُنفَّذ بعد تحديث اللعبة للكاميرا وكل إطار من مؤقتنا
static void applyZoom(id view) {
    float *cs = camScale(view);       // [0]value [1]last [2]target [3]predicted
    if (!cs) return;
    BOOL active = (zoomBtnOn && fabsf(zMul - 1.0f) > 1e-3f) || zStatic;
    if (isnan(zLast) || cs[2] != zLast) zBase = cs[2];   // اللعبة كتبت قيمة جديدة
    if (!active) {
        if (!isnan(zLast)) { cs[0] = cs[1] = cs[2] = cs[3] = zBase; zLast = NAN; }
        return;
    }
    float want = zStatic ? zStaticVal : zBase * zMul;
    cs[0] = cs[1] = cs[2] = cs[3] = want;
    zLast = want;
}

static void installHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *nm in @[@"BaseArenaState", @"OnlineArenaState",
                               @"OfflineModeArenaState", @"BattleRoyaleArenaState"]) {
            Class c = NSClassFromString(nm);
            hookShoot(c);
            hookVoid(c, NSSelectorFromString(@"onSplit"));
            hookBool(c, NSSelectorFromString(@"canShoot"));
            hookBool(c, NSSelectorFromString(@"canSplit"));
        }
        Class av = NSClassFromString(@"BaseArenaView");
        SEL us = NSSelectorFromString(@"updateCameraTarget:");
        if (av && ownsMethod(av, us)) {
            IMP orig = method_getImplementation(class_getInstanceMethod(av, us));
            recordOrig(av, us, orig);
            method_setImplementation(class_getInstanceMethod(av, us),
                imp_implementationWithBlock(^(id me, float dt) {
                    arenaView = me;
                    ((void (*)(id, SEL, float))orig)(me, us, dt);
                    applyZoom(me);
                }));
        }
        SEL zs = NSSelectorFromString(@"calculateZoom:cellAmount:");
        if (av && ownsMethod(av, zs)) {
            IMP orig = method_getImplementation(class_getInstanceMethod(av, zs));
            recordOrig(av, zs, orig);
            method_setImplementation(class_getInstanceMethod(av, zs),
                imp_implementationWithBlock(^float(id me, float a, int n) {
                    arenaView = me;
                    return ((float (*)(id, SEL, float, int))orig)(me, zs, a, n);
                }));
        }
    });
}

static NSString *applyFPS(BOOL on) {
    double hz = on ? 120.0 : 60.0;
    Class dc = NSClassFromString(@"CCDirector");
    id dir = nil;
    if (dc && [dc respondsToSelector:NSSelectorFromString(@"sharedDirector")])
        dir = ((id (*)(id, SEL))objc_msgSend)(dc, NSSelectorFromString(@"sharedDirector"));
    if (!dir) return @"fps: no director";
    NSMutableString *r = [NSMutableString stringWithFormat:@"fps→%.0f ", hz];
    SEL si = NSSelectorFromString(@"setAnimationInterval:");
    if ([dir respondsToSelector:si]) {
        ((void (*)(id, SEL, double))objc_msgSend)(dir, si, 1.0 / hz);
        [r appendString:@"int✓ "];
    }
    for (Class c = [dir class]; c; c = class_getSuperclass(c)) {
        unsigned n = 0;
        Ivar *iv = class_copyIvarList(c, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *t = ivar_getTypeEncoding(iv[i]);
            if (t && strstr(t, "CADisplayLink")) {
                id l = object_getIvar(dir, iv[i]);
                if ([l isKindOfClass:CADisplayLink.class]) {
                    ((CADisplayLink *)l).preferredFramesPerSecond = (NSInteger)hz;
                    [r appendString:@"link✓ "];
                }
            }
        }
        free(iv);
    }
    return r;
}

static void doSplit(int n) {
    double gap = MAX(10.0, 200.0 - splitSpeed * 1.9);      // سرعة 100 → 10ms
    for (int i = 0; i < n; i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * gap * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            id st = arenaState;
            if (st) @try { [st onSplit]; } @catch (NSException *e) {}
        });
}

static void refreshModStatus(void) {
    id st = arenaState, v = arenaView;
    float *cs = camScale(v);
    modLabel.text = [NSString stringWithFormat:@"arena:%@ view:%@\ncam:%.3f base:%.3f z:%.2f %@",
        st ? NSStringFromClass([st class]) : @"-", v ? @"ok" : @"-",
        cs ? cs[0] : 0.0f, zBase, zStatic ? zStaticVal : zMul, fpsInfo];
}

// ---------- تحليل SharkMod: خريطة الهوكات + أصناف المود (بدون البوتات/الحساب) ----------
static void scanMod(void) {
    NSArray *skip = @[@"bot", @"token", @"uid", @"account", @"login", @"facebook",
                      @"fbsdk", @"key", @"password", @"credential", @"discord"];
    BOOL (^bad)(const char *) = ^BOOL(const char *n) {
        if (!n) return NO;
        NSString *x = [NSString stringWithUTF8String:n];
        for (NSString *k in skip)
            if ([x rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        return NO;
    };
    NSMutableString *out = [NSMutableString new];
    int lines = 0;
    unsigned n = 0;
    Class *list = objc_copyClassList(&n);

    // 1) دوال استبدلها المود في اللعبة والنظام
    [out appendString:@"== HOOKED BY SHARKMOD ==\n"];
    for (unsigned i = 0; i < n && lines < 250; i++) {
        Class c = list[i];
        const char *img = class_getImageName(c);
        if (img && strcasestr(img, "shark")) continue;        // أصناف المود نفسه ليست هوكات
        const char *cn = class_getName(c);
        for (int meta = 0; meta < 2; meta++) {
            Class k = meta ? object_getClass(c) : c;
            unsigned mc = 0;
            Method *ms = class_copyMethodList(k, &mc);
            for (unsigned j = 0; j < mc && lines < 250; j++) {
                SEL sel = method_getName(ms[j]);
                IMP imp = method_getImplementation(ms[j]);
                NSValue *ov = meta ? nil : hookOrig[[NSString stringWithFormat:@"%s %s", cn, sel_getName(sel)]];
                if (ov) imp = (IMP)[ov pointerValue];          // نتجاوز هوكاتنا لنرى هوك المود
                Dl_info di;
                if (dladdr((void *)imp, &di) && di.dli_fname && strcasestr(di.dli_fname, "shark")) {
                    [out appendFormat:@"%c[%s %s] %s\n", meta ? '+' : '-', cn, sel_getName(sel),
                     method_getTypeEncoding(ms[j]) ?: ""];
                    lines++;
                }
            }
            free(ms);
        }
    }

    // 2) أصناف المود نفسه
    [out appendString:@"\n== SHARKMOD CLASSES ==\n"];
    int total = lines;
    for (unsigned i = 0; i < n && total < 650; i++) {
        Class c = list[i];
        const char *img = class_getImageName(c);
        if (!img || !strcasestr(img, "shark")) continue;
        const char *cn = class_getName(c);
        if (bad(cn)) continue;
        Class sup = class_getSuperclass(c);
        [out appendFormat:@"class %s : %s\n", cn, sup ? class_getName(sup) : "-"];
        total++;
        for (int meta = 0; meta < 2; meta++) {
            unsigned mc = 0;
            Method *ms = class_copyMethodList(meta ? object_getClass(c) : c, &mc);
            for (unsigned j = 0; j < mc && total < 650; j++) {
                const char *sel = sel_getName(method_getName(ms[j]));
                if (bad(sel)) continue;
                [out appendFormat:@"  %c%s %s\n", meta ? '+' : '-', sel, method_getTypeEncoding(ms[j]) ?: ""];
                total++;
            }
            free(ms);
        }
        unsigned ic = 0;
        Ivar *iv = class_copyIvarList(c, &ic);
        for (unsigned j = 0; j < ic && total < 650; j++) {
            const char *nm = ivar_getName(iv[j]);
            if (bad(nm)) continue;
            [out appendFormat:@"  ivar %s %s\n", nm, ivar_getTypeEncoding(iv[j]) ?: ""];
            total++;
        }
        free(iv);
    }
    free(list);
    UIPasteboard.generalPasteboard.string = out;
    modLabel.text = [NSString stringWithFormat:@"SharkMod scan: %d سطر منسوخ للحافظة", total];
}

@interface ACUI (Mod)
+ (void)scanMod:(UIButton *)b;
+ (void)tick:(CADisplayLink *)l;
+ (void)sw:(UISwitch *)s;
+ (void)fabDown:(UIButton *)b;
+ (void)fabUp:(UIButton *)b;
+ (void)menuTap:(UITapGestureRecognizer *)g;
+ (void)panParent:(UIPanGestureRecognizer *)g;
@end

@implementation ACUI (Mod)
+ (void)scanMod:(UIButton *)b { scanMod(); }
+ (void)tick:(CADisplayLink *)l {
    @try {
        if (zoomBtnOn && zoomDir != 0) {
            float f = 1.0f + zoomDir * (0.004f + (float)zoomSpeed / 100.0f * 0.03f);
            if (zStatic) zStaticVal = fminf(fmaxf(zStaticVal * f, 0.005f), 50.0f);
            else zMul = fminf(fmaxf(zMul * f, 0.02f), 5.0f);
        }
        id v = arenaView;
        if (v) applyZoom(v);
        id st = arenaState;
        if (st && macroOn && macroHeld) {
            macroAcc += macroSpeed / 10.0;                 // سرعة 0..100 → 0..10 تغذية/إطار
            int n = (int)macroAcc;
            macroAcc -= n;
            ourCall = YES;
            for (int i = 0; i < n && i < 12; i++) [st onShoot];
            ourCall = NO;
        }
    } @catch (NSException *e) { ourCall = NO; }
}
+ (void)sw:(UISwitch *)s {
    switch (s.tag) {
        case 1: macroOn = s.on; fabMacro.hidden = !s.on; if (!s.on) macroHeld = NO; break;
        case 2: softOn = s.on; break;
        case 3: splitOn = s.on; for (UIButton *b in fabSplits) b.hidden = !s.on; break;
        case 4:
            zoomBtnOn = s.on; fabZoomUp.hidden = fabZoomDown.hidden = !s.on;
            if (!s.on) { zoomDir = 0; zMul = 1.0f; }
            break;
        case 5: {
            float *cs = camScale(arenaView);
            if (s.on && !cs) { s.on = NO; zStatic = NO; modLabel.text = @"ادخل مباراة أولاً ثم فعّل Static"; return; }
            zStatic = s.on;
            if (zStatic) zStaticVal = cs[0];
            break;
        }
        case 6: fps120 = s.on; fpsInfo = applyFPS(s.on); break;
        case 7:
            editBtns = s.on;
            for (UIButton *b in allFabs) {
                b.layer.borderWidth = editBtns ? 2 : 0;
                b.layer.borderColor = UIColor.whiteColor.CGColor;
            }
            break;
    }
    refreshModStatus();
}
+ (void)fabDown:(UIButton *)b {
    if (editBtns) return;
    if (b.tag == 1000) { macroHeld = YES; b.alpha = 0.55; }
    else if (b.tag == 1001) zoomDir = 1;
    else if (b.tag == 1002) zoomDir = -1;
    else if (b.tag >= 1012 && b.tag <= 1015) doSplit((int)b.tag - 1010);
}
+ (void)fabUp:(UIButton *)b {
    if (b.tag == 1000) { macroHeld = NO; b.alpha = 1.0; }
    else if (b.tag == 1001 || b.tag == 1002) zoomDir = 0;
}
+ (void)menuTap:(UITapGestureRecognizer *)g {
    BOOL show = modPanel.hidden;
    modPanel.hidden = !show;
    panel.hidden = !show;
}
+ (void)panParent:(UIPanGestureRecognizer *)g {
    UIView *v = g.view.superview;
    CGPoint d = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static void modSlide(UISlider *s) {
    double v = round(s.value);
    switch (s.tag) {
        case 200: macroSpeed = v; break;
        case 201: softStrength = v; break;
        case 202: splitSpeed = v; break;
        case 203: zoomSpeed = v; break;
    }
    valLabels[@(s.tag)].text = [NSString stringWithFormat:@"%.0f", v];
}

static void mkSwitchRow(UIView *p, NSString *title, CGFloat y, int tag) {
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(10, y, 170, 30)];
    t.text = title; t.textColor = UIColor.whiteColor; t.font = [UIFont boldSystemFontOfSize:14];
    [p addSubview:t];
    UISwitch *sw = [UISwitch new];
    sw.transform = CGAffineTransformMakeScale(0.8, 0.8);
    sw.center = CGPointMake(222, y + 15);
    sw.tag = tag;
    [sw addTarget:ACUI.class action:@selector(sw:) forControlEvents:UIControlEventValueChanged];
    [p addSubview:sw];
}

static void mkSlider(UIView *p, NSString *title, CGFloat y, double v, int tag) {
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(22, y, 70, 30)];
    t.text = title; t.textColor = [UIColor colorWithWhite:0.8 alpha:1]; t.font = [UIFont systemFontOfSize:12];
    [p addSubview:t];
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(94, y, 120, 30)];
    s.minimumValue = 0; s.maximumValue = 100; s.value = v; s.tag = tag;
    [s addTarget:ACUI.class action:@selector(slide:) forControlEvents:UIControlEventValueChanged];
    [p addSubview:s];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(218, y, 40, 30)];
    l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:12];
    l.text = [NSString stringWithFormat:@"%.0f", v];
    [p addSubview:l];
    valLabels[@(tag)] = l;
}

static UIButton *mkFab(UIWindow *w, NSString *t, CGPoint c, UIColor *col, NSInteger tag) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, 58, 58);
    b.center = c;
    b.backgroundColor = [col colorWithAlphaComponent:0.8];
    b.layer.cornerRadius = 29;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.tag = tag;
    b.hidden = YES;
    [b addTarget:ACUI.class action:@selector(fabDown:) forControlEvents:UIControlEventTouchDown];
    [b addTarget:ACUI.class action:@selector(fabUp:)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    UIPanGestureRecognizer *pg = [[UIPanGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(pan:)];
    pg.delegate = acDelegate;
    [b addGestureRecognizer:pg];
    [w addSubview:b];
    [allFabs addObject:b];
    return b;
}

static void buildModPanel(UIWindow *w) {
    valLabels = [NSMutableDictionary new];
    allFabs = [NSMutableArray new];
    fabSplits = [NSMutableArray new];
    CGFloat W = w.bounds.size.width, H = w.bounds.size.height;

    // الأزرار العائمة (تظهر عند تفعيل خيارها)
    fabMacro = mkFab(w, @"Macro", CGPointMake(W * 0.86, H * 0.55), UIColor.systemRedColor, 1000);
    fabZoomUp = mkFab(w, @"▲", CGPointMake(W * 0.93, H * 0.25), UIColor.systemBlueColor, 1001);
    fabZoomDown = mkFab(w, @"▼", CGPointMake(W * 0.93, H * 0.38), UIColor.systemBlueColor, 1002);
    for (int n = 2; n <= 5; n++) {
        UIButton *b = mkFab(w, [NSString stringWithFormat:@"%dx", n],
                            CGPointMake(W * 0.74, H * (0.22 + 0.13 * (n - 2))),
                            UIColor.systemPurpleColor, 1010 + n);
        [fabSplits addObject:b];
    }

    // القائمة
    CGFloat bodyH = MIN(414, H - 150);
    modPanel = [[UIView alloc] initWithFrame:CGRectMake(290, 60, 262, 40 + bodyH)];
    modPanel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    modPanel.layer.cornerRadius = 12;

    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 262, 40)];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, 200, 30)];
    title.text = @"MOD  (اسحب من هنا)"; title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:14];
    [hdr addSubview:title];
    UIPanGestureRecognizer *hp = [[UIPanGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(panParent:)];
    [hdr addGestureRecognizer:hp];
    [modPanel addSubview:hdr];

    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 40, 262, bodyH)];
    sc.contentSize = CGSizeMake(262, 470);
    sc.delaysContentTouches = NO;
    [modPanel addSubview:sc];

    mkSwitchRow(sc, @"Macro", 0, 1);
    mkSlider(sc, @"Speed", 32, macroSpeed, 200);
    mkSwitchRow(sc, @"Soft Macro (زر اللعبة)", 66, 2);
    mkSlider(sc, @"Strength", 98, softStrength, 201);
    mkSwitchRow(sc, @"Splits", 132, 3);
    mkSlider(sc, @"Speed", 164, splitSpeed, 202);
    mkSwitchRow(sc, @"Zoom Buttons", 198, 4);
    mkSlider(sc, @"Zoom speed", 230, zoomSpeed, 203);
    mkSwitchRow(sc, @"Static Zoom", 264, 5);
    mkSwitchRow(sc, @"120 FPS", 298, 6);
    mkSwitchRow(sc, @"Move buttons", 332, 7);

    modLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 368, 244, 44)];
    modLabel.textColor = UIColor.yellowColor; modLabel.font = [UIFont systemFontOfSize:11];
    modLabel.numberOfLines = 3;
    [sc addSubview:modLabel];

    UIButton *b1 = [UIButton buttonWithType:UIButtonTypeSystem];
    b1.frame = CGRectMake(10, 420, 118, 34);
    b1.backgroundColor = UIColor.systemOrangeColor; b1.layer.cornerRadius = 8;
    [b1 setTitle:@"Scan game" forState:UIControlStateNormal];
    [b1 setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b1 addTarget:ACUI.class action:@selector(scan:) forControlEvents:UIControlEventTouchUpInside];
    [sc addSubview:b1];
    UIButton *b2 = [UIButton buttonWithType:UIButtonTypeSystem];
    b2.frame = CGRectMake(136, 420, 118, 34);
    b2.backgroundColor = UIColor.systemTealColor; b2.layer.cornerRadius = 8;
    [b2 setTitle:@"Scan SharkMod" forState:UIControlStateNormal];
    [b2 setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b2 addTarget:ACUI.class action:@selector(scanMod:) forControlEvents:UIControlEventTouchUpInside];
    [sc addSubview:b2];
    [w addSubview:modPanel];

    // زر القائمة ☰ (اضغط لإظهار/إخفاء اللوحات، واسحبه لتحريكه)
    UILabel *mb = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, 40, 40)];
    mb.text = @"☰"; mb.textAlignment = NSTextAlignmentCenter; mb.textColor = UIColor.whiteColor;
    mb.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    mb.layer.cornerRadius = 20; mb.clipsToBounds = YES; mb.font = [UIFont systemFontOfSize:20];
    mb.userInteractionEnabled = YES;
    [mb addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(menuTap:)]];
    UIPanGestureRecognizer *mp = [[UIPanGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(pan:)];
    mp.delegate = acDelegate;
    [mb addGestureRecognizer:mp];
    [w addSubview:mb];
    menuBtn = mb;

    frameLink = [CADisplayLink displayLinkWithTarget:ACUI.class selector:@selector(tick:)];
    [frameLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { refreshModStatus(); }];
    refreshModStatus();
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
