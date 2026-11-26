#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <spawn.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <sys/wait.h>
#import <stdio.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const kWXLogPath = @"/var/mobile/wxchooser.log";

static NSString *WXLocalLogPath(void) {
    @try {
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (dir.length) return [dir stringByAppendingPathComponent:@"wxchooser.log"];
    } @catch (NSException *e) { }
    return nil;
}

static void WXWriteLog(NSString *line) {
    NSString *s = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    BOOL wrote = NO;
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kWXLogPath];
        if (!fh) {
            wrote = [s writeToFile:kWXLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
            wrote = YES;
        }
    } @catch (NSException *e) { wrote = NO; }
    if (wrote) return;
    NSString *lp = WXLocalLogPath();
    if (!lp.length) return;
    @try {
        NSFileHandle *fh2 = [NSFileHandle fileHandleForWritingAtPath:lp];
        if (!fh2) { [s writeToFile:lp atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
        [fh2 seekToEndOfFile];
        [fh2 writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
        [fh2 closeFile];
    } @catch (NSException *e) { }
}

#define WXLOG(...) WXWriteLog([NSString stringWithFormat:__VA_ARGS__])

static void (*o_sbmw_execute)(id, SEL, id, unsigned long long, id) = NULL;

static volatile BOOL gWXBusy = NO;
static volatile CFAbsoluteTime gWXBusyAt = 0;
static volatile BOOL gWXDialoging = NO;
static CFAbsoluteTime gWXCooldownUntil = 0;
static NSString *gWXLastWXURL = nil;
static UIImage *WXAppIcon(NSString *bid);
static UIImage *WXRealIconForBid(NSString *bid, NSString *path);
static NSString *WXRealNameForBid(NSString *bid);
static NSString *WXBundlePathForBid(NSString *bid);
static BOOL WXLaunchBySBS(NSURL *url, NSString *bid);
static NSString *WXNameFromAppPath(NSString *dir);
static UIViewController *gWXHostVC = nil;
static void WXSBHideOverlay(void);
static CFAbsoluteTime gWXSuppressUntil = 0;
static void WXPostSheetDismiss(void);
static void WXPostLaunchingNote(void);
static double WXAppSheetAge(void);
static void WXMarkAppSheetShowing(void);
static void WXRemoveSheetNow(void);
static BOOL WXSBEnsureOverlay(void);

static NSString *WXSelfBundleID(void) {
    static NSString *bid = nil;
    if (!bid) bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return bid;
}

// 沙盒进程写不了 /var/mobile，改用 Darwin 通知向 SpringBoard 报到（SpringBoard 负责落日志）
static NSString *WXPingNameForBID(NSString *bid) {
    NSString *b = bid.lowercaseString;
    if (!b.length) return nil;
    if ([b isEqualToString:@"com.chinaunicom.mobilebusiness"]) return @"com.fengxin.wxchooser.loaded.chinaunicom";
    if ([b isEqualToString:@"wiki.qaq.umbra"]) return @"com.fengxin.wxchooser.loaded.umbra";
    if ([b containsString:@"safariviewservice"]) return @"com.fengxin.wxchooser.loaded.safariview";
    if ([b containsString:@"webkit.webcontent"]) return @"com.fengxin.wxchooser.loaded.webcontent";
    if ([b isEqualToString:@"com.apple.mobilesafari"]) return @"com.fengxin.wxchooser.loaded.safari";
    if ([b containsString:@"launchservicesd"]) return @"com.fengxin.wxchooser.loaded.lsd";
    return nil;
}

static void WXPostLoadedPing(void) {
    @try {
        NSString *name = WXPingNameForBID(WXSelfBundleID());
        if (!name) return;
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge CFStringRef)name, NULL, NULL, true);
    } @catch (NSException *e) {}
}

static BOOL WXIsSelfWeChat(void) {
    NSString *b = WXSelfBundleID().lowercaseString;
    if (!b.length) return NO;
    return [b containsString:@"tencent.xin"] || [b containsString:@"weixin"] || [b containsString:@"wechat"];
}

static BOOL WXIsWeixinScheme(NSString *scheme) {
    NSString *s = scheme.lowercaseString;
    if (!s.length) return NO;
    if ([s hasPrefix:@"weixin"]) return YES;
    if ([s hasPrefix:@"wx"] && s.length > 2) return YES;
    return NO;
}

static BOOL WXIsWeChatWebURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) return NO;
    NSString *host = (url.host ?: @"").lowercaseString;
    NSString *path = (url.path ?: @"").lowercaseString;
    if (host.length && ([host containsString:@"weixin"] || [host containsString:@"wechat"] || [host containsString:@"tenpay"] || [host containsString:@"tencent.com"])) return YES;
    if (path.length && ([path containsString:@"weixin"] || [path containsString:@"wechat"] || [path containsString:@"tenpay"])) return YES;
    return NO;
}

static BOOL WXIsTargetURL(NSURL *url) {
    if (!url) return NO;
    if (WXIsWeixinScheme(url.scheme ?: @"")) return YES;
    if (WXIsWeChatWebURL(url)) return YES;
    return NO;
}

static NSSet<NSString *> *WXWeChatLinkHosts(void) {
    static NSSet *set = nil;
    if (!set) set = [NSSet setWithArray:@[@"weixin.qq.com", @"weixin110.qq.com", @"wx.qq.com",
                                          @"help.wechat.com", @"open.weixin.qq.com"]];
    return set;
}

static NSArray<NSString *> *WXSchemesOfPlist(NSDictionary *pl) {
    NSMutableArray *out = [NSMutableArray array];
    id arr = pl[@"CFBundleURLTypes"];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (NSDictionary *t in (NSArray *)arr) {
            if (![t isKindOfClass:[NSDictionary class]]) continue;
            id ss = t[@"CFBundleURLSchemes"];
            if ([ss isKindOfClass:[NSArray class]]) {
                for (id s2 in (NSArray *)ss) {
                    if ([s2 isKindOfClass:[NSString class]] && [(NSString *)s2 length]) [out addObject:(NSString *)s2];
                }
            }
        }
    }
    return out;
}

static NSArray<NSDictionary *> *WXScanViaLSWorkspace(void);

static BOOL WXIsStrictWeChatScheme(NSString *scheme) {
    NSString *s = scheme.lowercaseString;
    if (!s.length) return NO;
    if ([s containsString:@"."]) return NO;   // 形如 weixin.chinaunicom.com 的是别人的私有 scheme
    if ([s isEqualToString:@"weixin"] || [s isEqualToString:@"wechat"]) return YES;
    if ([s hasPrefix:@"weixin"]) return YES;
    if ([s hasPrefix:@"wx"] && s.length > 2) return YES;
    return NO;
}

// 是否可能是微信类应用：包名像微信，或显示名含「微信」且注册了 weixin 系 scheme
static BOOL WXLooksLikeWeChat(NSString *bid, NSString *name, NSArray<NSString *> *schemes) {
    NSString *b = bid.lowercaseString ?: @"";
    NSString *n = name ?: @"";
    if ([b containsString:@"tencent.xin"]) return YES;
    if ([b containsString:@"weixin"]) return YES;
    if ([b containsString:@"wechat"]) return YES;
    BOOL hasWeixinScheme = NO;
    for (NSString *s in schemes) {
        NSString *low = s.lowercaseString;
        if ([low isEqualToString:@"weixin"] || [low isEqualToString:@"wechat"] || [low hasPrefix:@"weixin"]) { hasWeixinScheme = YES; break; }
    }
    if ([n containsString:@"微信"] && hasWeixinScheme) return YES;
    return NO;
}

static NSArray<NSDictionary *> *WXScanWeChatApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *appPaths = [NSMutableArray array];

    for (NSString *root in @[@"/Applications", @"/var/jb/Applications"]) {
        @try {
            for (NSString *sub in [fm contentsOfDirectoryAtPath:root error:nil]) {
                if ([sub hasSuffix:@".app"]) [appPaths addObject:[root stringByAppendingPathComponent:sub]];
            }
        } @catch (NSException *e) {}
    }
    @try {
        NSString *croot = @"/var/containers/Bundle/Application";
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:croot error:nil]) {
            NSString *u = [croot stringByAppendingPathComponent:uuid];
            for (NSString *sub in [fm contentsOfDirectoryAtPath:u error:nil]) {
                if ([sub hasSuffix:@".app"]) [appPaths addObject:[u stringByAppendingPathComponent:sub]];
            }
        }
    } @catch (NSException *e) {}

    for (NSString *p in appPaths) {
        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Info.plist"]];
        if (![pl isKindOfClass:[NSDictionary class]]) continue;
        NSString *bid = pl[@"CFBundleIdentifier"];
        if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
        NSString *name = pl[@"CFBundleDisplayName"] ?: pl[@"CFBundleName"];
        if (![name isKindOfClass:[NSString class]]) name = bid;
        NSArray *schemes = WXSchemesOfPlist(pl);
        if (!WXLooksLikeWeChat(bid, name, schemes)) continue;
        [out addObject:@{@"bid": bid, @"name": name, @"schemes": schemes, @"path": p}];
    }
    if (out.count == 0) {
        WXLOG(@"文件系统扫不到微信类应用，改用 LaunchServices");
        out = [WXScanViaLSWorkspace() mutableCopy];
    }
    return out;
}

static NSArray<NSDictionary *> *WXScanViaLSWorkspace(void) {
    NSMutableArray *out = [NSMutableArray array];
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    if (!cls) { WXLOG(@"LSW: 类不存在"); return out; }
    @try {
        id ws = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(defaultWorkspace));
        id apps = ((id (*)(id, SEL))objc_msgSend)(ws, @selector(allInstalledApplications));
        if (![apps isKindOfClass:[NSArray class]]) { WXLOG(@"LSW: 应用列表拿不到"); return out; }
        for (id proxy in (NSArray *)apps) {
            NSString *bid = nil, *name = nil;
            @try { bid = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleIdentifier)); } @catch (NSException *e) {}
            @try { name = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName)); } @catch (NSException *e) {}
            if (!bid.length) continue;
            NSArray *schemes = @[];
            @try {
                id burl = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleURL));
                if ([burl isKindOfClass:[NSURL class]]) {
                    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfURL:[(NSURL *)burl URLByAppendingPathComponent:@"Info.plist"]];
                    if ([pl isKindOfClass:[NSDictionary class]]) schemes = WXSchemesOfPlist(pl);
                }
            } @catch (NSException *e) {}
            if (!WXLooksLikeWeChat(bid, name, schemes)) continue;
            NSDictionary *item = @{@"bid": bid, @"name": name.length ? name : bid, @"schemes": schemes};
            NSMutableDictionary *mi = [item mutableCopy];
            @try {
                id burl2 = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleURL));
                if ([burl2 isKindOfClass:[NSURL class]]) mi[@"path"] = [(NSURL *)burl2 path];
            } @catch (NSException *e) {}
            [out addObject:mi];
        }
        WXLOG(@"LSW: 枚举到 %lu 个微信类应用", (unsigned long)out.count);
    } @catch (NSException *e) {
        WXLOG(@"LSW 异常 %@", e.reason);
    }
    return out;
}

