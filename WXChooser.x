#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

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

static NSString *WXSelfBundleID(void) {
    static NSString *bid = nil;
    if (!bid) bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    return bid;
}

static BOOL WXIsSelfWeChat(void) {
    NSString *b = WXSelfBundleID().lowercaseString;
    return (b.length && [b containsString:@"tencent.xin"]) || [b containsString:@"weixin"] || [b containsString:@"wechat"];
}

static BOOL WXIsWeixinScheme(NSString *scheme) {
    NSString *s = scheme.lowercaseString;
    if (!s.length) return NO;
    if ([s hasPrefix:@"weixin"]) return YES;
    if ([s hasPrefix:@"wx"] && s.length > 2) return YES;
    return NO;
}

static BOOL WXIsWeChatApp(NSString *bid, NSString *name) {
    NSString *b = bid.lowercaseString ?: @"";
    NSString *n = name ?: @"";
    if ([b containsString:@"tencent.xin"]) return YES;
    if ([b containsString:@"weixin"]) return YES;
    if ([b containsString:@"wechat"]) return YES;
    if ([n containsString:@"微信"]) return YES;
    return NO;
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

    WXLOG(@"文件扫描得到 %lu 个 app 路径", (unsigned long)appPaths.count);
    for (NSString *p in appPaths) {
        NSDictionary *pl = [NSDictionary dictionaryWithContentsOfFile:[p stringByAppendingPathComponent:@"Info.plist"]];
        if (![pl isKindOfClass:[NSDictionary class]]) continue;
        NSString *bid = pl[@"CFBundleIdentifier"];
        if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
        NSString *name = pl[@"CFBundleDisplayName"] ?: pl[@"CFBundleName"];
        if (![name isKindOfClass:[NSString class]]) name = bid;
        if (!WXIsWeChatApp(bid, name)) continue;
        NSArray *schemes = WXSchemesOfPlist(pl);
        [out addObject:@{@"bid": bid, @"name": name, @"schemes": schemes}];
    }
    if (out.count == 0) {
        WXLOG(@"文件系统扫不到，改用 LaunchServices");
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
            if (!WXIsWeChatApp(bid, name)) continue;
            [out addObject:@{@"bid": bid, @"name": name.length ? name : bid, @"schemes": @[]}];
        }
        WXLOG(@"LSW: 枚举到 %lu 个微信类应用", (unsigned long)out.count);
    } @catch (NSException *e) {
        WXLOG(@"LSW 异常 %@", e.reason);
    }
    return out;
}

static NSArray<NSDictionary *> *WXCandidatesForURL(NSURL *url) {
    NSArray *all = WXScanWeChatApps();
    NSMutableSet *others = [NSMutableSet set];
    for (NSDictionary *a in all) for (NSString *s in a[@"schemes"]) [others addObject:s.lowercaseString];

    NSMutableArray *res = [NSMutableArray array];
    for (NSDictionary *a in all) {
        NSString *bid = a[@"bid"];
        if ([bid isEqualToString:WXSelfBundleID()]) continue;
        NSString *uniq = nil;
        NSString *fallback = nil;
        for (NSString *s in a[@"schemes"]) {
            NSString *low = s.lowercaseString;
            if (!WXIsWeixinScheme(low)) continue;
            if (![uniq length]) fallback = s;
        }
        // 找一个只属于该 App、且不是 weixin 系的 scheme
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        for (NSDictionary *b in all) {
            for (NSString *s in b[@"schemes"]) {
                NSString *low = s.lowercaseString;
                counts[low] = @([counts[low] integerValue] + 1);
            }
        }
        for (NSString *s in a[@"schemes"]) {
            NSString *low = s.lowercaseString;
            if ([counts[low] integerValue] <= 1 && !WXIsWeixinScheme(low)) { uniq = s; break; }
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

static BOOL WXOpenByScheme(NSURL *url, NSString *scheme, void (^done)(BOOL)) {
    if (!scheme.length) return NO;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.scheme = scheme;
    NSURL *u = c.URL;
    if (!u) return NO;
    WXLOG(@"改写 scheme -> %@ : %@", scheme, u.absoluteString);
    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:^(BOOL ok) {
        WXLOG(@"改写后打开结果=%d", ok);
        if (done) done(ok);
    }];
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
            if ([sn hasSuffix:@"allowUnlock:"]) {
                ok = ((BOOL (*)(id, SEL, id, id, BOOL))objc_msgSend)(ws, sel, url, bid, YES);
            } else {
                ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, sel, url, bid);
            }
            WXLOG(@"私有接口 %@ -> %d", sn, ok);
            if (ok) { if (done) done(YES); return YES; }
        } @catch (NSException *e) {
            WXLOG(@"私有接口异常 %@ %@", sn, e.reason);
        }
    }
    return NO;
}

static void WXPresentChooser(NSURL *url, NSArray<NSDictionary *> *cands, NSDictionary *options, void (^completion)(BOOL)) {
    UIViewController *top = WXTopViewController();
    if (!top) { WXLOG(@"找不到顶层控制器，直接放行"); completion(YES); return; }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"打开微信"
                                                               message:@"选择要跳转的微信"
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *cand in cands) {
        NSString *title = cand[@"name"] ?: cand[@"bid"];
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            BOOL handled = NO;
            NSString *scheme = cand[@"scheme"];
            if (scheme.length) handled = WXOpenByScheme(url, scheme, ^(BOOL ok) {
                if (!ok) WXLOG(@"scheme 方式打开失败：%@", scheme);
            });
            if (!handled) handled = WXOpenByBundleID(url, cand[@"bid"], nil);
            if (!handled) {
                WXLOG(@"两种方式都失败，回退系统默认，目标=%@", cand[@"bid"]);
                [[UIApplication sharedApplication] openURL:url options:options ?: @{} completionHandler:completion];
            }
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"系统默认" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[UIApplication sharedApplication] openURL:url options:options ?: @{} completionHandler:completion];
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

static BOOL WXIntercept(NSURL *url, NSDictionary *options, void (^completion)(BOOL)) {
    @try {
        if (!url) return NO;
        if (WXIsSelfWeChat()) return NO;
        if (!WXIsWeixinScheme(url.scheme)) return NO;
        NSArray *cands = WXCandidatesForURL(url);
        WXLOG(@"拦截 %@ 候选 %lu 个", url.absoluteString, (unsigned long)cands.count);
        for (NSDictionary *c in cands) WXLOG(@"  候选：%@ %@ scheme=%@", c[@"bid"], c[@"name"], c[@"scheme"] ?: @"(无)");
        if (cands.count < 2) return NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            WXPresentChooser(url, cands, options, completion);
        });
        return YES;
    } @catch (NSException *e) {
        WXLOG(@"拦截异常 %@", e.reason);
        return NO;
    }
}

%hook UIApplication

- (void)openURL:(NSURL *)url options:(NSDictionary<NSString *, id> *)options completionHandler:(void (^)(BOOL))completionHandler {
    if (WXIntercept(url, options, completionHandler)) return;
    %orig;
}

- (BOOL)openURL:(NSURL *)url {
    if (WXIntercept(url, @{}, nil)) return YES;
    return %orig;
}

%end
