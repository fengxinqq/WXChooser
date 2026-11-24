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

static void WXWriteLog(NSString *line) {
    NSString *s = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], line];
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kWXLogPath];
        if (!fh) {
            [s writeToFile:kWXLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {
    }
}

#define WXLOG(...) WXWriteLog([NSString stringWithFormat:__VA_ARGS__])

static volatile BOOL gWXBusy = NO;

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
        [out addObject:@{@"bid": bid, @"name": name, @"schemes": schemes}];
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
            [out addObject:@{@"bid": bid, @"name": name.length ? name : bid, @"schemes": schemes}];
        }
        WXLOG(@"LSW: 枚举到 %lu 个微信类应用", (unsigned long)out.count);
    } @catch (NSException *e) {
        WXLOG(@"LSW 异常 %@", e.reason);
    }
    return out;
}

static NSArray<NSDictionary *> *WXCandidatesForURL(NSURL *url) {
    NSArray *all = WXScanWeChatApps();
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
        NSString *uniq = nil;
        NSString *fallback = nil;
        for (NSString *s in a[@"schemes"]) {
            NSString *low = s.lowercaseString;
            if ([counts[low] integerValue] <= 1 && !WXIsWeixinScheme(low)) { uniq = s; break; }
        }
        for (NSString *s in a[@"schemes"]) {
            if (WXIsWeixinScheme(s)) { fallback = s; break; }
        }
        NSMutableDictionary *m = [@{@"bid": bid, @"name": a[@"name"]} mutableCopy];
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
    gWXBusy = YES;
    [[UIApplication sharedApplication] openURL:url options:options ?: @{} completionHandler:^(BOOL ok) {
        if (done) done(ok);
    }];
    gWXBusy = NO;
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
            gWXBusy = YES;
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

static void WXPresentChooser(NSURL *url, NSArray<NSDictionary *> *cands, NSDictionary *options, void (^completion)(BOOL)) {
    UIViewController *top = WXTopViewController();
    if (!top) { WXLOG(@"找不到顶层控制器，直接放行"); completion(YES); return; }

    NSString *msg = cands.count ? @"选择要跳转的微信"
                                : @"没识别到微信 App（可先点“系统默认”继续）";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"打开微信"
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *cand in cands) {
        NSString *title = cand[@"name"] ?: cand[@"bid"];
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            BOOL handled = NO;
            NSString *scheme = cand[@"scheme"];
            if (scheme.length) handled = WXOpenByScheme(url, scheme, ^(BOOL ok) {
                if (!ok) WXLOG(@"scheme 方式打开失败：%@", scheme);
            });
            if (!handled) handled = WXRequestSpringBoardLaunch(url, cand[@"bid"]);
            if (!handled) handled = WXOpenByBundleID(url, cand[@"bid"], nil);
            if (!handled) {
                WXLOG(@"几种方式都失败，回退系统默认，目标=%@", cand[@"bid"]);
                WXOpenPassthrough(url, options, completion);
            } else if (completion) {
                completion(YES);
            }
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"系统默认" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        WXOpenPassthrough(url, options, completion);
    }]];
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
    if (gWXBusy) return NO;
    @try {
        if (!url) return NO;
        NSString *scheme = url.scheme ?: @"";
        NSString *host = url.host ?: @"";
        WXLOG(@"[%@] %@ //%@", entry, scheme.length ? scheme : @"(无)", host);
        if (WXIsSelfWeChat()) return NO;
        if (!WXIsTargetURL(url)) return NO;
        if (!WXIsWeixinScheme(scheme)) {
            WXLOG(@"★ 命中微信 https 链接（Universal Link），无法强制指定 App，仅记录：%@", url.absoluteString);
            return NO;
        }
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
    gWXBusy = YES;
    BOOL r = o_app_openURL_opts(self, _cmd, url, opts, cb);
    gWXBusy = NO;
    return r;
}

static BOOL h_app_openURL(id self, SEL _cmd, NSURL *url) {
    if (WXTryIntercept(url, @{}, nil, @"UIApplication openURL:")) return YES;
    if (!o_app_openURL) return NO;
    gWXBusy = YES;
    BOOL r = o_app_openURL(self, _cmd, url);
    gWXBusy = NO;
    return r;
}