static NSDictionary *WXKnownCandidate(NSString *bid, NSString *name) {
    return @{@"bid": bid ?: @"", @"name": name ?: bid ?: @"", @"schemes": @[@"weixin"]};
}

static NSArray<NSDictionary *> *WXCandidatesForURL(NSURL *url) {
    NSArray *all = WXScanWeChatApps();
    // 1.17：沙盒应用里扫不到 App 列表时，至少保证两个已知微信永远可选
    {
        NSMutableArray *merged = [all mutableCopy] ?: [NSMutableArray array];
        NSArray *known = @[ WXKnownCandidate(@"com.tencent.xin", @"微信"),
                            WXKnownCandidate(@"com.tencent.xinapp", @"微信") ];
        for (NSDictionary *k in known) {
            BOOL exists = NO;
            for (NSDictionary *a in all) {
                if ([a[@"bid"] isEqualToString:k[@"bid"]]) { exists = YES; break; }
            }
            if (!exists) {
                [merged addObject:k];
                WXLOG(@"候选不足，补入已知微信 %@ %@", k[@"bid"], k[@"name"]);
            }
        }
        all = merged;
    }
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (NSDictionary *b in all) {
        for (NSString *s in b[@"schemes"]) {
            NSString *low = s.lowercaseString;
            counts[low] = @([counts[low] integerValue] + 1);
        }
    }
    NSMutableArray *res = [NSMutableArray array];
    for (NSDictionary *a in all) {
        NSString *bid = a[@"bid"];
        if ([bid isEqualToString:WXSelfBundleID()]) continue;
        BOOL dup = NO;
        for (NSDictionary *r in res) {
            if ([r[@"bid"] isEqualToString:bid]) { dup = YES; break; }
        }
        if (dup) continue;
        NSString *uniq = nil;
        NSString *fallback = nil;
        for (NSString *s in a[@"schemes"]) {
            NSString *low = s.lowercaseString;
            if ([counts[low] integerValue] <= 1 && !WXIsWeixinScheme(low)) { uniq = s; break; }
        }
        for (NSString *s in a[@"schemes"]) {
            if (WXIsWeixinScheme(s)) { fallback = s; break; }
        }
        NSString *dispName = WXNameFromAppPath(a[@"path"]) ?: a[@"name"];
        if (!dispName.length) dispName = WXRealNameForBid(bid) ?: bid;
        // 1.32：名字一律按 App 自己的显示名（两个微信都叫「微信」）
        NSString *appPath = [a[@"path"] isKindOfClass:[NSString class]] ? a[@"path"] : WXBundlePathForBid(bid);
        if (!dispName.length && appPath.length) dispName = WXNameFromAppPath(appPath);
        NSMutableDictionary *m = [@{@"bid": bid, @"name": dispName.length ? dispName : (bid ?: @"")} mutableCopy];
        if (appPath.length) m[@"path"] = appPath;
        if (uniq) m[@"scheme"] = uniq;
        if (fallback) m[@"wxScheme"] = fallback;
        [res addObject:m];
    }
    return res;
}

static UIViewController *WXTopViewController(void) {
    UIWindow *w = nil;
    for (UIWindow *win in [[UIApplication sharedApplication] windows]) {
        if (win.isKeyWindow) { w = win; break; }
    }
    if (!w) w = [[[UIApplication sharedApplication] windows] firstObject];
    UIViewController *vc = w.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void WXOpenPassthrough(NSURL *url, NSDictionary *options, void (^done)(BOOL)) {
    gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gWXBusy) { gWXBusy = NO; WXLOG(@"放行等待超时，解除忙碌标记"); }
    });
    void (^fire)(void) = ^{
        [[UIApplication sharedApplication] openURL:url options:options ?: @{} completionHandler:^(BOOL ok) {
            WXLOG(@"原样放行结果=%d url=%@", ok, url.absoluteString);
            gWXBusy = NO;
            if (done) done(ok);
        }];
    };
    if ([NSThread isMainThread]) fire(); else dispatch_async(dispatch_get_main_queue(), fire);
}

static BOOL WXOpenByScheme(NSURL *url, NSString *scheme, void (^done)(BOOL)) {
    if (!scheme.length) return NO;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.scheme = scheme;
    NSURL *u = c.URL;
    if (!u) return NO;
    WXLOG(@"改写 scheme -> %@ : %@", scheme, u.absoluteString);
    WXOpenPassthrough(u, @{}, ^(BOOL ok) {
        WXLOG(@"改写后打开结果=%d", ok);
        if (done) done(ok);
    });
    return YES;
}

static BOOL WXRequestSpringBoardLaunch(NSURL *url, NSString *bid) {
    NSDictionary *req = @{ @"bid": bid ?: @"",
                           @"url": url.absoluteString ?: @"" };
    BOOL wrote = [req writeToFile:@"/var/mobile/wxchooser_req.plist" atomically:YES];
    WXLOG(@"向 SpringBoard 发启动请求（写文件=%d）bid=%@ url=%@", wrote, bid, url.absoluteString);
    if (!wrote) return NO;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.fengxin.wxchooser.launch"), NULL, NULL, true);
    return YES;
}

static BOOL WXOpenByBundleID(NSURL *url, NSString *bid, void (^done)(BOOL)) {
    Class lswCls = NSClassFromString(@"LSApplicationWorkspace");
    if (!lswCls) { WXLOG(@"没有 LSApplicationWorkspace"); return NO; }
    id ws = ((id (*)(id, SEL))objc_msgSend)(lswCls, @selector(defaultWorkspace));
    if (!ws) return NO;

    NSArray *sels = @[@"openURL:withBundleIdentifier:allowUnlock:",
                      @"openURL:withBundleIdentifier:"];
    for (NSString *sn in sels) {
        SEL sel = NSSelectorFromString(sn);
        if (![ws respondsToSelector:sel]) continue;
        @try {
            BOOL ok = NO;
            gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
            if ([sn hasSuffix:@"allowUnlock:"]) {
                ok = ((BOOL (*)(id, SEL, id, id, BOOL))objc_msgSend)(ws, sel, url, bid, YES);
            } else {
                ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, sel, url, bid);
            }
            gWXBusy = NO;
            WXLOG(@"私有接口 %@ -> %d", sn, ok);
            if (ok) { if (done) done(YES); return YES; }
        } @catch (NSException *e) {
            gWXBusy = NO;
            WXLOG(@"私有接口异常 %@ %@", sn, e.reason);
        }
    }
    return NO;
}

#pragma mark - SpringBoard 代办启动

static int (*gSBSLaunchWithURL)(CFStringRef, CFURLRef, CFDictionaryRef, CFStringRef *, Boolean) = NULL;
static int (*gSBSLaunch)(CFStringRef, Boolean) = NULL;

static void WXLoadSBS(void) {
    if (gSBSLaunchWithURL || gSBSLaunch) return;
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    gSBSLaunchWithURL = (int (*)(CFStringRef, CFURLRef, CFDictionaryRef, CFStringRef *, Boolean))dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions");
    gSBSLaunch = (int (*)(CFStringRef, Boolean))dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
    WXLOG(@"SBS 接口：withURL=%@ launch=%@", gSBSLaunchWithURL ? @"有" : @"无", gSBSLaunch ? @"有" : @"无");
}

static BOOL WXLaunchBySBS(NSURL *url, NSString *bid) {
    if (!bid.length) return NO;
    WXLoadSBS();
    if (!gSBSLaunchWithURL && !gSBSLaunch) return NO;
    int err = -1;
    @try {
        if (gSBSLaunchWithURL) {
            CFStringRef eb = NULL;
            err = gSBSLaunchWithURL((__bridge CFStringRef)bid, (__bridge CFURLRef)url,
                                    (__bridge CFDictionaryRef)@{}, &eb, false);
            if (eb) WXLOG(@"SBS 启动错误：%@", (__bridge NSString *)eb);
        } else {
            err = gSBSLaunch((__bridge CFStringRef)bid, false);
        }
    } @catch (NSException *e) { WXLOG(@"SBS 启动异常 %@", e.reason); }
    WXLOG(@"SBS 按包名启动 %@ -> %d", bid, err);
    return err == 0;
}

static void WXHandleLaunchRequest(void) {
    NSString *path = @"/var/mobile/wxchooser_req.plist";
    NSDictionary *req = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![req isKindOfClass:[NSDictionary class]]) { WXLOG(@"SB: 读不到请求文件"); return; }
    NSString *bid = req[@"bid"], *us = req[@"url"];
    NSURL *u = us.length ? [NSURL URLWithString:us] : nil;
    WXLOG(@"SB: 收到请求 bid=%@ url=%@", bid, us);
    WXLoadSBS();
    if (gSBSLaunchWithURL && bid.length) {
        CFStringRef err = NULL;
        int r = gSBSLaunchWithURL((__bridge CFStringRef)bid, (__bridge CFURLRef)u,
                                  (__bridge CFDictionaryRef)@{}, &err, false);
        WXLOG(@"SB: SBSLaunchWithURL bid=%@ r=%d err=%@", bid, r, err ? (__bridge NSString *)err : @"无");
        if (err) CFRelease(err);
    } else if (gSBSLaunch && bid.length) {
        int r = gSBSLaunch((__bridge CFStringRef)bid, false);
        WXLOG(@"SB: SBSLaunch bid=%@ r=%d", bid, r);
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

static void WXPingCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *nm = (__bridge NSString *)name;
    NSString *who = nm.lastPathComponent;
    if ([who isEqualToString:@"chinaunicom"]) who = @"中国联通";
    else if ([who isEqualToString:@"umbra"]) who = @"Umbra";
    else if ([who isEqualToString:@"safariview"]) who = @"SafariViewService";
    else if ([who isEqualToString:@"webcontent"]) who = @"WebKit WebContent";
    else if ([who isEqualToString:@"safari"]) who = @"Safari";
    else if ([who isEqualToString:@"lsd"]) who = @"launchservicesd";
    WXLOG(@"★ 报到：%@ 已加载插件", who);
}

static void WXDarwinCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ WXHandleLaunchRequest(); });
}

// 只在 SpringBoard 里跑：把系统里跟“启动应用 / 打开 URL”相关的方法名导出，方便定位真正的拦截点
static void WXDumpLaunchAPIs(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    if (!classes) return;
    objc_getClassList(classes, count);
    NSMutableArray *lines = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        NSString *cn = NSStringFromClass(classes[i]);
        if (!cn.length) continue;
        if (!([cn containsString:@"Applic"] || [cn containsString:@"Launch"] ||
              [cn containsString:@"OpenURL"] || [cn containsString:@"Workspace"])) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(classes[i], &mc);
        for (unsigned j = 0; j < mc; j++) {
            NSString *sn = NSStringFromSelector(method_getName(ms[j]));
            NSString *low = sn.lowercaseString;
            if (!([low containsString:@"open"] || [low containsString:@"url"] || [low containsString:@"launch"])) continue;
            [lines addObject:[NSString stringWithFormat:@"%@ -%@", cn, sn]];
        }
        if (ms) free(ms);
    }
    free(classes);
    WXLOG(@"DUMP 启动相关方法共 %lu 条", (unsigned long)lines.count);
    NSUInteger limit = MIN(lines.count, (NSUInteger)500);
    for (NSUInteger i = 0; i < limit; i++) WXLOG(@"  D %@", lines[i]);
}

