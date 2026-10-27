#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

static __weak UIView *cachedGL;
static id acDelegate;
static BOOL editBtns = NO;
static double btnSize = 100, btnAlpha = 85;     // حجم وشفافية الأزرار العائمة
static void saveFabPos(UIView *v);
static CFTimeInterval msgHold = 0;     // لا يكتب المؤقت فوق رسالة مهمة قبل هذا الوقت
static NSMutableDictionary<NSString *, NSValue *> *hookOrig;   // الدوال الأصلية قبل هوكاتنا
static void recordOrig(Class c, SEL sel, IMP orig) {
    if (!hookOrig) hookOrig = [NSMutableDictionary new];
    hookOrig[[NSString stringWithFormat:@"%s %s", class_getName(c), sel_getName(sel)]] =
        [NSValue valueWithPointer:(const void *)orig];
}
static void installHooks(void);
static void buildModPanel(UIWindow *w);
static void modSlide(UISlider *s);

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

// ---------- الواجهة ----------
@interface ACUI : NSObject <UIGestureRecognizerDelegate, UITextFieldDelegate>
+ (void)slide:(UISlider *)s;
+ (void)pan:(UIPanGestureRecognizer *)g;
@end

@implementation ACUI
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    if (g.view.tag >= 1000) return editBtns;
    return ![t.view isKindOfClass:UIControl.class];
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
+ (void)slide:(UISlider *)s { modSlide(s); }
+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint d = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [g setTranslation:CGPointZero inView:v.superview];
    if (g.state == UIGestureRecognizerStateEnded && v.tag >= 1000) saveFabPos(v);
}
@end

static void buildUI(UIWindow *w) {
    acDelegate = [ACUI new];
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
    if (CACurrentMediaTime() < msgHold) return;
    id st = arenaState, v = arenaView;
    float *cs = camScale(v);
    modLabel.text = [NSString stringWithFormat:@"arena:%@ view:%@\ncam:%.3f base:%.3f z:%.2f %@",
        st ? NSStringFromClass([st class]) : @"-", v ? @"ok" : @"-",
        cs ? cs[0] : 0.0f, zBase, zStatic ? zStaticVal : zMul, fpsInfo];
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
    msgHold = CACurrentMediaTime() + 15;
    modLabel.text = [NSString stringWithFormat:@"Scan: %d سطر منسوخ للحافظة", lines];
}

// ---------- تحليل SharkMod: خريطة الهوكات + أصناف المود (بدون البوتات/الحساب) ----------
static void scanModWork(void) {
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
                Dl_info di;
                BOOL hit = NO;
                if (dladdr((void *)imp, &di) && di.dli_fname) {
                    if (strcasestr(di.dli_fname, "shark")) hit = YES;
                    else if (!meta && strcasestr(di.dli_fname, "AutoClick")) {   // هوكنا: نفحص الدالة قبل هوكنا
                        NSValue *ov = hookOrig[[NSString stringWithFormat:@"%s %s", cn, sel_getName(sel)]];
                        Dl_info d2;
                        if (ov && dladdr((void *)[ov pointerValue], &d2) && d2.dli_fname &&
                            strcasestr(d2.dli_fname, "shark")) hit = YES;
                    }
                }
                if (hit) {
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
        if (!strncmp(cn, "GPB", 3) || strstr(cn, "Protobuf")) continue;   // مكتبة Protobuf: ضجيج
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
    NSString *res = [out copy];
    int tcount = total;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIPasteboard.generalPasteboard.string = res;
        msgHold = CACurrentMediaTime() + 15;
        modLabel.text = [NSString stringWithFormat:@"SharkMod scan: %d سطر منسوخ للحافظة", tcount];
    });
}

static void scanMod(void) {
    msgHold = CACurrentMediaTime() + 300;
    modLabel.text = @"جاري تحليل SharkMod... انتظر";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ scanModWork(); });
}

@interface ACUI (Mod)
+ (void)scanMod:(UIButton *)b;
+ (void)scan:(UIButton *)b;
+ (void)iconChanged:(UITextField *)f;
+ (void)tick:(CADisplayLink *)l;
+ (void)sw:(UISwitch *)s;
+ (void)fabDown:(UIButton *)b;
+ (void)fabUp:(UIButton *)b;
+ (void)menuTap:(UITapGestureRecognizer *)g;
+ (void)panParent:(UIPanGestureRecognizer *)g;
@end

