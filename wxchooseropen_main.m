// wxchooseropen —— 独立启动器进程。所有「按包名拉起」的危险操作都只在它里面做。
// 用法：
//   无参数      常驻守护：监听 Darwin 通知，读请求文件，逐个策略派生子进程去试
//   --try K P   试第 K 种策略（P 是请求文件路径）；成功就写回执，失败或崩了就退出，父进程接着试下一种
// 子进程崩溃只影响它自己，既不会注销 SpringBoard（1.47 的教训），也不会杀掉联通。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <spawn.h>
#import <unistd.h>
#import <signal.h>
#import <stdarg.h>
#import <sys/wait.h>

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

static id ClassFrom(NSString *cls, NSArray *paths) {
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

static id FBSService(void) {
    static id svc = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id c = ClassFrom(@"FBSSystemService", @[
            @"/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
            @"/System/Library/PrivateFrameworks/FrontBoard.framework/FrontBoard"]);
        SEL s = sel_getUid("sharedService");
        if (c && [c respondsToSelector:s]) svc = ((id (*)(id, SEL))objc_msgSend)(c, s);
        LG(@"FBSSystemService=%@", svc ? @"有" : @"无");
    });
    return svc;
}

static id LSWorkspace(void) {
    static id ws = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id c = ClassFrom(@"LSApplicationWorkspace", @[
            @"/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
            @"/System/Library/PrivateFrameworks/LaunchServices.framework/LaunchServices"]);
        SEL s = sel_getUid("defaultWorkspace");
        if (c && [c respondsToSelector:s]) ws = ((id (*)(id, SEL))objc_msgSend)(c, s);
        LG(@"LSApplicationWorkspace=%@", ws ? @"有" : @"无");
    });
    return ws;
}

#pragma mark - 三种策略（都在子进程里跑）

// 0) FrontBoard：用指定 App 打开指定链接
static BOOL tryFBURL(NSString *bid, NSURL *url) {
    id svc = FBSService();
    if (!svc || !url) { LG(@"策略0 缺料"); return NO; }
    SEL s = sel_getUid("openURL:application:options:clientPort:withResult:");
    if (![svc respondsToSelector:s]) { LG(@"策略0 方法不存在"); return NO; }
    __block BOOL fired = NO;
    NSDictionary *opts = @{ @"FBSOpenApplicationOptionKeyPayloadURL": url };
    ((void (*)(id, SEL, id, id, id, unsigned, id))objc_msgSend)(svc, s, url, bid, opts, (unsigned)0, ^(id e, id r) {
        fired = YES;
        LG(@"策略0 回调 err=%@", e ? [e description] : @"无");
        if (e) LG(@"策略0 回调算失败");
    });
    for (int i = 0; i < 40 && !fired; i++) usleep(50 * 1000);
    return fired;
}

// 1) FrontBoard：按包名启动，链接放进启动选项
static BOOL tryFBApp(NSString *bid, NSURL *url) {
    id svc = FBSService();
    SEL s = sel_getUid("openApplication:options:withResult:");
    if (!svc || ![svc respondsToSelector:s]) { LG(@"策略1 方法不存在"); return NO; }
    __block BOOL fired = NO;
    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    if (url) {
        @try { opts[@"FBSOpenApplicationOptionKeyPayloadURL"] = url; } @catch (NSException *e) {}
        @try { opts[@"FBSOpenApplicationOptionKeyLaunchURL"] = url; } @catch (NSException *e) {}
    }
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(svc, s, bid, opts, ^(id e, id r) {
        fired = YES;
        LG(@"策略1 回调 err=%@", e ? [e description] : @"无");
    });
    for (int i = 0; i < 40 && !fired; i++) usleep(50 * 1000);
    return fired;
}

// 2) LaunchServices：按包名起（不保证带链接）
static BOOL tryLSBundle(NSString *bid, NSURL *url) {
    id ws = LSWorkspace();
    if (!ws) { LG(@"策略2 无工作区"); return NO; }
    SEL s = sel_getUid("openApplicationWithBundleID:");
    if (![ws respondsToSelector:s]) { LG(@"策略2 方法不存在"); return NO; }
    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s, bid) ? YES : NO;
    LG(@"策略2 结果=%d", ok);
    return ok;
}

#pragma mark - 请求与回执

static NSDictionary *readRequest(NSString *path) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    return [d isKindOfClass:[NSDictionary class]] ? d : nil;
}