static UIImage *WXAppIcon(NSString *bid) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    if (!bid.length) return nil;
    UIImage *hit = cache[bid];
    if (hit) return hit;
    UIImage *img = nil;
    @try {
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        id ws = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"defaultWorkspace"));
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(ws, NSSelectorFromString(@"applicationForBundleIdentifier:"), bid);
        id burl = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"bundleURL"));
        if ([burl isKindOfClass:[NSURL class]]) {
            NSURL *u = (NSURL *)burl;
            NSString *dir = [u path];
            NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"Info.plist"]];
            NSMutableArray *names = [NSMutableArray array];
            if ([pl isKindOfClass:[NSDictionary class]]) {
                id icons = pl[@"CFBundleIcons"];
                if ([icons isKindOfClass:[NSDictionary class]]) {
                    id primary = ((NSDictionary *)icons)[@"CFBundlePrimaryIcon"];
                    if ([primary isKindOfClass:[NSDictionary class]]) {
                        id files = ((NSDictionary *)primary)[@"CFBundleIconFiles"];
                        if ([files isKindOfClass:[NSArray class]] && [files count]) {
                            NSString *base = [(NSArray *)files lastObject];
                            [names addObject:[base stringByAppendingString:@"@3x.png"]];
                            [names addObject:[base stringByAppendingString:@"@2x.png"]];
                            [names addObject:[base stringByAppendingString:@".png"]];
                        }
                    }
                }
                id single = pl[@"CFBundleIconFile"];
                if ([single isKindOfClass:[NSString class]] && [single length]) {
                    [names addObject:(NSString *)single];
                    [names addObject:[(NSString *)single stringByAppendingString:@".png"]];
                }
            }
            [names addObject:@"AppIcon60x60@3x.png"];
            [names addObject:@"AppIcon60x60@2x.png"];
            [names addObject:@"Icon@120x120.png"];
            for (NSString *n in names) {
                NSString *full = [dir stringByAppendingPathComponent:n];
                if ([[NSFileManager defaultManager] fileExistsAtPath:full]) {
                    img = [UIImage imageWithContentsOfFile:full];
                    if (img) break;
                }
            }
        }
    } @catch (NSException *e) { }
    if (img) cache[bid] = img;
    return img;
}

static UIImage *WXChatIcon(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(28, 28)];
        img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIColor colorWithRed:0.11 green:0.71 blue:0.20 alpha:1.0] setFill];
            UIBezierPath *bg = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 28, 28) cornerRadius:6.0];
            [bg fill];
            UIImage *sym = [UIImage systemImageNamed:@"message.fill"];
            sym = [sym imageWithTintColor:[UIColor whiteColor] renderingMode:UIImageRenderingModeAlwaysOriginal];
            if (sym) [sym drawInRect:CGRectMake(6, 7, 16, 14)];
        }];
    });
    return img;
}

static void WXSetActionIcon(UIAlertAction *a) {
    if (!a) return;
    UIImage *img = WXChatIcon();
    if (!img) return;
    @try { [a setValue:img forKey:@"image"]; } @catch (NSException *e) { }
}

static NSString *WXNameFromAppPath(NSString *dir) {
    if (!dir.length) return nil;
    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"Info.plist"]];
    if (![pl isKindOfClass:[NSDictionary class]]) return nil;
    id n = pl[@"CFBundleDisplayName"];
    if (![n isKindOfClass:[NSString class]] || ![n length]) n = pl[@"CFBundleName"];
    if ([n isKindOfClass:[NSString class]] && [n length]) return n;
    return nil;
}

static NSString *WXRealNameForBid(NSString *bid) {
    if (!bid.length) return nil;
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    NSString *hit = cache[bid];
    if ([hit isKindOfClass:[NSString class]]) return hit;
    NSString *name = nil;
    @try {
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        id ws = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"defaultWorkspace"));
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(ws, NSSelectorFromString(@"applicationForBundleIdentifier:"), bid);
        name = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(@"localizedName"));
    } @catch (NSException *e) { }
    if ([name isKindOfClass:[NSString class]] && name.length) cache[bid] = name;
    return name;
}

static UIImage *WXIconFromAppPath(NSString *dir) {
    if (!dir.length) return nil;
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    UIImage *hit = cache[dir];
    if ([hit isKindOfClass:[UIImage class]]) return hit;
    NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"Info.plist"]];
    NSMutableArray *names = [NSMutableArray array];
    if ([pl isKindOfClass:[NSDictionary class]]) {
        id icons = pl[@"CFBundleIcons"];
        if ([icons isKindOfClass:[NSDictionary class]]) {
            id primary = ((NSDictionary *)icons)[@"CFBundlePrimaryIcon"];
            if ([primary isKindOfClass:[NSDictionary class]]) {
                id files = ((NSDictionary *)primary)[@"CFBundleIconFiles"];
                if ([files isKindOfClass:[NSArray class]] && [files count]) {
                    NSString *base = [(NSArray *)files lastObject];
                    [names addObject:[base stringByAppendingString:@"@3x.png"]];
                    [names addObject:[base stringByAppendingString:@"@2x.png"]];
                    [names addObject:[base stringByAppendingString:@".png"]];
                }
            }
        }
        id single = pl[@"CFBundleIconFile"];
        if ([single isKindOfClass:[NSString class]] && [single length]) {
            [names addObject:(NSString *)single];
            [names addObject:[(NSString *)single stringByAppendingString:@".png"]];
        }
    }
    [names addObject:@"AppIcon60x60@3x.png"];
    [names addObject:@"AppIcon60x60@2x.png"];
    [names addObject:@"AppIcon60x60.png"];
    [names addObject:@"Icon@120x120.png"];
    [names addObject:@"Icon-60@3x.png"];
    UIImage *img = nil;
    for (NSString *n in names) {
        NSString *full = [dir stringByAppendingPathComponent:n];
        if ([[NSFileManager defaultManager] fileExistsAtPath:full]) {
            img = [UIImage imageWithContentsOfFile:full];
            if ([img isKindOfClass:[UIImage class]]) { WXLOG(@"图标取自文件 %@", full); break; }
        }
    }
    if ([img isKindOfClass:[UIImage class]]) cache[dir] = img;
    return img;
}

static NSString *WXBundlePathForBid(NSString *bid) {
    if (!bid.length) return nil;
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    id hit = cache[bid];
    if ([hit isKindOfClass:[NSString class]]) return [hit length] ? hit : nil;
    NSString *path = nil;
    @try {
        Class pc = NSClassFromString(@"LSApplicationProxy");
        SEL s = NSSelectorFromString(@"applicationProxyForIdentifier:");
        id proxy = (pc && [pc respondsToSelector:s]) ? ((id (*)(id, SEL, id))objc_msgSend)(pc, s, bid) : nil;
        for (NSString *selName in @[@"bundleURL", @"bundleContainerURL"]) {
            SEL sel = NSSelectorFromString(selName);
            if (![proxy respondsToSelector:sel]) continue;
            id u = ((id (*)(id, SEL))objc_msgSend)(proxy, sel);
            if (![u isKindOfClass:[NSURL class]]) continue;
            NSString *pp = [(NSURL *)u path];
            if ([pp hasSuffix:@".app"] && [[NSFileManager defaultManager] fileExistsAtPath:pp]) { path = pp; break; }
        }
    } @catch (NSException *e) { }
    cache[bid] = path ?: @"";
    if (path.length) WXLOG(@"按 bundle id 反查到 App 路径：%@ -> %@", bid, path);
    return path;
}

static UIImage *WXIconViaProxy(NSString *bid) {
    if (!bid.length) return nil;
    Class pc = NSClassFromString(@"LSApplicationProxy");
    if (!pc) return nil;
    id proxy = nil;
    @try {
        SEL s = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if ([pc respondsToSelector:s]) proxy = ((id (*)(id, SEL, id))objc_msgSend)(pc, s, bid);
    } @catch (NSException *e) { }
    if (!proxy) return nil;
    SEL dSel = NSSelectorFromString(@"iconDataForVariant:");
    if ([proxy respondsToSelector:dSel]) {
        for (unsigned int v = 0; v <= 4; v++) {
            @try {
                id data = ((id (*)(id, SEL, unsigned int))objc_msgSend)(proxy, dSel, v);
                if ([data isKindOfClass:[NSData class]] && [(NSData *)data length] > 64) {
                    UIImage *im = [UIImage imageWithData:(NSData *)data];
                    if ([im isKindOfClass:[UIImage class]]) { WXLOG(@"图标取自 proxy variant=%u", v); return im; }
                }
            } @catch (NSException *e) { }
        }
    }
    return nil;
}

static UIImage *WXRealIconForBid(NSString *bid, NSString *path) {
    NSString *key = bid.length ? bid : @"(空)";
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    UIImage *hit = cache[key];
    if ([hit isKindOfClass:[UIImage class]]) return hit;
    UIImage *img = WXIconViaProxy(bid);
    if (![img isKindOfClass:[UIImage class]]) img = WXIconFromAppPath(path);
    if (![img isKindOfClass:[UIImage class]]) {
        Class ui = NSClassFromString(@"UIImage");
        @try {
            SEL s2 = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
            if ([ui respondsToSelector:s2]) {
                img = ((id (*)(id, SEL, id, unsigned int, double))objc_msgSend)(ui, s2, bid, 0, (double)[UIScreen mainScreen].scale);
            }
            if (![img isKindOfClass:[UIImage class]]) {
                SEL s1 = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:");
                if ([ui respondsToSelector:s1]) img = ((id (*)(id, SEL, id))objc_msgSend)(ui, s1, bid);
            }
        } @catch (NSException *e) { }
    }
    if (![img isKindOfClass:[UIImage class]]) img = WXAppIcon(bid);
    if (![img isKindOfClass:[UIImage class]]) { WXLOG(@"取不到图标 bid=%@ path=%@", bid, path ?: @"(无)"); return nil; }
    UIImage *src = img;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(29, 29)];
    img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 29, 29) cornerRadius:6.5];
        [clip addClip];
        [src drawInRect:CGRectMake(0, 0, 29, 29)];
    }];
    img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    cache[key] = img;
    return img;
}

static NSAttributedString *WXActionTitleText(NSString *title, UIImage *icon) {
    if (![icon isKindOfClass:[UIImage class]]) return nil;
    if (!title.length) title = @"";
    NSTextAttachment *att = [[NSTextAttachment alloc] init];
    att.image = icon;
    att.bounds = CGRectMake(2, -6, 24, 24);
    NSMutableAttributedString *m = [[NSMutableAttributedString alloc] initWithAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
    NSDictionary *attrs = @{ NSFontAttributeName : [UIFont systemFontOfSize:17 weight:UIFontWeightMedium],
                             NSForegroundColorAttributeName : [UIColor labelColor] };
    [m appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:title] attributes:attrs]];
    return m;
}

static void WXStyleAction(UIAlertAction *a, NSDictionary *cand, NSString *title) {
    if (!a) return;
    UIImage *icon = WXRealIconForBid(cand[@"bid"], cand[@"path"]);
    if (![icon isKindOfClass:[UIImage class]]) return;
    NSAttributedString *attr = WXActionTitleText(title, icon);
    BOOL ok = NO;
    if (attr) { @try { [a setValue:attr forKey:@"attributedTitle"]; ok = YES; } @catch (NSException *e) { } }
    if (!ok) { @try { [a setValue:icon forKey:@"image"]; } @catch (NSException *e) { } }
}

