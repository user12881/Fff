#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define NL 4    // عدد اللوبيات

static __weak UIView *cachedGL;
static UIView *panelV;
static UILabel *iconV, *statusL;
static NSMutableArray<UIButton *> *radios;
static int selLobby = 0;
static BOOL tracing = NO;
static NSMutableArray<NSString *> *netLog;

// ---------- إيجاد عرض اللعبة ----------
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

// ---------- سكانر الشبكة: أصناف المناطق والسيرفرات والاتصال ----------
static BOOL isVendor(const char *n) {
    static NSArray *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = @[@"FB", @"GAD", @"MTG", @"PAG", @"IS", @"LPM", @"IA", @"FMP", @"STK", @"OMID",
              @"SS", @"AL", @"BF", @"Bid", @"Vungle", @"Unity", @"IronSource", @"DTX", @"NS",
              @"CF", @"UI", @"GPB", @"FIR", @"GUL", @"GDT", @"Swift", @"_Tt", @"OS_", @"WK",
              @"AV", @"CA", @"CL", @"SK", @"GC", @"Helpers_"];
    });
    NSString *x = [NSString stringWithUTF8String:n];
    for (NSString *k in p) if ([x hasPrefix:k]) return YES;
    return NO;
}

static void scanNetWork(void) {
    NSArray *keys = @[@"Region", @"EndPoint", @"Endpoint", @"Connection", @"Socket", @"Server",
                      @"Host", @"Lobby", @"Matchmak", @"Network", @"Party", @"Room"];
    NSMutableString *out = [NSMutableString new];
    int lines = 0;
    unsigned n = 0;
    Class *list = objc_copyClassList(&n);
    for (unsigned i = 0; i < n && lines < 700; i++) {
        Class c = list[i];
        const char *cn = class_getName(c);
        if (isVendor(cn)) continue;
        NSString *nm = [NSString stringWithUTF8String:cn];
        BOOL match = NO;
        for (NSString *k in keys)
            if ([nm rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) { match = YES; break; }
        if (!match) continue;
        const char *img = class_getImageName(c);
        if (!img || !strstr(img, ".app/")) continue;            // ملف اللعبة والدايلبات المحقونة فقط
        const char *base = strrchr(img, '/');
        Class sup = class_getSuperclass(c);
        [out appendFormat:@"class %s : %s  [%s]\n", cn, sup ? class_getName(sup) : "-", base ? base + 1 : img];
        lines++;
        BOOL ownerIsShark = strcasestr(img, "shark") != NULL;
        for (int meta = 0; meta < 2; meta++) {
            unsigned mc = 0;
            Method *ms = class_copyMethodList(meta ? object_getClass(c) : c, &mc);
            for (unsigned j = 0; j < mc && lines < 700; j++) {
                Dl_info di;
                BOOL hooked = !ownerIsShark && dladdr((void *)method_getImplementation(ms[j]), &di) &&
                              di.dli_fname && strcasestr(di.dli_fname, "shark");
                [out appendFormat:@"  %c%s %s%s\n", meta ? '+' : '-', sel_getName(method_getName(ms[j])),
                 method_getTypeEncoding(ms[j]) ?: "", hooked ? "   *HOOKED*" : ""];
                lines++;
            }
            free(ms);
        }
        unsigned ic = 0;
        Ivar *iv = class_copyIvarList(c, &ic);
        for (unsigned j = 0; j < ic && lines < 700; j++) {
            [out appendFormat:@"  ivar %s %s\n", ivar_getName(iv[j]), ivar_getTypeEncoding(iv[j]) ?: ""];
            lines++;
        }
        free(iv);
    }
    free(list);
    NSString *res = [out copy];
    int cnt = lines;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIPasteboard.generalPasteboard.string = res;
        statusL.text = [NSString stringWithFormat:@"Scan net: %d سطر منسوخ للحافظة", cnt];
    });
}

// ---------- تتبع الاتصالات (مضيف/منفذ/مسار فقط، بدون أي بيانات أو مفاتيح) ----------
static BOOL ownsMethod(Class c, SEL sel) {
    unsigned n = 0;
    Method *ml = class_copyMethodList(c, &n);
    BOOL own = NO;
    for (unsigned i = 0; i < n; i++) if (method_getName(ml[i]) == sel) { own = YES; break; }
    free(ml);
    return own;
}

