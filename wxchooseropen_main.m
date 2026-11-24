#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

static NSString *const kLog = @"/var/mobile/wxchooser.log";
static void LG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] [启动器] %@\n", [NSDate date], body];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLog];
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    } else {
        [line writeToFile:kLog atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
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

    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    NSMutableArray *openSels = [NSMutableArray array];
    unsigned int n = 0;
    Method *ms = class_copyMethodList(object_getClass(wsCls), &n);
    for (unsigned i = 0; i < n; i++) {
        NSString *nm = NSStringFromSelector(method_getName(ms[i]));
        if ([nm.lowercaseString containsString:@"open"]) [openSels addObject:[@"+" stringByAppendingString:nm]];
    }
    n = 0;
    ms = class_copyMethodList(wsCls, &n);
    for (unsigned i = 0; i < n; i++) {
        NSString *nm = NSStringFromSelector(method_getName(ms[i]));
        if ([nm.lowercaseString containsString:@"open"]) [openSels addObject:nm];
    }
    LG(@"LSWorkspace 可选：%@", [openSels componentsJoinedByString:@" | "]);

    void *sb = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    int (*sbsURL)(CFStringRef, CFURLRef, CFDictionaryRef, CFStringRef *, Boolean) =
        (int (*)(CFStringRef, CFURLRef, CFDictionaryRef, CFStringRef *, Boolean))dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions");
    int (*sbs)(CFStringRef, Boolean) = (int (*)(CFStringRef, Boolean))dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");

    __block NSInteger r = -999;
    __block NSString *how = @"无";
    __block NSString *errS = @"无";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            @try {
                if ([bid isEqualToString:@"com.tencent.xin"] && wsCls) {
                    id w = ((id (*)(id, SEL))objc_msgSend)(wsCls, sel_getUid("defaultWorkspace"));
                    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(w, sel_getUid("openURL:"), url);
                    r = ok ? 0 : -1;
                    how = @"openURL";
                } else if (sbsURL) {
                    LG(@"准备调用 SBS(带URL) bid=%@", bid);
                    CFStringRef e = NULL;
                    r = sbsURL((__bridge CFStringRef)bid, (__bridge CFURLRef)url, NULL, &e, false);
                    if (e) errS = CFBridgingRelease(e);
                    how = @"SBS+URL";
                } else if (sbs) {
                    LG(@"准备调用 SBS(无URL) bid=%@", bid);
                    r = sbs((__bridge CFStringRef)bid, false);
                    how = @"SBS";
                }
            } @catch (NSException *ex) {
                r = -998; errS = ex.reason ?: @"异常";
            }
            dispatch_semaphore_signal(sem);
        }
    });
    long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)));
    LG(@"结果 how=%@ r=%ld err=%@ 超时=%d", how, (long)r, errS, waited != 0);

    [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
    [pool release];
    return (r == 0) ? 0 : 1;
}