#pragma mark - 自绘底部菜单（图标与名字整行居中）

@interface WXSheetRowTarget : NSObject
- (void)onRowTouchDown:(UIButton *)sender;
- (void)onRowTouchUp:(UIButton *)sender;
- (void)onRowTap:(UIButton *)sender;
- (void)onCancelTap:(UIButton *)sender;
- (void)dismissSheet;
@end

static NSArray *gWXSheetCands = nil;
static void (^gWXSheetPick)(NSDictionary *) = nil;
static void (^gWXSheetCancel)(void) = nil;
static UIView *gWXSheetContainer = nil;
static WXSheetRowTarget *gWXSheetTarget = nil;

@implementation WXSheetRowTarget
- (void)dismissSheet {
    UIView *c = gWXSheetContainer;
    gWXSheetContainer = nil;
    gWXSheetCands = nil;
    gWXSheetPick = nil;
    gWXSheetCancel = nil;
    if (!c) return;
    [UIView animateWithDuration:0.16 animations:^{ c.alpha = 0.0; } completion:^(BOOL finished) { [c removeFromSuperview]; }];
}
- (void)onRowTouchDown:(UIButton *)sender {
    [UIView animateWithDuration:0.08 animations:^{ sender.alpha = 0.45; }];
}
- (void)onRowTouchUp:(UIButton *)sender {
    [UIView animateWithDuration:0.12 animations:^{ sender.alpha = 1.0; }];
}
- (void)onRowTap:(UIButton *)sender {
    sender.alpha = 1.0;
    @try {
        UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [h prepare]; [h impactOccurred];
    } @catch (NSException *e) { }
    NSInteger idx = sender.tag;
    NSArray *cands = gWXSheetCands;
    void (^pick)(NSDictionary *) = gWXSheetPick;
    gWXSheetPick = nil;
    gWXSheetCancel = nil;
    gWXSheetCands = nil;
    [self dismissSheet];
    WXPostSheetDismiss();
    if (cands && idx >= 0 && idx < (NSInteger)cands.count && pick) pick(cands[idx]);
}
- (void)onCancelTap:(UIButton *)sender {
    void (^cancel)(void) = gWXSheetCancel;
    gWXSheetPick = nil;
    gWXSheetCancel = nil;
    gWXSheetCands = nil;
    [self dismissSheet];
    WXPostSheetDismiss();
    if (cancel) cancel();
}
@end

static BOOL WXShowSheet(UIView *host, NSArray<NSDictionary *> *cands, void (^pick)(NSDictionary *), void (^cancel)(void)) {
    if (!host || ![host isKindOfClass:[UIView class]]) return NO;
    BOOL ok = NO;
    @try {
        UIView *old = gWXSheetContainer;
        gWXSheetContainer = nil;
        if (old) [old removeFromSuperview];

        gWXSheetCands = [cands copy];
        gWXSheetPick = [pick copy];
        gWXSheetCancel = [cancel copy];

        CGRect b = host.bounds;
        CGFloat headerH = 56.0, rowH = 58.0, cancelH = 52.0, gap = 8.0, bottomInset = 26.0;
        UIWindow *win = host.window;
        if (win) {
            if (@available(iOS 11.0, *)) bottomInset = MAX(bottomInset, win.safeAreaInsets.bottom + 8.0);
        }

        CGFloat cardW = b.size.width - 16.0;
        CGFloat cardH = headerH + rowH * (CGFloat)cands.count;
        CGFloat cardY = b.size.height - bottomInset - cancelH - gap - cardH;

        UIView *container = [[UIView alloc] initWithFrame:b];
        container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.34];
        container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        container.alpha = 0.0;

        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(8.0, cardY, cardW, cardH)];
        card.backgroundColor = [UIColor secondarySystemBackgroundColor];
        card.layer.cornerRadius = 14.0;
        card.clipsToBounds = YES;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 10.0, cardW, 20.0)];
        title.text = @"打开微信";
        title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        title.textColor = [UIColor secondaryLabelColor];
        title.textAlignment = NSTextAlignmentCenter;
        [card addSubview:title];

        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 32.0, cardW, 18.0)];
        sub.text = cands.count ? @"选择要跳转的微信" : @"没识别到微信 App";
        sub.font = [UIFont systemFontOfSize:13];
        sub.textColor = [UIColor tertiaryLabelColor];
        sub.textAlignment = NSTextAlignmentCenter;
        [card addSubview:sub];

        UIView *hline = [[UIView alloc] initWithFrame:CGRectMake(0, headerH - 0.5, cardW, 0.5)];
        hline.backgroundColor = [UIColor separatorColor];
        [card addSubview:hline];

        WXSheetRowTarget *target = [[WXSheetRowTarget alloc] init];
        gWXSheetTarget = target;

        for (NSUInteger i = 0; i < cands.count; i++) {
            NSDictionary *cand = cands[i];
            CGFloat y = headerH + rowH * (CGFloat)i;
            UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
            row.frame = CGRectMake(0, y, cardW, rowH);
            row.tag = (NSInteger)i;
            [row addTarget:target action:@selector(onRowTap:) forControlEvents:UIControlEventTouchUpInside];
            [row addTarget:target action:@selector(onRowTouchDown:) forControlEvents:UIControlEventTouchDown];
            [row addTarget:target action:@selector(onRowTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];

            UIImage *icon = WXRealIconForBid(cand[@"bid"], cand[@"path"]);
            NSString *nm = cand[@"name"] ?: cand[@"bid"];
            UIFont *nf = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
            CGFloat tw = [nm sizeWithAttributes:@{NSFontAttributeName:nf}].width + 2.0;
            CGFloat iconW = icon ? 26.0 : 0.0;
            CGFloat spacing = icon ? 10.0 : 0.0;
            CGFloat groupW = iconW + spacing + tw;
            CGFloat gx = (cardW - groupW) / 2.0;

            if (icon) {
                UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(gx, (rowH - 26.0) / 2.0, 26.0, 26.0)];
                iv.image = icon;
                iv.contentMode = UIViewContentModeScaleAspectFit;
                iv.layer.cornerRadius = 6.0;
                iv.clipsToBounds = YES;
                iv.userInteractionEnabled = NO;
                [row addSubview:iv];
                gx += iconW + spacing;
            }
            UILabel *lab = [[UILabel alloc] initWithFrame:CGRectMake(gx, 0, tw, rowH)];
            lab.text = nm;
            lab.font = nf;
            lab.textColor = [UIColor systemBlueColor];
            lab.userInteractionEnabled = NO;
            [row addSubview:lab];

            [card addSubview:row];

            if (i + 1 < cands.count) {
                UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, y + rowH - 0.5, cardW, 0.5)];
                line.backgroundColor = [UIColor separatorColor];
                [card addSubview:line];
            }
        }

        [container addSubview:card];

        UIButton *cancelBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        cancelBtn.frame = CGRectMake(8.0, CGRectGetMaxY(card.frame) + gap, cardW, cancelH);
        [cancelBtn setTitle:@"取消" forState:UIControlStateNormal];
        cancelBtn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        [cancelBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        cancelBtn.backgroundColor = [UIColor secondarySystemBackgroundColor];
        cancelBtn.layer.cornerRadius = 14.0;
        [cancelBtn addTarget:target action:@selector(onCancelTap:) forControlEvents:UIControlEventTouchUpInside];
        [container addSubview:cancelBtn];

        gWXSheetContainer = container;
        [host addSubview:container];
        [UIView animateWithDuration:0.20 animations:^{ container.alpha = 1.0; }];
        ok = YES;
        WXLOG(@"自绘底部菜单已显示，候选 %lu 个", (unsigned long)cands.count);
    } @catch (NSException *e) {
        WXLOG(@"自绘菜单异常 %@", e.reason);
        ok = NO;
    }
    return ok;
}

static void WXPostSheetDismiss(void) {
    @try {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.fengxin.wxchooser.sheetdismiss"), NULL, NULL, true);
    } @catch (NSException *e) { }
}

static void WXRemoveSheetNow(void) {
    UIView *c = gWXSheetContainer;
    gWXSheetContainer = nil;
    gWXSheetCands = nil;
    gWXSheetPick = nil;
    gWXSheetCancel = nil;
    if (c) [c removeFromSuperview];
}

static void WXLaunchingCallback(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gWXSuppressUntil = CFAbsoluteTimeGetCurrent() + 8.0;
        gWXDialoging = NO;
        gWXCooldownUntil = 0;
        WXLOG(@"收到启动广播，SB 放行 8 秒且不再弹框");
        WXSBHideOverlay();
    });
}

static void WXPostLaunchingNote(void) {
    @try {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.fengxin.wxchooser.launching"), NULL, NULL, true);
    } @catch (NSException *e) { }
}

static void WXSheetDismissCallback(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{
        WXRemoveSheetNow();
        gWXDialoging = NO;
    });
}

static void WXMarkAppSheetShowing(void) {
    @try {
        [[NSData dataWithBytes:"1" length:1] writeToFile:@"/var/mobile/wxchooser.appsheet" atomically:YES];
    } @catch (NSException *e) { }
}

static double WXAppSheetAge(void) {
    @try {
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:@"/var/mobile/wxchooser.appsheet" error:nil];
        NSDate *m = a[NSFileModificationDate];
        if (!m) return 9999.0;
        return [[NSDate date] timeIntervalSinceDate:m];
    } @catch (NSException *e) { return 9999.0; }
}

static UIWindow *gWXDiagWin = nil;

static void WXShowDiagHUD(NSString *text) {
    @try {
        if (gWXDiagWin) { [gWXDiagWin removeFromSuperview]; gWXDiagWin.hidden = YES; gWXDiagWin = nil; }
        UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 1;
        w.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectInset(w.bounds, 24, 0)];
        lab.numberOfLines = 0;
        lab.text = text;
        lab.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        lab.textColor = [UIColor whiteColor];
        lab.textAlignment = NSTextAlignmentCenter;
        UIView *bg = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w.bounds.size.width - 48, 0)];
        bg.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
        bg.layer.cornerRadius = 14;
        [vc.view addSubview:bg];
        [vc.view addSubview:lab];
        lab.frame = CGRectMake(20, 0, w.bounds.size.width - 88, 0);
        [lab sizeToFit];
        CGFloat h = lab.bounds.size.height + 36;
        bg.frame = CGRectMake(24, w.bounds.size.height / 2 - h / 2, w.bounds.size.width - 48, h);
        lab.frame = CGRectMake(40, bg.frame.origin.y + 18, w.bounds.size.width - 80, lab.bounds.size.height);
        w.rootViewController = vc;
        w.hidden = NO;
        gWXDiagWin = w;
        WXLOG(@"诊断 HUD 已显示：%@", text);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gWXDiagWin == w) { w.hidden = YES; gWXDiagWin = nil; }
        });
    } @catch (NSException *e) { WXLOG(@"HUD 异常 %@", e.reason); }
}