static void logNet(NSString *s) {
    if (!tracing || !netLog) return;
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss.SSS"; });
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [df stringFromDate:NSDate.date], s];
    @synchronized (netLog) {
        if (netLog.count >= 400) [netLog removeObjectAtIndex:0];
        [netLog addObject:line];
    }
}

static NSString *safeURL(NSURL *u) {      // بدون query ولا fragment ولا بيانات دخول
    if (!u) return @"?";
    return [NSString stringWithFormat:@"%@://%@%@%@", u.scheme ?: @"?", u.host ?: @"?",
            u.port ? [NSString stringWithFormat:@":%@", u.port] : @"", u.path ?: @""];
}

static void installNetHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        netLog = [NSMutableArray new];

        Method m1 = class_getInstanceMethod(NSURLSession.class, @selector(dataTaskWithRequest:completionHandler:));
        if (m1) {
            IMP o1 = method_getImplementation(m1);
            SEL s1 = @selector(dataTaskWithRequest:completionHandler:);
            method_setImplementation(m1, imp_implementationWithBlock(^id(id me, NSURLRequest *r, id h) {
                logNet([NSString stringWithFormat:@"HTTP %@ %@", r.HTTPMethod ?: @"GET", safeURL(r.URL)]);
                return ((id (*)(id, SEL, id, id))o1)(me, s1, r, h);
            }));
        }
        Method m2 = class_getInstanceMethod(NSURLSession.class, @selector(dataTaskWithURL:completionHandler:));
        if (m2) {
            IMP o2 = method_getImplementation(m2);
            SEL s2 = @selector(dataTaskWithURL:completionHandler:);
            method_setImplementation(m2, imp_implementationWithBlock(^id(id me, NSURL *u, id h) {
                logNet([NSString stringWithFormat:@"HTTP GET %@", safeURL(u)]);
                return ((id (*)(id, SEL, id, id))o2)(me, s2, u, h);
            }));
        }

        Class tc = NSClassFromString(@"TCPSocketClient");
        SEL t1 = NSSelectorFromString(@"connectToHost:port:error:");
        if (tc && ownsMethod(tc, t1)) {
            IMP o = method_getImplementation(class_getInstanceMethod(tc, t1));
            method_setImplementation(class_getInstanceMethod(tc, t1),
                imp_implementationWithBlock(^BOOL(id me, NSString *h, NSInteger p, NSError *__autoreleasing *e) {
                    logNet([NSString stringWithFormat:@"TCP %@:%ld", h, (long)p]);
                    return ((BOOL (*)(id, SEL, id, NSInteger, NSError *__autoreleasing *))o)(me, t1, h, p, e);
                }));
        }
        SEL t2 = NSSelectorFromString(@"connectToHost:port:timeout:error:");
        if (tc && ownsMethod(tc, t2)) {
            IMP o = method_getImplementation(class_getInstanceMethod(tc, t2));
            method_setImplementation(class_getInstanceMethod(tc, t2),
                imp_implementationWithBlock(^BOOL(id me, NSString *h, NSInteger p, double to, NSError *__autoreleasing *e) {
                    logNet([NSString stringWithFormat:@"TCP %@:%ld", h, (long)p]);
                    return ((BOOL (*)(id, SEL, id, NSInteger, double, NSError *__autoreleasing *))o)(me, t2, h, p, to, e);
                }));
        }

        // علامات: ضغط زر Classic / Burst
        Class mm = NSClassFromString(@"MenuMain");
        for (NSString *nm in @[@"playButtonCallback", @"burstPlayButtonCallback"]) {
            SEL sel = NSSelectorFromString(nm);
            if (!mm || !ownsMethod(mm, sel)) continue;
            IMP o = method_getImplementation(class_getInstanceMethod(mm, sel));
            NSString *tag = [nm hasPrefix:@"burst"] ? @"PLAY BURST" : @"PLAY CLASSIC";
            method_setImplementation(class_getInstanceMethod(mm, sel), imp_implementationWithBlock(^(id me) {
                logNet(tag);
                ((void (*)(id, SEL))o)(me, sel);
            }));
        }
    });
}