static BOOL h_app__openURL_opts(id self, SEL _cmd, NSURL *url, id opts) {
    if (WXTryIntercept(url, [opts isKindOfClass:[NSDictionary class]] ? opts : @{}, nil, @"UIApplication _openURL:options:")) return YES;
    if (!o_app__openURL_opts) return NO;
    gWXBusy = YES;
    BOOL r = o_app__openURL_opts(self, _cmd, url, opts);
    gWXBusy = NO;
    return r;
}

static BOOL h_lsw_openURL(id self, SEL _cmd, NSURL *url) {
    if (WXTryIntercept(url, @{}, nil, @"LSWorkspace openURL:")) return YES;
    if (!o_lsw_openURL) return NO;
    gWXBusy = YES;
    BOOL r = o_lsw_openURL(self, _cmd, url);
    gWXBusy = NO;
    return r;
}

static BOOL h_lsw_openURL_opts(id self, SEL _cmd, NSURL *url, id opts) {
    if (WXTryIntercept(url, [opts isKindOfClass:[NSDictionary class]] ? opts : @{}, nil, @"LSWorkspace openURL:withOptions:")) return YES;
    if (!o_lsw_openURL_opts) return NO;
    gWXBusy = YES;
    BOOL r = o_lsw_openURL_opts(self, _cmd, url, opts);
    gWXBusy = NO;
    return r;
}

static BOOL h_lsw_openSensitive(id self, SEL _cmd, NSURL *url, id opts) {
    if (WXTryIntercept(url, [opts isKindOfClass:[NSDictionary class]] ? opts : @{}, nil, @"LSWorkspace openSensitiveURL:withOptions:")) return YES;
    if (!o_lsw_openSensitive) return NO;
    gWXBusy = YES;
    BOOL r = o_lsw_openSensitive(self, _cmd, url, opts);
    gWXBusy = NO;
    return r;
}

static BOOL h_ext_openURL(id self, SEL _cmd, NSURL *url, void (^cb)(BOOL)) {
    if (WXTryIntercept(url, @{}, cb, @"NSExtensionContext openURL:")) return YES;
    if (!o_ext_openURL) return NO;
    gWXBusy = YES;
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
    gWXBusy = YES;
    BOOL r = o_lsw_openURL_bid(self, _cmd, url, bid);
    gWXBusy = NO;
    return r;
}