static void WXLaunchChosen(NSURL *url, NSDictionary *cand, NSDictionary *options, void (^completion)(BOOL)) {
    NSString *bid = cand[@"bid"];
    NSString *scheme = cand[@"scheme"];
    BOOL isWebURL = !WXIsWeixinScheme(url.scheme ?: @"");
    NSMutableString *steps = [NSMutableString string];
    WXPostLaunchingNote();

    __block BOOL done = NO;
    __block NSInteger step = 0;
    __block void (^runNext)(void);
    __weak void (^weakNext)(void);

    void (^finish)(BOOL) = ^(BOOL ok) {
        if (done) return;
        done = YES;
        WXLOG(@"选择结果 target=%@ url=%@ ok=%d\n%@", bid ?: @"(空)", url.absoluteString ?: @"(空)", ok, steps);
        if (ok) { gWXBusy = NO; gWXBusyAt = 0; }
        if (completion) completion(YES);
        if (!ok) {
            WXShowDiagHUD([NSString stringWithFormat:@"没跳转 (%@)\n%@", bid ?: @"?", steps]);
        }
    };

    runNext = ^{
        if (done) return;
        BOOL fired = NO;
        NSString *label = nil;
        switch (step) {
            case 0: label = @"1 包名+链接"; fired = bid.length ? WXOpenByBundleID(url, bid, nil) : NO; break;
            case 1: label = @"2 系统SBS+链接"; fired = bid.length ? WXLaunchBySBS(url, bid) : NO; break;
            case 2: label = @"3 仅启动App"; fired = bid.length ? WXLaunchBySBS(nil, bid) : NO; break;
            case 3:
                if (isWebURL) { step++; if (weakNext) weakNext(); return; }
                label = @"4 改链接"; fired = scheme.length ? WXOpenByScheme(url, scheme, nil) : NO;
                break;
            case 4: label = @"5 系统默认"; fired = YES; WXOpenPassthrough(url, options, nil); break;
            default: finish(NO); return;
        }
        step++;
        [steps appendFormat:@"%@ 返回%d\n", label, fired];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (done) return;
            if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
                [steps appendString:@"→ 已离开当前应用"];
                finish(YES);
                return;
            }
            if (weakNext) weakNext();
        });
    };

    runNext = [runNext copy];
    weakNext = runNext;
    runNext();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        finish(NO);
    });
}

static void WXPresentChooser(NSURL *url, NSArray<NSDictionary *> *cands, NSDictionary *options, void (^completion)(BOOL)) {
    UIViewController *top = WXTopViewController();
    if (!top) { WXLOG(@"找不到顶层控制器，直接放行"); completion(YES); return; }

    @try {
        UIWindow *hostWin = top.view.window;
        if (!hostWin) {
            for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
                if (w.isKeyWindow) { hostWin = w; break; }
            }
        }
        BOOL shown = hostWin ? WXShowSheet(hostWin, cands, ^(NSDictionary *cand) {
                WXLaunchChosen(url, cand, options, completion);
            }, ^{
                if (completion) completion(NO);
            }) : NO;
        if (shown) {
            WXMarkAppSheetShowing();
            WXLOG(@"应用内自绘菜单已显示，已标记占位（SB 不再弹）");
            return;
        }
    } @catch (NSException *e) {
        WXLOG(@"自绘菜单调用异常 %@", e.reason);
    }

    NSString *msg = cands.count ? @"选择要跳转的微信"
                                : @"没识别到微信 App";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"打开微信"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *cand in cands) {
        NSString *title = cand[@"name"] ?: cand[@"bid"];
        UIAlertAction *act = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            WXLaunchChosen(url, cand, options, completion);
        }];
        WXStyleAction(act, cand, title);
        [ac addAction:act];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        if (completion) completion(NO);
    }]];
    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = top.view;
        ac.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width / 2.0, top.view.bounds.size.height, 1, 1);
    }
    [top presentViewController:ac animated:YES completion:nil];
}

// 返回 YES 表示已经由本插件接管（调用方应直接返回成功）
static BOOL WXTryIntercept(NSURL *url, NSDictionary *options, void (^completion)(BOOL), NSString *entry) {
    if (gWXBusy) {
        if (CFAbsoluteTimeGetCurrent() - gWXBusyAt < 1.5) return NO;
        WXLOG(@"忙碌标记已过期，自动解除");
        gWXBusy = NO;
    }
    NSString *selfBid = WXSelfBundleID();
    BOOL inSpringBoard = [selfBid isEqualToString:@"com.apple.springboard"];
    WXLOG(@"[%@] 入口调用 App=%@ url=%@ opts=%@", entry, selfBid ?: @"(未知)", url.absoluteString ?: @"(无)", options ? [(NSDictionary *)options description] : @"(空)");
    if (inSpringBoard) return NO;   // SpringBoard 走 SBMainWorkspace 那一层
    @try {
        if (!url) return NO;
        NSString *scheme = url.scheme ?: @"";
        NSString *host = url.host ?: @"";
        WXLOG(@"[%@] %@ //%@", entry, scheme.length ? scheme : @"(无)", host);
        if (WXIsSelfWeChat()) return NO;
        if (!WXIsTargetURL(url)) return NO;
        BOOL webLink = !WXIsWeixinScheme(scheme);
        if (webLink) WXLOG(@"命中微信 https/Universal Link，同样弹选择框：%@", url.absoluteString);
        NSArray *cands = WXCandidatesForURL(url);
        WXLOG(@"拦截 %@ 候选 %lu 个", url.absoluteString, (unsigned long)cands.count);
        for (NSDictionary *c in cands) WXLOG(@"  候选：%@ %@ scheme=%@ wxScheme=%@", c[@"bid"], c[@"name"], c[@"scheme"] ?: @"(无)", c[@"wxScheme"] ?: @"(无)");
        dispatch_async(dispatch_get_main_queue(), ^{
            WXPresentChooser(url, cands, options, completion);
        });
        return YES;
    } @catch (NSException *e) {
        WXLOG(@"拦截异常 %@", e.reason);
        return NO;
    }
}

#pragma mark - 运行时挂钩

static BOOL (*o_app_openURL_opts)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)) = NULL;
static BOOL (*o_app_openURL)(id, SEL, NSURL *) = NULL;
static BOOL (*o_app__openURL_opts)(id, SEL, NSURL *, id) = NULL;
static BOOL (*o_lsw_openURL)(id, SEL, NSURL *) = NULL;
static BOOL (*o_lsw_openURL_opts)(id, SEL, NSURL *, id) = NULL;
static BOOL (*o_lsw_openSensitive)(id, SEL, NSURL *, id) = NULL;
static BOOL (*o_ext_openURL)(id, SEL, NSURL *, void (^)(BOOL)) = NULL;

static BOOL h_app_openURL_opts(id self, SEL _cmd, NSURL *url, NSDictionary *opts, void (^cb)(BOOL)) {
    if (WXTryIntercept(url, opts, cb, @"UIApplication openURL:options:")) return YES;
    if (!o_app_openURL_opts) return NO;
    gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
    BOOL r = o_app_openURL_opts(self, _cmd, url, opts, cb);
    gWXBusy = NO;
    return r;
}

static BOOL h_app_openURL(id self, SEL _cmd, NSURL *url) {
    if (WXTryIntercept(url, @{}, nil, @"UIApplication openURL:")) return YES;
    if (!o_app_openURL) return NO;
    gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
    BOOL r = o_app_openURL(self, _cmd, url);
    gWXBusy = NO;
    return r;
}

static BOOL h_app__openURL_opts(id self, SEL _cmd, NSURL *url, id opts) {
    if (WXTryIntercept(url, [opts isKindOfClass:[NSDictionary class]] ? opts : @{}, nil, @"UIApplication _openURL:options:")) return YES;
    if (!o_app__openURL_opts) return NO;
    gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
    BOOL r = o_app__openURL_opts(self, _cmd, url, opts);
    gWXBusy = NO;
    return r;
}

static BOOL h_lsw_openURL(id self, SEL _cmd, NSURL *url) {
    if (WXTryIntercept(url, @{}, nil, @"LSWorkspace openURL:")) return YES;
    if (!o_lsw_openURL) return NO;
    gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
    BOOL r = o_lsw_openURL(self, _cmd, url);
    gWXBusy = NO;
    return r;
}

static BOOL h_lsw_openURL_opts(id self, SEL _cmd, NSURL *url, id opts) {
    if (WXTryIntercept(url, [opts isKindOfClass:[NSDictionary class]] ? opts : @{}, nil, @"LSWorkspace openURL:withOptions:")) return YES;
    if (!o_lsw_openURL_opts) return NO;
    gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
    BOOL r = o_lsw_openURL_opts(self, _cmd, url, opts);
    gWXBusy = NO;
    return r;
}

static BOOL h_lsw_openSensitive(id self, SEL _cmd, NSURL *url, id opts) {
    if (WXTryIntercept(url, [opts isKindOfClass:[NSDictionary class]] ? opts : @{}, nil, @"LSWorkspace openSensitiveURL:withOptions:")) return YES;
    if (!o_lsw_openSensitive) return NO;
    gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
    BOOL r = o_lsw_openSensitive(self, _cmd, url, opts);
    gWXBusy = NO;
    return r;
}

static BOOL h_ext_openURL(id self, SEL _cmd, NSURL *url, void (^cb)(BOOL)) {
    if (WXTryIntercept(url, @{}, cb, @"NSExtensionContext openURL:")) return YES;
    if (!o_ext_openURL) return NO;
    gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
    BOOL r = o_ext_openURL(self, _cmd, url, cb);
    gWXBusy = NO;
    return r;
}

static BOOL (*o_app_canOpenURL)(id, SEL, NSURL *) = NULL;
static BOOL (*o_lsw_openURL_bid)(id, SEL, NSURL *, id) = NULL;
static BOOL (*o_lsw_openURL_bid_unlock)(id, SEL, NSURL *, id, BOOL) = NULL;

static BOOL h_app_canOpenURL(id self, SEL _cmd, NSURL *url) {
    BOOL r = o_app_canOpenURL ? o_app_canOpenURL(self, _cmd, url) : NO;
    if (!gWXBusy && WXIsTargetURL(url)) WXLOG(@"CAN canOpenURL %@ -> %d", url.absoluteString, r);
    return r;
}

static BOOL h_lsw_openURL_bid(id self, SEL _cmd, NSURL *url, id bid) {
    if (WXTryIntercept(url, @{}, nil, [NSString stringWithFormat:@"LSWorkspace openURL:withBundleIdentifier: %@", bid])) return YES;
    if (!o_lsw_openURL_bid) return NO;
    gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
    BOOL r = o_lsw_openURL_bid(self, _cmd, url, bid);
    gWXBusy = NO;
    return r;
}

static BOOL h_lsw_openURL_bid_unlock(id self, SEL _cmd, NSURL *url, id bid, BOOL allow) {
    if (WXTryIntercept(url, @{}, nil, [NSString stringWithFormat:@"LSWorkspace openURL:withBundleIdentifier:allowUnlock: %@", bid])) return YES;
    if (!o_lsw_openURL_bid_unlock) return NO;
    gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
    BOOL r = o_lsw_openURL_bid_unlock(self, _cmd, url, bid, allow);
    gWXBusy = NO;
    return r;
}