static void writeResult(NSString *reqPath, BOOL ok, NSString *how) {
    if (!reqPath.length) return;
    NSDictionary *res = @{ @"ok": @(ok), @"how": how ?: @"", @"ts": @([[NSDate date] timeIntervalSince1970]) };
    NSString *rp = [[reqPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"wxres.plist"];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:res format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    BOOL w = [data writeToFile:rp atomically:YES];
    LG(@"回执写入 %@ =%d (%@)", rp, w, how);
}

static NSDictionary *newestRequest(NSString **outPath) {
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

#pragma mark - 子进程模式

static int runTry(int which, NSString *reqPath) {
    NSDictionary *req = readRequest(reqPath);
    if (!req) { LG(@"--try 读不到请求 %@", reqPath); return 2; }
    NSString *bid = req[@"bid"] ?: @"";
    NSString *us = req[@"url"] ?: @"";
    NSURL *url = us.length ? [NSURL URLWithString:us] : nil;
    LG(@"--try %d bid=%@ url=%@", which, bid, us.length ? us : @"(空)");
    BOOL ok = NO;
    NSString *how = @"";
    if (which == 0) { ok = tryFBURL(bid, url); how = @"FBS+链接"; }
    else if (which == 1) { ok = tryFBApp(bid, url); how = @"FBS按包名"; }
    else if (which == 2) { ok = tryLSBundle(bid, url); how = @"LS按包名"; }
    if (ok) { writeResult(reqPath, YES, how); return 0; }
    return 1;
}

#pragma mark - 守护模式

static void handleRequest(void) {
    @autoreleasepool {
        NSString *path = nil;
        NSDictionary *req = newestRequest(&path);
        if (!req) { LG(@"没有请求文件"); return; }
        LG(@"收到请求 文件=%@ bid=%@", path, req[@"bid"]);
        NSString *selfPath = [[NSProcessInfo processInfo] arguments].firstObject;
        if (!selfPath.length) selfPath = @"/Library/MobileSubstrate/DynamicLibraries/wxchooseropen";
        char *const envv[] = { (char *)"PATH=/usr/bin:/bin:/usr/sbin:/sbin", (char *)"HOME=/var/mobile", NULL };

        for (int k = 0; k < 3; k++) {
            // 每种策略单独起一个子进程：它崩了也不会带走守护，更不会影响系统界面
            char argk[8];
            snprintf(argk, sizeof(argk), "%d", k);
            char *const argsv[] = { (char *)selfPath.UTF8String, (char *)"--try", argk, (char *)path.UTF8String, NULL };
            pid_t pid = 0;
            int rc = posix_spawn(&pid, selfPath.UTF8String, NULL, NULL, argsv, envv);
            LG(@"策略%d 派生子进程 rc=%d errno=%d pid=%d", k, rc, errno, (int)pid);
            if (rc != 0) continue;
            int status = 0;
            for (int i = 0; i < 90; i++) {   // 最多 4.5 秒
                pid_t w = waitpid(pid, &status, WNOHANG);
                if (w == pid) break;
                usleep(50 * 1000);
            }
            NSString *rp = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"wxres.plist"];
            NSDictionary *res = [NSDictionary dictionaryWithContentsOfFile:rp];
            if ([res[@"ok"] boolValue]) {
                LG(@"策略%d 成功（%@）", k, res[@"how"]);
                return;
            }
            LG(@"策略%d 未成功（子进程状态 0x%x）", k, status);
        }

        // 三种都不成：退回系统默认打开，至少把支付接上
        NSString *us = req[@"url"] ?: @"";
        NSURL *url = us.length ? [NSURL URLWithString:us] : nil;
        id ws = LSWorkspace();
        BOOL ok = NO;
        SEL s = sel_getUid("openSensitiveURL:withOptions:");
        if (ws && url && [ws respondsToSelector:s]) {
            ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, s, url, nil) ? YES : NO;
        }
        LG(@"兜底打开链接=%d", ok);
        writeResult(path, ok, ok ? @"退回原生" : @"全败");
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc >= 4 && !strcmp(argv[1], "--try")) {
            int which = atoi(argv[2]);
            NSString *reqPath = [NSString stringWithUTF8String:argv[3]];
            return runTry(which, reqPath);
        }

        NSString *pidPath = @"/var/mobile/wxchooser.daemon.pid";
        NSString *oldPid = [NSString stringWithContentsOfFile:pidPath encoding:NSUTF8StringEncoding error:nil];
        pid_t op = (pid_t)oldPid.intValue;
        if (op > 1 && op != getpid() && kill(op, 0) == 0) {
            LG(@"已有守护 pid=%d，本次退出", (int)op);
            return 0;
        }
        [[NSString stringWithFormat:@"%d", getpid()] writeToFile:pidPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        LG(@"守护启动 pid=%d", getpid());

        int token = 0;
        notify_register_dispatch("com.fengxin.wxchooser.launchreq", &token,
                                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(int t) {
            LG(@"收到通知");
            handleRequest();
        });
        LG(@"已监听 com.fengxin.wxchooser.launchreq");
        dispatch_main();
    }
    return 0;
}