// ---------- الواجهة ----------
static NSUserDefaults *UD(void) { return NSUserDefaults.standardUserDefaults; }

static NSString *lobbyName(int i) {
    NSString *s = [UD() stringForKey:[NSString stringWithFormat:@"lb_%d", 100 + i]];
    if (s) return s;
    return @[@"Classic 1", @"Classic 2", @"Burst 1", @"Burst 2"][i];
}
static NSString *lobbyAddr(int i) {
    return [UD() stringForKey:[NSString stringWithFormat:@"lb_%d", 200 + i]] ?: @"";
}

static void refreshSel(void) {
    for (int i = 0; i < NL; i++) [radios[i] setTitle:(i == selLobby ? @"●" : @"○") forState:UIControlStateNormal];
    NSString *a = lobbyAddr(selLobby);
    statusL.text = [NSString stringWithFormat:@"المحدد: %@\n%@", lobbyName(selLobby), a.length ? a : @"(لم تكتب عنوان بعد)"];
}

@interface ACUI : NSObject <UIGestureRecognizerDelegate, UITextFieldDelegate>
+ (void)menuTap:(UITapGestureRecognizer *)g;
+ (void)pan:(UIPanGestureRecognizer *)g;
+ (void)panParent:(UIPanGestureRecognizer *)g;
+ (void)pick:(UIButton *)b;
+ (void)join:(UIButton *)b;
+ (void)scan:(UIButton *)b;
+ (void)trace:(UIButton *)b;
+ (void)copyLog:(UIButton *)b;
+ (void)fieldChanged:(UITextField *)f;
@end

static id acDelegate;

@implementation ACUI
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return ![t.view isKindOfClass:UIControl.class];
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
+ (void)menuTap:(UITapGestureRecognizer *)g { panelV.hidden = !panelV.hidden; }
+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint d = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
+ (void)panParent:(UIPanGestureRecognizer *)g {
    UIView *v = g.view.superview;
    CGPoint d = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + d.x, v.center.y + d.y);
    [g setTranslation:CGPointZero inView:v.superview];
}
+ (void)pick:(UIButton *)b {
    selLobby = (int)b.tag;
    [UD() setInteger:selLobby forKey:@"lb_sel"];
    refreshSel();
}
+ (void)join:(UIButton *)b {
    NSString *a = lobbyAddr(selLobby);
    if (!a.length) { statusL.text = @"اكتب عنوان اللوبي (ip:port) أولاً"; return; }
    statusL.text = [NSString stringWithFormat:@"تم اختيار %@\n%@\n(الربط باللعبة بعد نتيجة Scan net)", lobbyName(selLobby), a];
}
+ (void)scan:(UIButton *)b {
    statusL.text = @"جاري فحص الشبكة... انتظر";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ scanNetWork(); });
}
+ (void)trace:(UIButton *)b {
    tracing = !tracing;
    [b setTitle:tracing ? @"Trace: ON" : @"Trace: OFF" forState:UIControlStateNormal];
    b.backgroundColor = tracing ? UIColor.systemRedColor : UIColor.systemGrayColor;
    statusL.text = tracing ? @"التتبع شغّال: اضغط Classic أو Burst في اللعبة، ثم أوقفه وانسخ السجل"
                           : @"التتبع متوقف";
}
+ (void)copyLog:(UIButton *)b {
    NSString *all;
    NSUInteger n;
    @synchronized (netLog) { all = [netLog componentsJoinedByString:@"\n"]; n = netLog.count; }
    UIPasteboard.generalPasteboard.string = all;
    statusL.text = [NSString stringWithFormat:@"Log: %lu سطر منسوخ للحافظة", (unsigned long)n];
}
+ (void)fieldChanged:(UITextField *)f {
    [UD() setObject:f.text forKey:[NSString stringWithFormat:@"lb_%ld", (long)f.tag]];
    if (f.tag % 100 == selLobby) refreshSel();
}
@end