static void WXInstallHook(Class cls, NSString *selName, IMP newImp, IMP *outOrig, NSString *tag) {
    if (!cls) { WXLOG(@"挂钩跳过：类不存在 %@", tag); return; }
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { WXLOG(@"挂钩跳过：方法不存在 %@", tag); return; }
    IMP old = method_setImplementation(m, newImp);
    if (outOrig) *outOrig = old;
    WXLOG(@"挂钩成功：%@", tag);
}

static BOOL gWXLSHooked = NO;

static void WXInstallHooks(void) {
    static BOOL appDone = NO;
    if (!appDone) {
        appDone = YES;
        Class app = NSClassFromString(@"UIApplication");
        WXInstallHook(app, @"openURL:options:completionHandler:", (IMP)h_app_openURL_opts, (IMP *)&o_app_openURL_opts, @"UIApplication openURL:options:completionHandler:");
        WXInstallHook(app, @"openURL:", (IMP)h_app_openURL, (IMP *)&o_app_openURL, @"UIApplication openURL:");
        WXInstallHook(app, @"_openURL:options:", (IMP)h_app__openURL_opts, (IMP *)&o_app__openURL_opts, @"UIApplication _openURL:options:");
        WXInstallHook(app, @"canOpenURL:", (IMP)h_app_canOpenURL, (IMP *)&o_app_canOpenURL, @"UIApplication canOpenURL:");
        Class ext = NSClassFromString(@"NSExtensionContext");
        WXInstallHook(ext, @"openURL:completionHandler:", (IMP)h_ext_openURL, (IMP *)&o_ext_openURL, @"NSExtensionContext openURL:completionHandler:");
    }
    if (!gWXLSHooked) {
        Class lsw = NSClassFromString(@"LSApplicationWorkspace");
        if (lsw) {
            gWXLSHooked = YES;
            WXInstallHook(lsw, @"openURL:", (IMP)h_lsw_openURL, (IMP *)&o_lsw_openURL, @"LSWorkspace openURL:");
            WXInstallHook(lsw, @"openURL:withOptions:", (IMP)h_lsw_openURL_opts, (IMP *)&o_lsw_openURL_opts, @"LSWorkspace openURL:withOptions:");
            WXInstallHook(lsw, @"openSensitiveURL:withOptions:", (IMP)h_lsw_openSensitive, (IMP *)&o_lsw_openSensitive, @"LSWorkspace openSensitiveURL:withOptions:");
            WXInstallHook(lsw, @"openURL:withBundleIdentifier:", (IMP)h_lsw_openURL_bid, (IMP *)&o_lsw_openURL_bid, @"LSWorkspace openURL:withBundleIdentifier:");
            WXInstallHook(lsw, @"openURL:withBundleIdentifier:allowUnlock:", (IMP)h_lsw_openURL_bid_unlock, (IMP *)&o_lsw_openURL_bid_unlock, @"LSWorkspace openURL:withBundleIdentifier:allowUnlock:");
        }
    }
}

#pragma mark - SpringBoard 层的 URL 路由拦截

static UIWindow *gWXOverlay = nil;
static volatile BOOL gWXOverlayVisible = NO;
static NSString *const kWXGuard = @"/var/mobile/wxchooser.guard";
static BOOL gWXGuardTripped = NO;

static id gWXPendingReq = nil;
static id gWXPendingSelf = nil;
static id gWXPendingValidator = nil;
static unsigned long long gWXPendingOpts = 0;
static SEL gWXPendingCmd = NULL;
static BOOL WXReplayPending(void);
static void WXSetGuard(BOOL on) {
    @try {
        if (on) [@"1" writeToFile:kWXGuard atomically:YES encoding:NSUTF8StringEncoding error:nil];
        else [[NSFileManager defaultManager] removeItemAtPath:kWXGuard error:nil];
    } @catch (NSException *e) {}
}
static BOOL (*o_router_openURL)(id, SEL, NSURL *) = NULL;
static BOOL (*o_router_openSensitive)(id, SEL, NSURL *) = NULL;

// 不再在 SpringBoard 进程里直接调 SBS（那会就地崩溃）。改为写命令文件 + 拉起独立启动器进程执行。
static NSString *WXOpenerPath(void) {
    // 启动器和宿主 dylib 同目录，用自身路径推导，绕开 roothide 虚拟根
    static NSString *cached = nil;
    if (cached) return cached;
    @try {
        void *sym = (void *)&WXWriteLog;
        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (dladdr(sym, &info) && info.dli_fname) {
            NSString *me = [NSString stringWithUTF8String:info.dli_fname];
            cached = [[me stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"wxchooseropen"];
            WXLOG(@"自身路径 %@ → 启动器 %@", me, cached);
        }
    } @catch (NSException *e) {}
    return cached;
}

static volatile BOOL gWXLSFired = NO;

// 在 SpringBoard 进程内异步拉起（LS 工作区，无外部进程、无同步等待，不阻塞主线程）
static void WXLSAsyncOpen(NSString *bid, NSURL *url) {
    @try {
        Class c = NSClassFromString(@"LSApplicationWorkspace");
        if (!c) { WXLOG(@"LS 工作区类缺失"); return; }
        id ws = ((id (*)(id, SEL))objc_msgSend)(c, sel_getUid("defaultWorkspace"));
        if (!ws) { WXLOG(@"LS 工作区实例缺失"); return; }
        if (url) {
            SEL s = sel_getUid("openURL:configuration:completionHandler:");
            if ([ws respondsToSelector:s]) {
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(ws, s, url, nil, ^(id x, NSError *e) {
                    gWXLSFired = YES;
                    WXLOG(@"LS 开URL 回调 ok=%@ err=%@", x ?: @"nil", e.localizedDescription ?: @"无");
                });
                WXLOG(@"LS 异步开URL 已提交 %@", url.absoluteString);
                return;
            }
        }
        SEL s2 = sel_getUid("openApplicationWithBundleIdentifier:configuration:completionHandler:");
        if ([ws respondsToSelector:s2]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(ws, s2, bid, nil, ^(id x, NSError *e) {
                gWXLSFired = YES;
                WXLOG(@"LS 开包 回调 ok=%@ err=%@", x ?: @"nil", e.localizedDescription ?: @"无");
            });
            WXLOG(@"LS 异步开包 已提交 %@", bid);
            return;
        }
        WXLOG(@"LS 无异步接口");
    } @catch (NSException *e) { WXLOG(@"LS 异步拉起异常 %@", e.reason); }
}

static BOOL WXSBLaunchByBundle(NSURL *url, NSString *bid) {
    @try {
        if (!bid.length) return NO;
        gWXBusy = YES; gWXBusyAt = CFAbsoluteTimeGetCurrent();
        gWXSuppressUntil = CFAbsoluteTimeGetCurrent() + 3.0;

        WXLOG(@"外部启动器接管 bid=%@ url=%@", bid, url.absoluteString ?: @"(无)");

        NSMutableArray *paths = [NSMutableArray array];
        NSString *selfPath = WXOpenerPath();
        if (selfPath) [paths addObject:selfPath];
        [paths addObject:@"/usr/bin/wxchooseropen"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *bin = nil;
        for (NSString *p in paths) {
            BOOL exe = [fm isExecutableFileAtPath:p];
            WXLOG(@"候选 %@ 可执行=%d", p, exe);
            if (exe) { bin = p; break; }
        }
        if (!bin) { WXLOG(@"全部候选都不可执行"); gWXBusy = NO; return NO; }
        [fm setAttributes:@{NSFilePosixPermissions:@(0755)} ofItemAtPath:bin error:nil];

        NSString *cmdPath = @"/var/mobile/wxchooser_cmd.plist";
        NSDictionary *cmd = @{ @"bid" : bid, @"url" : (url.absoluteString ?: @"") };
        BOOL wrote = [cmd writeToFile:cmdPath atomically:YES];
        WXLOG(@"命令文件 %@ 已写=%d", cmdPath, wrote);

        const char *path = bin.UTF8String;
        char *const argsv[] = { (char *)path, NULL };
        char *const envv[] = { (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin", (char *)"HOME=/var/mobile", NULL };
        pid_t pid = 0;
        int rc = posix_spawn(&pid, path, NULL, NULL, argsv, envv);
        WXLOG(@"spawn %@ rc=%d errno=%d pid=%d", bin, rc, errno, (int)pid);
        gWXBusy = NO;
        return (rc == 0);
    } @catch (NSException *e) {
        gWXBusy = NO;
        WXLOG(@"拉起动作异常 %@", e.reason);
        return NO;
    }
}

// 重放 SpringBoard 自己那条被拦下的启动事务（不经过任何外部接口）
static BOOL WXReplayInner(void);

static BOOL WXReplayPending(void) {
    __block BOOL ok = NO;
    dispatch_block_t blk = ^{ ok = WXReplayInner(); };
    if ([NSThread isMainThread]) blk();
    else dispatch_sync(dispatch_get_main_queue(), blk);
    return ok;
}

static BOOL WXReplayInner(void) {
    if (!gWXPendingReq || !o_sbmw_execute) { WXLOG(@"重放失败：没有保存的事务"); return NO; }
    id req = gWXPendingReq;
    id self0 = gWXPendingSelf;
    SEL cmd = gWXPendingCmd;
    unsigned long long opts = gWXPendingOpts;
    id val = gWXPendingValidator;
    @try {
        WXLOG(@"重放原始启动事务…");
        o_sbmw_execute(self0, cmd, req, opts, val);
        WXLOG(@"重放已执行，无异常");
        return YES;
    } @catch (NSException *e) {
        WXLOG(@"重放异常 %@", e.reason);
        return NO;
    }
}

static void WXSBHideOverlay(void) {
    @try {
        WXRemoveSheetNow();
        if (gWXHostVC && gWXHostVC.presentedViewController) {
            [gWXHostVC dismissViewControllerAnimated:NO completion:nil];
        }
        gWXOverlayVisible = NO;
        WXLOG(@"SB 弹框已关闭");
    } @catch (NSException *e) {
        WXLOG(@"关闭弹框异常 %@", e.reason);
    }
}

static BOOL WXSBEnsureOverlay(void) {
    if (gWXHostVC) return YES;
    @try {
        // 只用 SpringBoard 自己已有的窗口，绝不自建窗口、绝不挂 SystemAperture 场景
        UIWindow *host = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.hidden && w.rootViewController && w.windowLevel < UIWindowLevelAlert) { host = w; break; }
        }
        if (!host) {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.rootViewController && w.windowLevel < UIWindowLevelAlert) { host = w; break; }
            }
        }
        if (!host) { WXLOG(@"SB 找不到承载窗口，放弃弹框"); return NO; }
        gWXHostVC = host.rootViewController;
        WXLOG(@"SB 弹框宿主就绪 %@ level=%.0f", NSStringFromClass([host class]), host.windowLevel);
        return gWXHostVC != nil;
    } @catch (NSException *e) {
        WXLOG(@"找宿主异常 %@", e.reason);
        return NO;
    }
}