static BOOL h_lsw_openURL_bid_unlock(id self, SEL _cmd, NSURL *url, id bid, BOOL allow) {
    if (WXTryIntercept(url, @{}, nil, [NSString stringWithFormat:@"LSWorkspace openURL:withBundleIdentifier:allowUnlock: %@", bid])) return YES;
    if (!o_lsw_openURL_bid_unlock) return NO;
    gWXBusy = YES;
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
static CFAbsoluteTime gWXSuppressUntil = 0;
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

static BOOL WXSBLaunchByBundle(NSURL *url, NSString *bid) {
    @try {
        if (!bid.length) return NO;
        gWXBusy = YES;
        gWXSuppressUntil = CFAbsoluteTimeGetCurrent() + 8.0;

        if ([bid isEqualToString:@"com.tencent.xin"] && gWXPendingReq) {
            BOOL ok = WXReplayPending();
            WXLOG(@"重放结果 %d", ok);
            if (ok) { gWXBusy = NO; return YES; }
        }

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
        UIViewController *vc = gWXOverlay.rootViewController;
        if (vc.presentedViewController) [vc dismissViewControllerAnimated:NO completion:nil];
        gWXOverlay.hidden = YES;
        gWXOverlayVisible = NO;
        WXLOG(@"SB 窗口已隐藏");
    } @catch (NSException *e) {
        WXLOG(@"隐藏窗口异常 %@", e.reason);
    }
}

static BOOL WXSBEnsureOverlay(void) {
    if (gWXOverlay && gWXOverlay.windowScene) return YES;
    @try {
        UIWindow *w = gWXOverlay;
        if (!w) {
            w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            w.windowLevel = UIWindowLevelAlert + 1;
            w.backgroundColor = [UIColor clearColor];
            w.rootViewController = [[UIViewController alloc] init];
            w.rootViewController.view.backgroundColor = [UIColor clearColor];
        }
        UIWindowScene *sc = nil;
        for (UIScene *cs in [UIApplication sharedApplication].connectedScenes) {
            if ([cs isKindOfClass:[UIWindowScene class]]) { sc = (UIWindowScene *)cs; break; }
        }
        if (!sc) {
            for (UIWindow *win in [UIApplication sharedApplication].windows) {
                if (win.windowScene) { sc = win.windowScene; break; }
            }
        }
        if (!sc) { WXLOG(@"SB 找不到 scene，放弃弹框"); return NO; }
        w.windowScene = sc;
        gWXOverlay = w;
        WXLOG(@"SB 悬浮窗口就绪 level=%.0f scene=%@", w.windowLevel, NSStringFromClass([sc class]));
        return YES;
    } @catch (NSException *e) {
        WXLOG(@"SB 建窗异常 %@", e.reason);
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
            gWXOverlay.hidden = NO;
            gWXOverlayVisible = YES;
            UIViewController *top = gWXOverlay.rootViewController;
            while (top.presentedViewController) top = top.presentedViewController;

            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"打开微信"
                                                                       message:@"选择要跳转的微信"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
            NSArray *snapshot = cands;
            for (NSDictionary *cand in snapshot) {
                NSString *bid = cand[@"bid"];
                NSString *nm = cand[@"name"] ?: bid;
                [ac addAction:[UIAlertAction actionWithTitle:nm style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    WXLOG(@"用户选择：%@ (%@)", nm, bid);
                    WXSBHideOverlay();
                    NSURL *u2 = url;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        WXLOG(@"后台线程开始拉起 %@", bid);
                        WXSBLaunchByBundle(u2, bid);
                    });
                }]];
            }
            [ac addAction:[UIAlertAction actionWithTitle:@"系统默认微信" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                WXLOG(@"用户选择：系统默认");
                WXSBHideOverlay();
                NSURL *u3 = url;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    WXLOG(@"后台线程开始拉起 com.tencent.xin");
                    WXSBLaunchByBundle(u3, @"com.tencent.xin");
                });
            }]];
            [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
                WXLOG(@"用户取消");
                WXSBHideOverlay();
            }]];
            [top presentViewController:ac animated:NO completion:^{
                WXSetGuard(NO);
                WXLOG(@"SB 弹框已呈现");
            }];
        } @catch (NSException *e) {
            WXLOG(@"SB 弹框异常 %@", e.reason);
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

static void (*o_sbmw_execute)(id, SEL, id, unsigned long long, id) = NULL;

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
    if (!obj || depth > 3 || *budget <= 0) return nil;
    (*budget)--;
    @try {
        if ([obj isKindOfClass:[NSString class]]) {
            NSString *s = (NSString *)obj;
            if (s.length > 5 && s.length < 500 && [s rangeOfString:@"weixin" options:NSCaseInsensitiveSearch].location != NSNotFound) return s;
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
            }
            BOOL urlLike = (u && WXIsTargetURL(u))
                        || (desc && [desc.lowercaseString containsString:@"weixin"])
                        || (u && WXIsWeChatWebURL(u));
            if (looksWX && (urlLike || bidKnown)) {
                if (!desc) { @try { desc = [request description]; } @catch (NSException *e) {} }
                if (!u) {
                    int budget = 400;
                    NSString *raw = WXScanForWeixinString(request, 0, &budget);
                    if (!raw) raw = WXWeixinURLFromString(desc);
                    if (raw) {
                        NSURL *cand = [NSURL URLWithString:raw];
                        if (cand && WXIsTargetURL(cand)) { u = cand; WXLOG(@"  取到真实 URL：%@", raw); }
                        else WXLOG(@"  取到的不是有效微信 URL：%@", raw);
                    }
                }
                static CFAbsoluteTime lastHit = 0;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                BOOL tooSoon = (now - lastHit < 1.2);
                if (!tooSoon && WXSBEnsureOverlay()) {
                    lastHit = now;
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
                    WXLOG(@"SB 短时间重复命中，放行原启动");
                } else {
                    WXLOG(@"SB 建窗失败，放行原启动");
                }
            }
        }
    } @catch (NSException *e) {
        WXLOG(@"SBMainWorkspace 拦截异常 %@", e.reason);
    }
    if (intercept) {
        WXSBShowChooser(hitURL, @"SBMainWorkspace", nil);
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
    if ([WXSelfBundleID() isEqualToString:@"com.apple.springboard"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:kWXGuard]) {
            gWXGuardTripped = YES;
            WXSetGuard(NO);
            WXLOG(@"⚠ 检测到上次弹框把 SpringBoard 弄崩了，本会话不再弹框（直接放行）");
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        WXDarwinCallback, CFSTR("com.fengxin.wxchooser.launch"),
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