@implementation ACUI (Mod)
+ (void)scanMod:(UIButton *)b { scanMod(); }
+ (void)scan:(UIButton *)b { scanGame(); }
+ (void)iconChanged:(UITextField *)f {
    if (!f.text.length) return;
    NSRange r = [f.text rangeOfComposedCharacterSequenceAtIndex:0];     // أول رمز كامل (إيموجي)
    NSString *e = [f.text substringWithRange:r];
    ((UILabel *)menuBtn).text = e;
    [NSUserDefaults.standardUserDefaults setObject:e forKey:@"ac_icon"];
}
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
    if (s.tag != 5 && s.tag != 7)
        [NSUserDefaults.standardUserDefaults setBool:s.on forKey:[NSString stringWithFormat:@"ac_sw%ld", (long)s.tag]];
    refreshModStatus();
}
+ (void)fabDown:(UIButton *)b {
    if (editBtns) return;
    if (b.tag == 1000) { macroHeld = YES; b.alpha = 0.6 * btnAlpha / 100.0; }
    else if (b.tag == 1001) zoomDir = 1;
    else if (b.tag == 1002) zoomDir = -1;
    else if (b.tag >= 1012 && b.tag <= 1015) doSplit((int)b.tag - 1010);
}
+ (void)fabUp:(UIButton *)b {
    if (b.tag == 1000) { macroHeld = NO; b.alpha = btnAlpha / 100.0; }
    else if (b.tag == 1001 || b.tag == 1002) zoomDir = 0;
}
+ (void)menuTap:(UITapGestureRecognizer *)g {
    BOOL show = modPanel.hidden;
    modPanel.hidden = !show;
}
+ (void)panParent:(UIPanGestureRecognizer *)g {
    UIView *v = g.view.superview;
    CGPoint d = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static void applyFabStyle(void) {
    for (UIButton *b in allFabs) {
        b.transform = CGAffineTransformMakeScale(btnSize / 100.0, btnSize / 100.0);
        b.alpha = btnAlpha / 100.0;
    }
}

static void modSlide(UISlider *s) {
    double v = round(s.value);
    switch (s.tag) {
        case 200: macroSpeed = v; break;
        case 201: softStrength = v; break;
        case 202: splitSpeed = v; break;
        case 203: zoomSpeed = v; break;
        case 204: btnSize = v; applyFabStyle(); break;
        case 205: btnAlpha = v; applyFabStyle(); break;
    }
    [NSUserDefaults.standardUserDefaults setDouble:v forKey:[NSString stringWithFormat:@"ac_sl%ld", (long)s.tag]];
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

static void mkSlider(UIView *p, NSString *title, CGFloat y, double mn, double mx, double v, int tag) {
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(22, y, 70, 30)];
    t.text = title; t.textColor = [UIColor colorWithWhite:0.8 alpha:1]; t.font = [UIFont systemFontOfSize:12];
    [p addSubview:t];
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(94, y, 120, 30)];
    s.minimumValue = mn; s.maximumValue = mx; s.value = v; s.tag = tag;
    [s addTarget:ACUI.class action:@selector(slide:) forControlEvents:UIControlEventValueChanged];
    [p addSubview:s];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(218, y, 40, 30)];
    l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:12];
    l.text = [NSString stringWithFormat:@"%.0f", v];
    [p addSubview:l];
    valLabels[@(tag)] = l;
}

static void saveFabPos(UIView *v) {
    UIView *p = v.superview;
    if (!p) return;
    CGSize sz = p.bounds.size;
    [NSUserDefaults.standardUserDefaults setObject:@[@(v.center.x / sz.width), @(v.center.y / sz.height)]
                                            forKey:[NSString stringWithFormat:@"ac_fab%ld", (long)v.tag]];
}
static void loadFabPos(UIView *v, UIView *p) {
    NSArray *a = [NSUserDefaults.standardUserDefaults arrayForKey:[NSString stringWithFormat:@"ac_fab%ld", (long)v.tag]];
    if (a.count == 2) {
        CGSize sz = p.bounds.size;
        v.center = CGPointMake([a[0] doubleValue] * sz.width, [a[1] doubleValue] * sz.height);
    }
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
    loadFabPos(b, w);
    return b;
}