static void WXSBShowChooser(NSURL *url, NSString *entry, void (^fallback)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSURL *probe = url ?: [NSURL URLWithString:@"weixin://"];
            NSArray *cands = WXCandidatesForURL(probe);
            WXLOG(@"SB 弹框（%@）%@ 候选 %lu", entry, url.absoluteString ?: @"(无 URL)", (unsigned long)cands.count);
            if (!WXSBEnsureOverlay()) {
                WXLOG(@"SB 无法建窗，改为放行");
                if (fallback) fallback();
                return;
            }
            WXSetGuard(YES);
            gWXOverlayVisible = YES;
            UIViewController *top = gWXHostVC;
            while (top.presentedViewController) top = top.presentedViewController;

            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"打开微信"
                                                                       message:@"选择要跳转的微信"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
            NSArray *snapshot = cands;
            if (url) {
                snapshot = [cands sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    BOOL ao = [a[@"bid"] isEqualToString:@"com.tencent.xin"];
                    BOOL bo = [b[@"bid"] isEqualToString:@"com.tencent.xin"];
                    if (ao == bo) return NSOrderedSame;
                    return ao ? NSOrderedAscending : NSOrderedDescending;
                }];
            }
            if (gWXHostVC.view && WXShowSheet(gWXHostVC.view, snapshot, ^(NSDictionary *cand) {
                    NSString *bid = cand[@"bid"];
                    WXLOG(@"用户选择(自绘)：%@ (%@)", cand[@"name"], bid);
                    gWXDialoging = NO;
                    gWXCooldownUntil = CFAbsoluteTimeGetCurrent() + 2.5;
                    WXSBHideOverlay();
                    NSURL *u2 = url;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        WXLOG(@"后台线程开始拉起 %@", bid);
                        WXSBLaunchByBundle(u2, bid);
                    });
                }, ^{
                    WXLOG(@"用户取消(自绘)");
                    gWXDialoging = NO;
                    gWXCooldownUntil = CFAbsoluteTimeGetCurrent() + 2.5;
                    WXSBHideOverlay();
                })) {
                WXSetGuard(NO);
                WXLOG(@"自绘菜单已呈现");
                return;
            }

            for (NSDictionary *cand in snapshot) {
                NSString *bid = cand[@"bid"];
                NSString *nm = cand[@"name"] ?: bid;
                UIAlertAction *act = [UIAlertAction actionWithTitle:nm style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    WXLOG(@"用户选择：%@ (%@)", nm, bid);
                    gWXDialoging = NO;
                    gWXCooldownUntil = CFAbsoluteTimeGetCurrent() + 2.5;
                    WXSBHideOverlay();
                    NSURL *u2 = url;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        WXLOG(@"后台线程开始拉起 %@", bid);
                        WXSBLaunchByBundle(u2, bid);
                    });
                }];
                WXStyleAction(act, cand, nm);
                [ac addAction:act];
            }
            [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
                WXLOG(@"用户取消");
                gWXDialoging = NO;
                gWXCooldownUntil = CFAbsoluteTimeGetCurrent() + 2.5;
                WXSBHideOverlay();
            }]];
            [gWXHostVC presentViewController:ac animated:NO completion:^{
                WXSetGuard(NO);
                WXLOG(@"SB 弹框已呈现");
            }];
        } @catch (NSException *e) {
            WXLOG(@"SB 弹框异常 %@", e.reason);
            gWXDialoging = NO;
            if (fallback) fallback();
        }
    });
}

static BOOL h_router_openURL(id self, SEL _cmd, NSURL *url) {
    @try {
        WXLOG(@"[HFOpenURLRouter openURL:] %@", url.absoluteString);
        if (!gWXBusy && url && WXIsTargetURL(url) && !WXIsSelfWeChat()) {
            NSURL *u = url;
            WXSBShowChooser(u, @"openURL:", ^{
                if (o_router_openURL) o_router_openURL(self, _cmd, u);
            });
            return YES;
        }
    } @catch (NSException *e) {
        WXLOG(@"openURL 拦截异常 %@", e.reason);
    }
    return o_router_openURL ? o_router_openURL(self, _cmd, url) : NO;
}

static BOOL h_router_openSensitive(id self, SEL _cmd, NSURL *url) {
    @try {
        WXLOG(@"[HFOpenURLRouter openSensitiveURL:] %@", url.absoluteString);
        if (!gWXBusy && url && WXIsTargetURL(url) && !WXIsSelfWeChat()) {
            NSURL *u = url;
            WXSBShowChooser(u, @"openSensitiveURL:", ^{
                if (o_router_openSensitive) o_router_openSensitive(self, _cmd, u);
            });
            return YES;
        }
    } @catch (NSException *e) {
        WXLOG(@"openSensitive 拦截异常 %@", e.reason);
    }
    return o_router_openSensitive ? o_router_openSensitive(self, _cmd, url) : NO;
}

#pragma mark - 系统层：SBMainWorkspace 启动事务拦截


static NSURL *WXActionURL(id o) {
    NSString *cn = NSStringFromClass([o class]) ?: @"";
    if (![cn containsString:@"UIOpenURLAction"]) return nil;
    for (NSString *key in @[@"URL", @"url"]) {
        SEL sel = NSSelectorFromString(key);
        if ([o respondsToSelector:sel]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(o, sel);
            if ([v isKindOfClass:[NSURL class]]) return (NSURL *)v;
        }
    }
    return nil;
}

static NSURL *WXLookupURL(id obj, int depth) {
    if (!obj || depth > 3) return nil;
    NSURL *u = WXActionURL(obj);
    if (u) return u;
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id x in (NSArray *)obj) { NSURL *r = WXLookupURL(x, depth + 1); if (r) return r; }
        return nil;
    }
    if ([obj isKindOfClass:[NSSet class]]) {
        for (id x in (NSSet *)obj) { NSURL *r = WXLookupURL(x, depth + 1); if (r) return r; }
        return nil;
    }
    for (NSString *key in @[@"actions", @"applicationSceneEntities", @"entities", @"sceneSettings",
                            @"applicationSceneSettings", @"context", @"settings"]) {
        SEL sel = NSSelectorFromString(key);
        if ([obj respondsToSelector:sel]) {
            @try {
                id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
                NSURL *r = WXLookupURL(v, depth + 1);
                if (r) return r;
            } @catch (NSException *e) {}
        }
    }
    return nil;
}

static NSString *WXBundleFromRequest(id req) {
    for (NSString *key in @[@"applicationSceneEntities", @"entities"]) {
        SEL sel = NSSelectorFromString(key);
        if (![req respondsToSelector:sel]) continue;
        id arr = nil;
        @try { arr = ((id (*)(id, SEL))objc_msgSend)(req, sel); } @catch (NSException *e) {}
        if (![arr isKindOfClass:[NSArray class]]) continue;
        for (id entity in (NSArray *)arr) {
            for (NSString *k2 in @[@"application", @"scene"]) {
                SEL s2 = NSSelectorFromString(k2);
                if (![entity respondsToSelector:s2]) continue;
                id v = nil;
                @try { v = ((id (*)(id, SEL))objc_msgSend)(entity, s2); } @catch (NSException *e) { continue; }
                NSString *bid = nil;
                if ([v respondsToSelector:NSSelectorFromString(@"bundleIdentifier")]) {
                    bid = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"bundleIdentifier"));
                } else if ([v respondsToSelector:NSSelectorFromString(@"identifier")]) {
                    id sid = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"identifier"));
                    if ([sid isKindOfClass:[NSString class]]) bid = (NSString *)sid;
                }
                if ([bid isKindOfClass:[NSString class]] && bid.length) return bid;
            }
        }
    }
    return nil;
}

