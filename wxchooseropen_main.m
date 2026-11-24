#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <unistd.h>

// 独立启动器：读取 /var/mobile/wxchooser_cmd.plist，用 SpringBoardServices 拉起指定 App
int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *cmdPath = @"/var/mobile/wxchooser_cmd.plist";
    NSString *logPath = @"/var/mobile/wxchooser.log";

    void (^log)(NSString *) = ^(NSString *s) {
        NSString *line = [NSString stringWithFormat:@"[%@] [启动器] %@\n", [NSDate date], s];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *e) {}
        } else {
            [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    };

    NSDictionary *cmd = nil;
    for (int i = 0; i < 20 && !cmd; i++) {
        cmd = [NSDictionary dictionaryWithContentsOfFile:cmdPath];
        if (!cmd) usleep(200 * 1000);
    }
    if (![cmd isKindOfClass:[NSDictionary class]]) { log(@"没有命令文件，退出"); [pool release]; return 1; }

    NSString *bid = cmd[@"bid"];
    NSString *urlStr = cmd[@"url"];
    log([NSString stringWithFormat:@"收到：bid=%@ url=%@", bid ?: @"(空)", urlStr ?: @"(空)"]);

    void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (!h) h = dlopen("/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard", RTLD_LAZY);
    int (*launchWithURL)(CFStringRef, CFURLRef, CFDictionaryRef, CFStringRef *, Boolean) =
        (int (*)(CFStringRef, CFURLRef, CFDictionaryRef, CFStringRef *, Boolean))dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions");
    int (*launch)(CFStringRef, Boolean) = (int (*)(CFStringRef, Boolean))dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
    log([NSString stringWithFormat:@"接口：withURL=%@ launch=%@", launchWithURL ? @"有" : @"无", launch ? @"有" : @"无"]);

    NSURL *url = urlStr.length ? [NSURL URLWithString:urlStr] : nil;
    CFStringRef err = NULL;
    int r = -1;
    if (launchWithURL && bid.length) {
        r = launchWithURL((__bridge CFStringRef)bid, (__bridge CFURLRef)url,
                          (__bridge CFDictionaryRef)@{}, &err, false);
    }
    if (r != 0 && launch && bid.length) {
        r = launch((__bridge CFStringRef)bid, false);
        log(@"退回无 URL 启动");
    }
    log([NSString stringWithFormat:@"结果 r=%d err=%@", r, err ? (__bridge NSString *)err : @"无"]);

    [[NSFileManager defaultManager] removeItemAtPath:cmdPath error:nil];
    [pool release];
    return (r == 0) ? 0 : 1;
}
