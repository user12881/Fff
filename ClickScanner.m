// ClickScanner.m
// يسجّل النقرات + طلبات واستجابات NSURLSession و NSURLConnection.
// متوافق مع Theos (ضعه في AutoClick_FILES داخل Makefile).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define MAX_BODY 2000

#pragma mark - Logging

static NSString *LogPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"click_scanner.log"];
}

static void ClickLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    NSLog(@"[ClickScanner] %@", msg);

    NSString *path = LogPath();
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static NSString *BodyString(NSData *d) {
    if (!d.length) return @"<empty>";
    NSData *part = d.length > MAX_BODY ? [d subdataWithRange:NSMakeRange(0, MAX_BODY)] : d;
    NSString *s = [[NSString alloc] initWithData:part encoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"(%lu bytes) %@", (unsigned long)d.length,
            s ?: @"<binary>"];
}

static void LogRequest(NSURLRequest *req, NSString *tag) {
    if (!req) return;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"[%@] %@ %@", tag, req.HTTPMethod ?: @"GET", req.URL.absoluteString];
    if (req.allHTTPHeaderFields.count)
        [s appendFormat:@"\n  Headers: %@", req.allHTTPHeaderFields];
    if (req.HTTPBody.length)
        [s appendFormat:@"\n  Body %@", BodyString(req.HTTPBody)];
    else if (req.HTTPBodyStream)
        [s appendString:@"\n  Body: <stream>"];
    ClickLog(@"%@", s);
}

static void LogResponse(NSURL *url, NSData *data, NSURLResponse *resp, NSError *err) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"[RESP] %@", url.absoluteString];
    if ([resp isKindOfClass:[NSHTTPURLResponse class]])
        [s appendFormat:@" -> %ld", (long)((NSHTTPURLResponse *)resp).statusCode];
    if (err) [s appendFormat:@"\n  Error: %@", err.localizedDescription];
    if (data.length) [s appendFormat:@"\n  Body %@", BodyString(data)];
    ClickLog(@"%@", s);
}

#pragma mark - Hook: النقرات

static void HookTouches(void) {
    Method m = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
    if (!m) return;
    IMP orig = method_getImplementation(m);

    method_setImplementation(m, imp_implementationWithBlock(^(UIApplication *app, UIEvent *event) {
        if (event.type == UIEventTypeTouches) {
            for (UITouch *t in event.allTouches) {
                if (t.phase == UITouchPhaseEnded) {
                    CGPoint p = [t locationInView:nil];
                    ClickLog(@"[TAP] (%.0f, %.0f) view=%@", p.x, p.y, NSStringFromClass([t.view class]));
                }
            }
        }
        ((void (*)(id, SEL, UIEvent *))orig)(app, @selector(sendEvent:), event);
    }));
}

#pragma mark - Hook: NSURLSession (الطلبات)

static NSMutableSet *gHooked;

static void HookResume(Class cls) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(resume));
    if (!m) return;

    IMP orig = method_getImplementation(m);
    NSValue *key = [NSValue valueWithPointer:(const void *)orig];
    if ([gHooked containsObject:key]) return;
    [gHooked addObject:key];

    method_setImplementation(m, imp_implementationWithBlock(^(NSURLSessionTask *task) {
        LogRequest(task.currentRequest ?: task.originalRequest, @"REQ");
        ((void (*)(id, SEL))orig)(task, @selector(resume));
    }));
}

#pragma mark - Hook: NSURLSession (الاستجابات عبر completionHandler)

typedef void (^SessionCH)(NSData *, NSURLResponse *, NSError *);
static __thread BOOL gInside; // يمنع التسجيل المزدوج عند استدعاء الدوال لبعضها

static SessionCH WrapSessionCH(NSURL *url, SessionCH ch) {
    if (!ch) return nil;
    return ^(NSData *d, NSURLResponse *r, NSError *e) {
        LogResponse(url, d, r, e);
        ch(d, r, e);
    };
}

