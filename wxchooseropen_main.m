#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <stdarg.h>
#import <dispatch/dispatch.h>

static NSString *const kLog = @"/var/mobile/wxchooser.log";
static void LG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] [启动器] %@\n", [NSDate date], body];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLog];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        @catch (NSException *e) {}
    } else {
        [line writeToFile:kLog atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static id WSObj(void) {
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    if (!c) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, sel_getUid("defaultWorkspace"));
}

static void markSelfLaunch(NSString *bid) {
    NSDictionary *d = @{ @"bid": bid ?: @"",
                         @"ts": [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]] };
    [d writeToFile:@"/var/mobile/wxchooser.selflaunch.plist" atomically:YES];
}

static void clearSelfLaunch(void) {
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/wxchooser.selflaunch.plist" error:nil];
}

static id FBSvc(void) {
    Class c = NSClassFromString(@"FBSSystemService");
    if (!c) return nil;
    SEL s = sel_getUid("sharedService");
    if (![c respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, s);
}

static BOOL callBOOL(id obj, NSString *selName, id a1, id a2) {
    SEL s = sel_getUid(selName.UTF8String);
    if (!obj || ![obj respondsToSelector:s]) { LG(@"%@ 不存在", selName); return NO; }
    NSInteger ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(obj, s, a1, a2);
    LG(@"%@ 返回 %ld", selName, (long)ok);
    return ok ? YES : NO;
}

// 在独立线程执行，最多等 timeout 秒，卡住也不会毁掉整个启动器
static NSInteger runWithTimeout(NSString *name, double timeout, BOOL (^blk)(void)) {
    __block NSInteger val = -2;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            @try { val = blk() ? 0 : -1; } @catch (NSException *e) { val = -3; LG(@"%@ 异常 %@", name, e.reason); }
            dispatch_semaphore_signal(sem);
        }
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        LG(@"%@ 超时", name);
        return -2;
    }
    LG(@"%@ 返回 %ld", name, (long)val);
    return val;
}

// FrontBoard 系统服务打开（系统级，最可靠的一条）
static BOOL openViaFBSSystem(NSString *bid, NSURL *url) {
    id svc = FBSvc();
    if (!svc) { LG(@"FBSSystemService 不存在"); return NO; }
    NSMutableDictionary *opts = [NSMutableDictionary dictionary];
    if (url) {
        for (NSString *k in @[@"FBSOpenApplicationOptionKeyPayloadURL", @"FBSOpenApplicationOptionKeyLaunchURL"]) {
            @try { opts[k] = url; } @catch (NSException *e) {}
        }
    }
    __block BOOL fired = NO;
    SEL s = sel_getUid("openApplication:options:withResult:");
    if ([svc respondsToSelector:s]) {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(svc, s, bid, opts, ^(NSError *e, id r) {
            fired = YES;
            LG(@"FBS 回调 err=%@ r=%@", e.localizedDescription ?: @"无", r ?: @"nil");
        });
        NSInteger rr = runWithTimeout(@"FBS openApplication", 5.0, ^{ return (BOOL)fired; });
        return (rr == 0);
    }
    LG(@"FBS openApplication:options:withResult: 不存在");
    SEL s2 = sel_getUid("openApplication:withOptions:");
    if ([svc respondsToSelector:s2]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(svc, s2, bid, opts);
        return YES;
    }
    return NO;
}

int main(int argc, char **argv) {
    __block NSInteger r = -999;
    __block NSString *how = @"无";
    @autoreleasepool {
        NSString *cmdPath = @"/var/mobile/wxchooser_cmd.plist";
        NSDictionary *cmd = nil;
        for (int i = 0; i < 25 && ![cmd isKindOfClass:[NSDictionary class]]; i++) {
            cmd = [NSDictionary dictionaryWithContentsOfFile:cmdPath];
            if (![cmd isKindOfClass:[NSDictionary class]]) usleep(200 * 1000);
        }
        if (![cmd isKindOfClass:[NSDictionary class]]) { LG(@"没有命令文件，退出"); return 1; }

        NSString *bid = cmd[@"bid"] ?: @"";
        NSString *urlStr = cmd[@"url"] ?: @"";
        NSURL *url = urlStr.length ? [NSURL URLWithString:urlStr] : nil;
        LG(@"收到 bid=%@ url=%@", bid, urlStr);

        id ws = WSObj();
        LG(@"工作区=%@ FBS=%@", ws ? NSStringFromClass([ws class]) : @"(空)", FBSvc() ? @"有" : @"无");
        markSelfLaunch(bid);
        LG(@"已写自启动标记 bid=%@", bid);

        BOOL useURLFirst = (url != nil);

        if (useURLFirst) {
            // 带 URL 的三条路先走：让微信直接进支付页
            markSelfLaunch(bid);
            r = runWithTimeout(@"FBS+URL", 6.0, ^{ return openViaFBSSystem(bid, url); });
            if (r == 0) how = @"FBS+URL";
            if (r != 0) {
                r = runWithTimeout(@"openSensitiveURL:withOptions:", 5.0, ^{
                    SEL s = sel_getUid("openSensitiveURL:withOptions:");
                    if (![ws respondsToSelector:s]) return NO;
                    BOOL ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, s, url, nil);
                    LG(@"openSensitiveURL:withOptions: 返回 %d", ok);
                    return ok;
                });
                if (r == 0) how = @"openSensitiveURL";
            }
            if (r != 0) {
                r = runWithTimeout(@"openURL:", 4.0, ^{ return callBOOL(ws, @"openURL:", url, nil); });
                if (r == 0) how = @"openURL";
            }
            if (r != 0) {
                r = runWithTimeout(@"openURL:withOptions:", 4.0, ^{ return callBOOL(ws, @"openURL:withOptions:", url, nil); });
                if (r == 0) how = @"openURL:withOptions";
            }
        }

        if (r != 0) {
            markSelfLaunch(bid);
            r = runWithTimeout(@"FBS", 6.0, ^{ return openViaFBSSystem(bid, nil); });
            if (r == 0) how = @"FBS 系统服务";
        }

        if (r != 0) {
            r = runWithTimeout(@"openApplicationWithBundleID:", 5.0, ^{
                return callBOOL(ws, @"openApplicationWithBundleID:", bid, nil);
            });
            if (r == 0) how = @"按包名";
        }

        LG(@"最终 how=%@ r=%ld", how, (long)r);
        [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
        if (r == 0) clearSelfLaunch();   // 成功了就撤掉自启动标记，别吞掉用户下一次请求
    }
    return (r == 0) ? 0 : 1;
}