static UITextField *mkField(UIView *p, CGRect fr, NSString *ph, NSString *text, NSInteger tag, BOOL url) {
    UITextField *f = [[UITextField alloc] initWithFrame:fr];
    f.placeholder = ph; f.text = text; f.tag = tag;
    f.font = [UIFont systemFontOfSize:13];
    f.textColor = UIColor.whiteColor;
    f.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    f.layer.cornerRadius = 6;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    if (url) f.keyboardType = UIKeyboardTypeURL;
    f.returnKeyType = UIReturnKeyDone;
    f.delegate = acDelegate;
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 6, 1)];
    f.leftView = pad; f.leftViewMode = UITextFieldViewModeAlways;
    [f addTarget:ACUI.class action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [p addSubview:f];
    return f;
}

static UIButton *mkBtn(UIView *p, NSString *t, CGRect f, UIColor *bg, SEL a) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f; b.backgroundColor = bg; b.layer.cornerRadius = 8;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b addTarget:ACUI.class action:a forControlEvents:UIControlEventTouchUpInside];
    [p addSubview:b];
    return b;
}

static void buildUI(UIWindow *w) {
    acDelegate = [ACUI new];
    installNetHooks();
    radios = [NSMutableArray new];
    selLobby = (int)[UD() integerForKey:@"lb_sel"];
    if (selLobby < 0 || selLobby >= NL) selLobby = 0;

    panelV = [[UIView alloc] initWithFrame:CGRectMake(10, 62, 300, 372)];
    panelV.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    panelV.layer.cornerRadius = 12;

    UIView *hdr = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 40)];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, 270, 30)];
    title.text = @"Lobbies  (اسحب من هنا)"; title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:14];
    [hdr addSubview:title];
    UIPanGestureRecognizer *hp = [[UIPanGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(panParent:)];
    [hdr addGestureRecognizer:hp];
    [panelV addSubview:hdr];

    for (int i = 0; i < NL; i++) {
        CGFloat y = 46 + 40 * i;
        UIButton *r = mkBtn(panelV, @"○", CGRectMake(8, y, 34, 34), UIColor.systemBlueColor, @selector(pick:));
        r.tag = i; r.layer.cornerRadius = 17;
        [radios addObject:r];
        mkField(panelV, CGRectMake(48, y, 86, 34), @"Name", lobbyName(i), 100 + i, NO);
        mkField(panelV, CGRectMake(140, y, 152, 34), @"ip:port", lobbyAddr(i), 200 + i, YES);
    }

    statusL = [[UILabel alloc] initWithFrame:CGRectMake(10, 208, 280, 56)];
    statusL.textColor = UIColor.yellowColor; statusL.font = [UIFont systemFontOfSize:12];
    statusL.numberOfLines = 3;
    [panelV addSubview:statusL];

    mkBtn(panelV, @"Join", CGRectMake(10, 272, 136, 38), UIColor.systemGreenColor, @selector(join:));
    mkBtn(panelV, @"Scan net", CGRectMake(154, 272, 136, 38), UIColor.systemTealColor, @selector(scan:));
    UIButton *tb = mkBtn(panelV, @"Trace: OFF", CGRectMake(10, 318, 136, 38), UIColor.systemGrayColor, @selector(trace:));
    tb.titleLabel.font = [UIFont systemFontOfSize:14];
    mkBtn(panelV, @"Copy log", CGRectMake(154, 318, 136, 38), UIColor.systemIndigoColor, @selector(copyLog:));
    [w addSubview:panelV];

    // زر الأيقونة (إيموجي)
    iconV = [[UILabel alloc] initWithFrame:CGRectMake(10, 6, 46, 46)];
    iconV.text = [UD() stringForKey:@"ac_icon"] ?: @"💐";
    iconV.textAlignment = NSTextAlignmentCenter;
    iconV.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    iconV.layer.cornerRadius = 23; iconV.clipsToBounds = YES;
    iconV.font = [UIFont systemFontOfSize:28];
    iconV.userInteractionEnabled = YES;
    [iconV addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(menuTap:)]];
    UIPanGestureRecognizer *mp = [[UIPanGestureRecognizer alloc] initWithTarget:ACUI.class action:@selector(pan:)];
    mp.delegate = acDelegate;
    [iconV addGestureRecognizer:mp];
    [w addSubview:iconV];

    refreshSel();
}

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