static void HookSessionCompletion(void) {
    Class c = [NSURLSession class];

    // dataTaskWithRequest:completionHandler:
    SEL s1 = @selector(dataTaskWithRequest:completionHandler:);
    Method m1 = class_getInstanceMethod(c, s1);
    if (m1) {
        IMP o1 = method_getImplementation(m1);
        method_setImplementation(m1, imp_implementationWithBlock(^id(NSURLSession *ses, NSURLRequest *req, SessionCH ch) {
            SessionCH w = gInside ? ch : WrapSessionCH(req.URL, ch);
            return ((id (*)(id, SEL, id, id))o1)(ses, s1, req, w);
        }));
    }

    // dataTaskWithURL:completionHandler:
    SEL s2 = @selector(dataTaskWithURL:completionHandler:);
    Method m2 = class_getInstanceMethod(c, s2);
    if (m2) {
        IMP o2 = method_getImplementation(m2);
        method_setImplementation(m2, imp_implementationWithBlock(^id(NSURLSession *ses, NSURL *url, SessionCH ch) {
            BOOL prev = gInside;
            SessionCH w = WrapSessionCH(url, ch);
            gInside = YES;
            id task = ((id (*)(id, SEL, id, id))o2)(ses, s2, url, w);
            gInside = prev;
            return task;
        }));
    }

    // uploadTaskWithRequest:fromData:completionHandler:
    SEL s3 = @selector(uploadTaskWithRequest:fromData:completionHandler:);
    Method m3 = class_getInstanceMethod(c, s3);
    if (m3) {
        IMP o3 = method_getImplementation(m3);
        method_setImplementation(m3, imp_implementationWithBlock(^id(NSURLSession *ses, NSURLRequest *req, NSData *data, SessionCH ch) {
            if (data.length) ClickLog(@"[UPLOAD] %@ Body %@", req.URL.absoluteString, BodyString(data));
            return ((id (*)(id, SEL, id, id, id))o3)(ses, s3, req, data, WrapSessionCH(req.URL, ch));
        }));
    }
}

#pragma mark - Hook: NSURLConnection

static void HookConnection(void) {
    Class c = [NSURLConnection class];
    Class meta = object_getClass(c);

    // +sendSynchronousRequest:returningResponse:error:
    SEL ss = @selector(sendSynchronousRequest:returningResponse:error:);
    Method ms = class_getClassMethod(c, ss);
    if (ms) {
        IMP os = method_getImplementation(ms);
        method_setImplementation(ms, imp_implementationWithBlock(^NSData *(Class cls, NSURLRequest *req, NSURLResponse **resp, NSError **err) {
            LogRequest(req, @"CONN-REQ");
            NSData *d = ((NSData * (*)(id, SEL, id, NSURLResponse **, NSError **))os)(cls, ss, req, resp, err);
            LogResponse(req.URL, d, resp ? *resp : nil, err ? *err : nil);
            return d;
        }));
    }

    // +sendAsynchronousRequest:queue:completionHandler:
    SEL sa = @selector(sendAsynchronousRequest:queue:completionHandler:);
    Method ma = class_getClassMethod(c, sa);
    if (ma) {
        IMP oa = method_getImplementation(ma);
        method_setImplementation(ma, imp_implementationWithBlock(^(Class cls, NSURLRequest *req, NSOperationQueue *q,
                                                                   void (^ch)(NSURLResponse *, NSData *, NSError *)) {
            LogRequest(req, @"CONN-REQ");
            void (^w)(NSURLResponse *, NSData *, NSError *) = ch ? ^(NSURLResponse *r, NSData *d, NSError *e) {
                LogResponse(req.URL, d, r, e);
                ch(r, d, e);
            } : nil;
            ((void (*)(id, SEL, id, id, id))oa)(cls, sa, req, q, w);
        }));
    }

    // -initWithRequest:delegate:startImmediately:
    SEL si = @selector(initWithRequest:delegate:startImmediately:);
    Method mi = class_getInstanceMethod(c, si);
    if (mi) {
        IMP oi = method_getImplementation(mi);
        method_setImplementation(mi, imp_implementationWithBlock(^id(NSURLConnection *conn, NSURLRequest *req, id del, BOOL start) {
            LogRequest(req, @"CONN-REQ");
            return ((id (*)(id, SEL, id, id, BOOL))oi)(conn, si, req, del, start);
        }));
    }
    (void)meta;
}

#pragma mark - Entry

__attribute__((constructor))
static void ClickScannerInit(void) {
    gHooked = [NSMutableSet set];
    HookTouches();

    NSArray *names = @[@"NSURLSessionTask", @"__NSCFLocalSessionTask", @"__NSCFLocalDataTask",
                       @"__NSCFLocalUploadTask", @"__NSCFLocalDownloadTask"];
    for (NSString *n in names) HookResume(NSClassFromString(n));

    HookSessionCompletion();
    HookConnection();

    ClickLog(@"ClickScanner loaded. Log: %@", LogPath());
}