static void buildModPanel(UIWindow *w) {
    valLabels = [NSMutableDictionary new];
    allFabs = [NSMutableArray new];
    fabSplits = [NSMutableArray new];
    CGFloat W = w.bounds.size.width, H = w.bounds.size.height;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    if ([ud objectForKey:@"ac_sl200"]) macroSpeed = [ud doubleForKey:@"ac_sl200"];
    if ([ud objectForKey:@"ac_sl201"]) softStrength = [ud doubleForKey:@"ac_sl201"];
    if ([ud objectForKey:@"ac_sl202"]) splitSpeed = [ud doubleForKey:@"ac_sl202"];
    if ([ud objectForKey:@"ac_sl203"]) zoomSpeed = [ud doubleForKey:@"ac_sl203"];
    if ([ud objectForKey:@"ac_sl204"]) btnSize = [ud doubleForKey:@"ac_sl204"];
    if ([ud objectForKey:@"ac_sl205"]) btnAlpha = [ud doubleForKey:@"ac_sl205"];

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
    modPanel = [[UIView alloc] initWithFrame:CGRectMake(10, 58, 262, 40 + bodyH)];
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
    sc.contentSize = CGSizeMake(262, 566);
    sc.delaysContentTouches = NO;
    [modPanel addSubview:sc];

    mkSwitchRow(sc, @"Macro", 0, 1);
    mkSlider(sc, @"Speed", 32, 0, 100, macroSpeed, 200);
    mkSwitchRow(sc, @"Soft Macro (زر اللعبة)", 66, 2);
    mkSlider(sc, @"Strength", 98, 0, 100, softStrength, 201);
    mkSwitchRow(sc, @"Splits", 132, 3);
    mkSlider(sc, @"Speed", 164, 0, 100, splitSpeed, 202);
    mkSwitchRow(sc, @"Zoom Buttons", 198, 4);
    mkSlider(sc, @"Zoom", 230, 0, 100, zoomSpeed, 203);
    mkSwitchRow(sc, @"Static Zoom", 264, 5);
    mkSwitchRow(sc, @"120 FPS", 298, 6);
    mkSwitchRow(sc, @"Move buttons", 332, 7);
    mkSlider(sc, @"Btn size", 366, 50, 150, btnSize, 204);
    mkSlider(sc, @"Btn alpha", 398, 20, 100, btnAlpha, 205);

    UILabel *il = [[UILabel alloc] initWithFrame:CGRectMake(22, 430, 70, 30)];
    il.text = @"Icon"; il.textColor = [UIColor colorWithWhite:0.8 alpha:1]; il.font = [UIFont systemFontOfSize:12];
    [sc addSubview:il];
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(94, 430, 120, 30)];
    tf.text = ([ud stringForKey:@"ac_icon"].length ? [ud stringForKey:@"ac_icon"] : @"💐");
    tf.textAlignment = NSTextAlignmentCenter; tf.font = [UIFont systemFontOfSize:20];
    tf.textColor = UIColor.whiteColor; tf.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    tf.layer.cornerRadius = 6; tf.returnKeyType = UIReturnKeyDone; tf.delegate = acDelegate;
    [tf addTarget:ACUI.class action:@selector(iconChanged:) forControlEvents:UIControlEventEditingChanged];
    [sc addSubview:tf];

    modLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 466, 244, 44)];
    modLabel.textColor = UIColor.yellowColor; modLabel.font = [UIFont systemFontOfSize:11];
    modLabel.numberOfLines = 3;
    [sc addSubview:modLabel];

    UIButton *b1 = [UIButton buttonWithType:UIButtonTypeSystem];
    b1.frame = CGRectMake(10, 518, 118, 34);
    b1.backgroundColor = UIColor.systemOrangeColor; b1.layer.cornerRadius = 8;
    [b1 setTitle:@"Scan game" forState:UIControlStateNormal];
    [b1 setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b1 addTarget:ACUI.class action:@selector(scan:) forControlEvents:UIControlEventTouchUpInside];
    [sc addSubview:b1];
    UIButton *b2 = [UIButton buttonWithType:UIButtonTypeSystem];
    b2.frame = CGRectMake(136, 518, 118, 34);
    b2.backgroundColor = UIColor.systemTealColor; b2.layer.cornerRadius = 8;
    [b2 setTitle:@"Scan SharkMod" forState:UIControlStateNormal];
    [b2 setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b2 addTarget:ACUI.class action:@selector(scanMod:) forControlEvents:UIControlEventTouchUpInside];
    [sc addSubview:b2];
    [w addSubview:modPanel];

    // زر القائمة ☰ (اضغط لإظهار/إخفاء اللوحات، واسحبه لتحريكه)
    UILabel *mb = [[UILabel alloc] initWithFrame:CGRectMake(10, 6, 46, 46)];
    NSString *ic = [ud stringForKey:@"ac_icon"];
    mb.text = ic.length ? ic : @"💐";
    mb.textAlignment = NSTextAlignmentCenter;
    mb.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    mb.layer.cornerRadius = 23; mb.clipsToBounds = YES; mb.font = [UIFont systemFontOfSize:28];
    mb.userInteractionEnabled = YES;
    [mb addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(menuTap:)]];
    UIPanGestureRecognizer *mp = [[UIPanGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(pan:)];
    mp.delegate = acDelegate;
    [mb addGestureRecognizer:mp];
    [w addSubview:mb];
    menuBtn = mb;

    // استرجاع المفاتيح المحفوظة (Static Zoom وMove buttons لا تُحفظ)
    for (NSNumber *t in @[@1, @2, @3, @4, @6]) {
        if (![ud boolForKey:[NSString stringWithFormat:@"ac_sw%d", t.intValue]]) continue;
        UISwitch *sw = (UISwitch *)[sc viewWithTag:t.intValue];
        if ([sw isKindOfClass:UISwitch.class]) { sw.on = YES; [ACUI sw:sw]; }
    }
    applyFabStyle();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (fps120) fpsInfo = applyFPS(YES);      // اللعبة قد تعيد ضبط المؤقت بعد البدء
    });

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
