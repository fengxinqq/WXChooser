// wxchooseropen —— 独立启动器进程。
// 两种工作模式：
//   无参数（默认，由 LaunchDaemon 常驻）：监听 Darwin 通知，收到请求后按包名把微信拉起来。
//   --oneshot：读 /var/mobile/wxchooser_cmd.plist 执行一次后退出（供 SpringBoard 兜底 spawn）。
// 它不碰界面、不碰剪贴板：所有启动尝试都在它自己的进程里做，
// 失败也只是它自己退出，绝不会杀掉调用方（1.41）或卡死 SpringBoard（1.44）。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>
#import <stdarg.h>

static NSString *const kLog = @"/var/mobile/wxchooser.log";

static void LG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] [启动器] %@\n", [NSDate date], body];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLog];
    @try {
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        else { [line writeToFile:kLog atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    } @catch (NSException *e) {}
}

static id ClassFromFrameworks(NSString *cls, NSArray *paths) {
    Class c = NSClassFromString(cls);
    if (c) return c;
    for (NSString *p in paths) {
        void *h = dlopen(p.UTF8String, RTLD_NOW);
        if (!h) continue;
        c = NSClassFromString(cls);
        if (c) return c;
    }
    return nil;
}

static id FBSSvc(void) {
    static id svc = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id c = ClassFromFrameworks(@"FBSSystemService", @[
            @"/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
            @"/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard",
            @"/usr/lib/libFrontBoardServices.dylib"]);
        SEL s = sel_getUid("sharedService");
        if (c && [c respondsToSelector:s]) svc = ((id (*)(id, SEL))objc_msgSend)(c, s);
        LG(@"FBSSystemService=%@", svc ? @"有" : @"无");
    });
    return svc;
}

static id LSWS(void) {
    static id ws = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id c = ClassFromFrameworks(@"LSApplicationWorkspace", @[
            @"/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
            @"/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices",
            @"/usr/lib/libMobileCoreServices.dylib"]);
        SEL s = sel_getUid("defaultWorkspace");
        if (c && [c respondsToSelector:s]) ws = ((id (*)(id, SEL))objc_msgSend)(c, s);
        LG(@"LSApplicationWorkspace=%@", ws ? @"有" : @"无");
    });
    return ws;
}

static BOOL waitBlock(NSString *name, double timeout, BOOL (^blk)(void)) {
    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            @try { ok = blk() ? YES : NO; }
            @catch (NSException *e) { LG(@"%@ 异常 %@", name, e.reason); ok = NO; }
            dispatch_semaphore_signal(sem);
        }
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        LG(@"%@ 等不到回调(%.1fs)", name, timeout);
        return NO;
    }
    LG(@"%@ -> %@", name, ok ? @"成" : @"败");
    return ok;
}

// 1) FrontBoard：指定「用哪个 App」打开「哪个链接」——系统自己的通道
static BOOL openViaFBURL(NSString *bid, NSURL *url) {
    id svc = FBSSvc();
    if (!svc || !url) { LG(@"FBS+URL 缺料 svc=%@ url=%@", svc ? @"有" : @"无", url ? @"有" : @"无"); return NO; }
    SEL s = sel_getUid("openURL:application:options:clientPort:withResult:");
    if (![svc respondsToSelector:s]) { LG(@"FBS openURL:application: 不存在"); return NO; }
    __block BOOL done = NO;
    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    @try { opts[@"FBSOpenApplicationOptionKeyPayloadURL"] = url; } @catch (NSException *e) {}
    @try {
        ((void (*)(id, SEL, id, id, id, unsigned, id))objc_msgSend)(svc, s, url, bid, opts, 0, ^(id e) {
            done = YES;
            LG(@"FBS+URL 回调 err=%@", e ? [e description] : @"无");
        });
    } @catch (NSException *e) { LG(@"FBS+URL 异常 %@", e.reason); return NO; }
    return waitBlock(@"FBS+URL", 3.0, ^{ return done; });
}

// 2) FrontBoard：按包名启动，链接塞在启动选项里
static BOOL openViaFBApp(NSString *bid, NSURL *url) {
    id svc = FBSSvc();
    SEL s = sel_getUid("openApplication:options:withResult:");
    if (!svc || ![svc respondsToSelector:s]) { LG(@"FBS openApplication 不存在"); return NO; }
    __block BOOL done = NO;
    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    if (url) @try {
        opts[@"FBSOpenApplicationOptionKeyPayloadURL"] = url;
        opts[@"FBSOpenApplicationOptionKeyLaunchURL"] = url;
    } @catch (NSException *e) {}
    @try {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(svc, s, bid, opts, ^(id e, id r) {
            done = YES;
            LG(@"FBS 按包名回调 err=%@", e ? [e description] : @"无");
        });
    } @catch (NSException *e) { LG(@"FBS 按包名异常 %@", e.reason); return NO; }
    return waitBlock(@"FBS 按包名", 3.0, ^{ return done; });
}

// 3) SpringBoardServices 自己的启动函数
static BOOL openViaSBS(NSString *bid, NSURL *url) {
    typedef int (*FnURL)(CFStringRef, CFURLRef, CFDictionaryRef, CFStringRef *, Boolean);
    typedef int (*FnPlain)(CFStringRef, Boolean);
    static FnURL fURL = NULL;
    static FnPlain fPlain = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
        fURL = (FnURL)dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions");
        fPlain = (FnPlain)dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
        LG(@"SBS 接口 withURL=%@ plain=%@", fURL ? @"有" : @"无", fPlain ? @"有" : @"无");
    });
    if (!bid.length) return NO;
    if (fURL) {
        CFStringRef eb = NULL;
        int r = fURL((__bridge CFStringRef)bid, (__bridge CFURLRef)url, NULL, &eb, false);
        LG(@"SBS 带链接 r=%d err=%@", r, eb ? (__bridge NSString *)eb : @"无");
        if (eb) CFRelease(eb);
        if (r == 0) return YES;
    }
    if (fPlain) {
        int r = fPlain((__bridge CFStringRef)bid, false);
        LG(@"SBS 只启动 r=%d", r);
        if (r == 0) return YES;
    }
    return NO;
}

