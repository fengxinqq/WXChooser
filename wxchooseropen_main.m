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

static BOOL callSEL(id obj, NSString *selName, id a1, id a2) {
    SEL s = sel_getUid(selName.UTF8String);
    if (!obj || ![obj respondsToSelector:s]) return NO;
    BOOL ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(obj, s, a1, a2);
    LG(@"%@ -> %d", selName, ok);
    return ok;
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
        LG(@"工作区=%@", ws ? NSStringFromClass([ws class]) : @"(空)");
        Class cfgCls = NSClassFromString(@"LSApplicationOpenConfiguration");
        LG(@"配置类=%@", cfgCls ? NSStringFromClass(cfgCls) : @"(空)");

        // 1) 带 URL + 目标包名的配置打开
        r = runWithTimeout(@"openURL:configuration:", 4.0, ^{
            id cfg = cfgCls ? ((id (*)(id, SEL))objc_msgSend)(cfgCls, sel_getUid("new")) : nil;
            for (NSString *k in @[@"targetApplicationBundleIdentifier", @"applicationBundleIdentifier", @"bundleIdentifier"]) {
                @try { [cfg setValue:bid forKey:k]; LG(@"配置写入 %@ 成功", k); break; }
                @catch (NSException *e) { LG(@"配置写入 %@ 失败", k); }
            }
            SEL s = sel_getUid("openURL:configuration:completionHandler:");
            if (ws && [ws respondsToSelector:s]) {
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(ws, s, url, cfg, ^(id x, NSError *e) {
                    LG(@"openURL 回调 ok=%@ err=%@", x ?: @"nil", e.localizedDescription ?: @"无");
                });
                return YES;
            }
            LG(@"没有 openURL:configuration: 方法");
            return NO;
        });
        if (r == 0) how = @"openURL+配置";

        // 2) 按包名启动（配置对象可选）
        if (r != 0) {
            r = runWithTimeout(@"openApplicationWithBundleIdentifier:", 4.0, ^{
                SEL s = sel_getUid("openApplicationWithBundleIdentifier:configuration:completionHandler:");
                if (ws && [ws respondsToSelector:s]) {
                    ((void (*)(id, SEL, id, id, id))objc_msgSend)(ws, s, bid, nil, ^(id x, NSError *e) {
                        LG(@"按包名回调 ok=%@ err=%@", x ?: @"nil", e.localizedDescription ?: @"无");
                    });
                    return YES;
                }
                if (!callSEL(ws, @"openApplicationWithBundleID:", bid, nil)) return NO;
                return YES;
            });
            if (r == 0) how = @"按包名";
        }

        // 3) 普通 openURL（只有官方微信会命中）
        if (r != 0 && url) {
            r = runWithTimeout(@"openURL:", 3.0, ^{
                return callSEL(ws, @"openURL:", url, nil);
            });
            if (r == 0) how = @"openURL";
        }

        LG(@"最终 how=%@ r=%ld", how, (long)r);
        [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
    }
    return (r == 0) ? 0 : 1;
}