static NSString *WXScanForWeixinString(id obj, int depth, int *budget) {
    if (!obj || depth > 6 || *budget <= 0) return nil;
    (*budget)--;
    @try {
        if ([obj isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)obj;
            if (s.length > 5 && s.length < 900 && [s rangeOfString:@"weixin://" options:NSCaseInsensitiveSearch].location != NSNotFound) return s;
            return nil;
        }
        if ([obj isKindOfClass:[NSURL class]]) {
            NSString *s = [(NSURL *)obj absoluteString];
            if ([s rangeOfString:@"weixin" options:NSCaseInsensitiveSearch].location != NSNotFound) return s;
            return nil;
        }
        if ([obj isKindOfClass:[NSArray class]]) {
            for (id x in (NSArray *)obj) { NSString *r = WXScanForWeixinString(x, depth + 1, budget); if (r) return r; }
            return nil;
        }
        if ([obj isKindOfClass:[NSSet class]]) {
            for (id x in (NSSet *)obj) { NSString *r = WXScanForWeixinString(x, depth + 1, budget); if (r) return r; }
            return nil;
        }
        if ([obj isKindOfClass:[NSDictionary class]]) {
            for (id k in (NSDictionary *)obj) { NSString *r = WXScanForWeixinString([(NSDictionary *)obj objectForKey:k], depth + 1, budget); if (r) return r; }
            return nil;
        }
        Class cls = object_getClass(obj);
        if (!cls) return nil;
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        if (!ivars) return nil;
        NSString *found = nil;
        for (unsigned int i = 0; i < n && !found; i++) {
            const char *t = ivar_getTypeEncoding(ivars[i]);
            if (!t || t[0] != '@') continue;
            @try {
                id v = object_getIvar(obj, ivars[i]);
                if (v) found = WXScanForWeixinString(v, depth + 1, budget);
            } @catch (NSException *e) {}
        }
        free(ivars);
        return found;
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *WXScanForBundleString(id obj, int depth, int *budget) {
    if (!obj || depth > 3 || *budget <= 0) return nil;
    (*budget)--;
    @try {
        if ([obj isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)obj;
            if ([s hasPrefix:@"com.tencent.xin"]) return s;
            return nil;
        }
        if ([obj isKindOfClass:[NSArray class]]) {
            for (id x in (NSArray *)obj) { NSString *r = WXScanForBundleString(x, depth + 1, budget); if (r) return r; }
            return nil;
        }
        if ([obj isKindOfClass:[NSSet class]]) {
            for (id x in (NSSet *)obj) { NSString *r = WXScanForBundleString(x, depth + 1, budget); if (r) return r; }
            return nil;
        }
        if ([obj isKindOfClass:[NSDictionary class]]) {
            for (id k in (NSDictionary *)obj) { NSString *r = WXScanForBundleString([(NSDictionary *)obj objectForKey:k], depth + 1, budget); if (r) return r; }
            return nil;
        }
        Class cls = object_getClass(obj);
        if (!cls) return nil;
        unsigned int n = 0;
        Ivar *ivars = class_copyIvarList(cls, &n);
        if (!ivars) return nil;
        NSString *found = nil;
        for (unsigned int i = 0; i < n && !found; i++) {
            const char *t = ivar_getTypeEncoding(ivars[i]);
            if (!t || t[0] != '@') continue;
            @try {
                id v = object_getIvar(obj, ivars[i]);
                if (v) found = WXScanForBundleString(v, depth + 1, budget);
            } @catch (NSException *e) {}
        }
        free(ivars);
        return found;
    } @catch (NSException *e) {
        return nil;
    }
}

static NSString *WXWeixinURLFromString(NSString *s) {
    if (!s.length) return nil;
    NSRange r = [s rangeOfString:@"weixin" options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return nil;
    NSUInteger i = r.location;
    NSMutableString *out = [NSMutableString string];
    while (i < s.length) {
        unichar c = [s characterAtIndex:i];
        if (c == ' ' || c == '"' || c == '\'' || c == '>' || c == '<' || c == ')' || c == '\n' || c == '\\') break;
        [out appendFormat:@"%C", c];
        i++;
    }
    return out.length > 6 ? out : nil;
}

static void h_sbmw_execute(id self, SEL _cmd, id request, unsigned long long options, id validator) {
    BOOL intercept = NO;
    BOOL shouldShow = NO;
    NSURL *hitURL = nil;
    @try {
        if (!gWXBusy && !gWXOverlayVisible && !gWXGuardTripped && CFAbsoluteTimeGetCurrent() > gWXSuppressUntil) {
            NSString *bid = WXBundleFromRequest(request);
            NSURL *u = WXLookupURL(request, 0);
            BOOL bidKnown = [bid hasPrefix:@"com.tencent.xin"];
            if (!bidKnown) {
                int b2 = 400;
                NSString *sb2 = WXScanForBundleString(request, 0, &b2);
                if (sb2) { bid = sb2; bidKnown = YES; WXLOG(@"  深度扫描到目标包：%@", sb2); }
            }
            NSString *desc = nil;
            static int dbgCount = 0;
            if (!bidKnown && dbgCount < 150) {
                dbgCount++;
                if (!desc) { @try { desc = [request description]; } @catch (NSException *e) {} }
                if (desc.length) WXLOG(@"  事务样本 %@", [desc substringToIndex:MIN(desc.length, 150u)]);
            }
            BOOL looksWX = bidKnown;
            if (!looksWX) {
                @try { desc = [request description]; } @catch (NSException *e) {}
                looksWX = [desc containsString:@"com.tencent.xin"];
                if (looksWX) { bidKnown = YES; WXLOG(@"  从事务描述认得目标微信"); }
                if (!u && desc && [desc containsString:@"SBUIApplicationIconLaunchEventLabel"]) {
                    WXLOG(@"  桌面图标启动（无 URL），放行不弹框");
                    looksWX = NO;
                    bidKnown = NO;
                }
            }
            BOOL urlLike = (u && WXIsTargetURL(u))
                        || (desc && [desc.lowercaseString containsString:@"weixin"])
                        || (u && WXIsWeChatWebURL(u));
            if (looksWX && (urlLike || bidKnown)) {
                if (!desc) { @try { desc = [request description]; } @catch (NSException *e) {} }
                if (!u) {
                    int budget = 1500;
                    NSString *raw = WXScanForWeixinString(request, 0, &budget);
                    if (!raw) raw = WXWeixinURLFromString(desc);
                    if (raw) {
                        NSURL *cand = [NSURL URLWithString:raw];
                        if (cand && WXIsTargetURL(cand)) { u = cand; WXLOG(@"  取到真实 URL：%@", raw); }
                        else WXLOG(@"  取到的不是有效微信 URL：%@", raw);
                    }
                }
                if (u) gWXLastWXURL = u.absoluteString;
                static CFAbsoluteTime lastHit = 0;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                BOOL tooSoon = (now - lastHit < 1.2);
                BOOL busyByDialog = (gWXDialoging || now < gWXCooldownUntil);
                if (busyByDialog) {
                    WXLOG(@"弹框进行中/刚选完，静默拒绝重复请求 url=%@", u.absoluteString ?: @"(无)");
                    if ([request respondsToSelector:NSSelectorFromString(@"declineWithReason:")]) {
                        @try {
                            ((void (*)(id, SEL, id))objc_msgSend)(request, NSSelectorFromString(@"declineWithReason:"), @"WXChooser 静默接管");
                            WXLOG(@"  已静默拒绝重复事务");
                        } @catch (NSException *e) {}
                    }
                    intercept = YES;
                    hitURL = u;
                } else if (!tooSoon && WXSBEnsureOverlay()) {
                    lastHit = now;
                    gWXDialoging = YES;
                    shouldShow = YES;
                    WXLOG(@"★ SB 拦到拉起微信：bid=%@ url=%@", bid ?: @"(未知)", u.absoluteString ?: @"(无)");
                    gWXPendingReq = request;
                    gWXPendingSelf = self;
                    gWXPendingCmd = _cmd;
                    gWXPendingOpts = options;
                    gWXPendingValidator = validator;
                    if ([request respondsToSelector:NSSelectorFromString(@"declineWithReason:")]) {
                        @try {
                            ((void (*)(id, SEL, id))objc_msgSend)(request, NSSelectorFromString(@"declineWithReason:"), @"WXChooser 接管");
                            WXLOG(@"  已拒绝原启动事务");
                        } @catch (NSException *e) { WXLOG(@"  拒绝失败 %@", e.reason); }
                    }
                    intercept = YES;
                    hitURL = u;
                } else if (tooSoon) {
                    WXLOG(@"SB 短时间重复命中，静默拒绝（不放行）");
                    if ([request respondsToSelector:NSSelectorFromString(@"declineWithReason:")]) {
                        @try {
                            ((void (*)(id, SEL, id))objc_msgSend)(request, NSSelectorFromString(@"declineWithReason:"), @"WXChooser 静默接管");
                            WXLOG(@"  已静默拒绝重复事务");
                        } @catch (NSException *e) {}
                    }
                    intercept = YES;
                    hitURL = u;
                } else {
                    WXLOG(@"SB 建窗失败，静默拒绝（不放行）");
                    if ([request respondsToSelector:NSSelectorFromString(@"declineWithReason:")]) {
                        @try {
                            ((void (*)(id, SEL, id))objc_msgSend)(request, NSSelectorFromString(@"declineWithReason:"), @"WXChooser 静默接管");
                        } @catch (NSException *e) {}
                    }
                    intercept = YES;
                    hitURL = u;
                }
            }
        }
    } @catch (NSException *e) {
        WXLOG(@"SBMainWorkspace 拦截异常 %@", e.reason);
    }
    if (intercept) {
        if (!hitURL && gWXLastWXURL.length) {
            NSURL *memo = [NSURL URLWithString:gWXLastWXURL];
            if (memo && WXIsTargetURL(memo)) { hitURL = memo; WXLOG(@"  用记忆的票据 URL：%@", memo.absoluteString); }
        }
        if (shouldShow) WXSBShowChooser(hitURL, @"SBMainWorkspace", nil);
        else WXLOG(@"静默拦截已完成，不重复弹框");
        return;
    }
    if (o_sbmw_execute) {
        @try { o_sbmw_execute(self, _cmd, request, options, validator); }
        @catch (NSException *e) { WXLOG(@"调用原方法异常 %@", e.reason); }
    }
}

static void WXInstallWorkspaceHook(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    Class ws = NSClassFromString(@"SBMainWorkspace");
    if (!ws) { WXLOG(@"SBMainWorkspace 不存在"); return; }
    NSString *selName = @"_executeTransitionRequest:options:validator:";
    Method m = class_getInstanceMethod(ws, NSSelectorFromString(selName));
    if (!m) { WXLOG(@"挂钩跳过：SBMainWorkspace %@ 不存在", selName); return; }
    o_sbmw_execute = (void (*)(id, SEL, id, unsigned long long, id))method_getImplementation(m);
    method_setImplementation(m, (IMP)h_sbmw_execute);
    WXLOG(@"挂钩成功：SBMainWorkspace _executeTransitionRequest:options:validator:");
}

static void WXInstallRouterHooks(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    Class router = NSClassFromString(@"HFOpenURLRouter");
    if (!router) { WXLOG(@"HFOpenURLRouter 不存在"); return; }
    SEL s1 = NSSelectorFromString(@"openURL:");
    Method m1 = class_getInstanceMethod(router, s1);
    if (m1 && method_getNumberOfArguments(m1) == 3) {
        o_router_openURL = (BOOL (*)(id, SEL, NSURL *))method_setImplementation(m1, (IMP)h_router_openURL);
        WXLOG(@"挂钩成功：HFOpenURLRouter openURL:");
    } else {
        WXLOG(@"挂钩跳过：HFOpenURLRouter openURL: 参数数不符");
    }
    SEL s2 = NSSelectorFromString(@"openSensitiveURL:");
    Method m2 = class_getInstanceMethod(router, s2);
    if (m2 && method_getNumberOfArguments(m2) == 3) {
        o_router_openSensitive = (BOOL (*)(id, SEL, NSURL *))method_setImplementation(m2, (IMP)h_router_openSensitive);
        WXLOG(@"挂钩成功：HFOpenURLRouter openSensitiveURL:");
    } else {
        WXLOG(@"挂钩跳过：HFOpenURLRouter openSensitiveURL: 参数数不符");
    }
}

__attribute__((constructor)) static void WXInit(void) {
    WXLOG(@"LOADED in %@ (%@)", WXSelfBundleID(), WXIsSelfWeChat() ? @"微信本体" : @"其他进程");
    WXInstallHooks();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    WXSheetDismissCallback, CFSTR("com.fengxin.wxchooser.sheetdismiss"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    if ([WXSelfBundleID() isEqualToString:@"com.apple.springboard"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:kWXGuard]) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kWXGuard error:nil];
            NSDate *mt = attrs[NSFileModificationDate];
            double age = mt ? [[NSDate date] timeIntervalSinceDate:mt] : 9999.0;
            if (age >= 0 && age < 90.0) {
                gWXGuardTripped = YES;
                WXLOG(@"⚠ 护栏文件较新（%.0f 秒前），本会话不再弹框（直接放行）", age);
            } else {
                WXLOG(@"清理过期护栏文件（%.0f 秒），恢复正常弹框", age);
            }
            WXSetGuard(NO);
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        WXDarwinCallback, CFSTR("com.fengxin.wxchooser.launch"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        WXLaunchingCallback, CFSTR("com.fengxin.wxchooser.launching"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        for (NSString *nm in @[@"com.fengxin.wxchooser.loaded.chinaunicom",
                               @"com.fengxin.wxchooser.loaded.umbra",
                               @"com.fengxin.wxchooser.loaded.safariview",
                               @"com.fengxin.wxchooser.loaded.webcontent",
                               @"com.fengxin.wxchooser.loaded.safari",
                               @"com.fengxin.wxchooser.loaded.lsd"]) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                            WXPingCallback, (__bridge CFStringRef)nm,
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        }
        WXLoadSBS();
        WXLOG(@"SB: 已注册代办启动监听 + 报到监听");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WXInstallRouterHooks();
            WXInstallWorkspaceHook();
        });
    } else {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            if (gWXBusy || gWXDialoging) WXLOG(@"回到前台，清理忙碌/弹窗状态");
            gWXBusy = NO;
            gWXDialoging = NO;
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WXPostLoadedPing();
            WXLOG(@"已向 SB 报到：%@", WXSelfBundleID());
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WXInstallHooks();
        if ([WXSelfBundleID() containsString:@"WebKit"]) return;
        if (!WXIsSelfWeChat()) {
            @try {
                NSArray *all = WXScanWeChatApps();
                WXLOG(@"自检：识别到 %lu 个微信类应用", (unsigned long)all.count);
                for (NSDictionary *a in all) WXLOG(@"  自检候选：%@ %@ schemes=%@", a[@"bid"], a[@"name"], a[@"schemes"]);
            } @catch (NSException *e) {
                WXLOG(@"自检异常 %@", e.reason);
            }
        }
    });
}