// 4) LaunchServices 兜底
static BOOL openViaWorkspace(NSString *bid, NSURL *url) {
    id ws = LSWS();
    if (!ws) return NO;
    BOOL any = NO;
    SEL s1 = sel_getUid("openApplicationWithBundleID:");
    if ([ws respondsToSelector:s1]) {
        BOOL r = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s1, bid) ? YES : NO;
        LG(@"workspace 按包名 %@", r ? @"成" : @"败");
        any = any || r;
    }
    if (url) {
        SEL s2 = sel_getUid("openSensitiveURL:withOptions:");
        if ([ws respondsToSelector:s2]) {
            BOOL r = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, s2, url, nil) ? YES : NO;
            LG(@"workspace 打开链接 %@", r ? @"成" : @"败");
            any = any || r;
        }
    }
    return any;
}

static BOOL WXLaunchBundle(NSString *bid, NSURL *url, NSString **howOut) {
    NSString *how = @"";
    BOOL ok = NO;
    if (!ok && openViaFBURL(bid, url)) { ok = YES; how = @"FBS+链接"; }
    if (!ok && openViaFBApp(bid, url)) { ok = YES; how = @"FBS按包名"; }
    if (!ok && openViaSBS(bid, url)) { ok = YES; how = @"SBS"; }
    if (!ok && openViaWorkspace(bid, url)) { ok = YES; how = @"workspace"; }
    LG(@"结论 %@ (%@)", ok ? @"成功" : @"失败", how.length ? how : @"全败");
    if (howOut) *howOut = how;
    return ok;
}

#pragma mark - 请求文件

static NSDictionary *WXNewestRequest(NSString **outPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *cands = [NSMutableArray arrayWithObject:@"/var/mobile/wxchooser_req.plist"];
    NSString *apps = @"/var/mobile/Containers/Data/Application";
    for (NSString *d in [fm contentsOfDirectoryAtPath:apps error:nil]) {
        [cands addObject:[apps stringByAppendingPathComponent:[d stringByAppendingPathComponent:@"Documents/wxreq.plist"]]];
    }
    NSString *bestPath = nil;
    double bestTs = 0;
    NSDictionary *best = nil;
    for (NSString *p in cands) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:p];
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        double ts = [[fm attributesOfItemAtPath:p error:nil][NSFileModificationDate] timeIntervalSince1970];
        if (ts > bestTs) { bestTs = ts; best = dict; bestPath = p; }
    }
    if (!best) return nil;
    if ([[NSDate date] timeIntervalSince1970] - bestTs > 90) return nil;
    if (outPath) *outPath = bestPath;
    return best;
}

static void WXWriteResult(NSString *reqPath, BOOL ok, NSString *how) {
    if (!reqPath.length) return;
    NSDictionary *res = @{@"ok": @(ok), @"how": how ?: @"", @"ts": @([[NSDate date] timeIntervalSince1970])};
    [res writeToFile:[[reqPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"wxres.plist"] atomically:YES];
}

static void WXHandleOneRequest(void) {
    @autoreleasepool {
        NSString *path = nil;
        NSDictionary *req = WXNewestRequest(&path);
        if (!req) { LG(@"没有请求文件"); return; }
        NSString *bid = req[@"bid"] ?: @"";
        NSString *us = req[@"url"] ?: @"";
        NSURL *url = us.length ? [NSURL URLWithString:us] : nil;
        LG(@"请求 bid=%@ url=%@ 文件=%@", bid, us.length ? us : @"(空)", path);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (!bid.length) return;
        NSString *how = nil;
        BOOL ok = WXLaunchBundle(bid, url, &how);
        WXWriteResult(path, ok, how);
    }
}

static void WXHandleOneshot(void) {
    NSDictionary *cmd = nil;
    for (int i = 0; i < 25 && ![cmd isKindOfClass:[NSDictionary class]]; i++) {
        cmd = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/wxchooser_cmd.plist"];
        if (![cmd isKindOfClass:[NSDictionary class]]) usleep(200 * 1000);
    }
    if (![cmd isKindOfClass:[NSDictionary class]]) { LG(@"oneshot 没命令文件"); return; }
    NSString *bid = cmd[@"bid"] ?: @"";
    NSString *us = cmd[@"url"] ?: @"";
    NSURL *url = us.length ? [NSURL URLWithString:us] : nil;
    LG(@"oneshot bid=%@ url=%@", bid, us.length ? us : @"(空)");
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/wxchooser_cmd.plist" error:nil];
    NSString *how = nil;
    WXLaunchBundle(bid, url, &how);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL oneshot = NO;
        for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--oneshot")) oneshot = YES;
        if (oneshot) {
            WXHandleOneshot();
            return 0;
        }
        LG(@"守护常驻启动 pid=%d", getpid());
        int token = 0;
        notify_register_dispatch("com.fengxin.wxchooser.launchreq", &token,
                                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(int t) {
            LG(@"收到启动通知");
            WXHandleOneRequest();
        });
        LG(@"已监听 com.fengxin.wxchooser.launchreq");
        dispatch_main();
    }
    return 0;
}
