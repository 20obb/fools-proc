#import "PMHookReporter.h"

#import "PMTweakClient.h"
#import "../shared/PMConfig.h"

@implementation PMHookReporter

+ (void)reportEventType:(NSString *)eventType
                   path:(NSString *)path
                oldPath:(NSString *)oldPath
                newPath:(NSString *)newPath
                  extra:(NSDictionary *)extra {
    if (eventType.length == 0 || path.length == 0) {
        return;
    }

    NSString *logDir = [[PMConfig humanLogPath] stringByDeletingLastPathComponent];
    if ([path hasPrefix:logDir] || [path isEqualToString:[PMConfig socketPath]]) {
        return;
    }

    static NSMutableDictionary<NSString *, NSDate *> *lastSentByKey = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lastSentByKey = [NSMutableDictionary dictionary];
    });

    NSString *key = [NSString stringWithFormat:@"%@|%@|%@", eventType, path, oldPath ?: @""];
    NSDate *now = [NSDate date];

    @synchronized (lastSentByKey) {
        NSDate *previous = lastSentByKey[key];
        if (previous && [now timeIntervalSinceDate:previous] < 0.05) {
            return;
        }
        lastSentByKey[key] = now;
    }

    [[PMTweakClient sharedInstance] sendHookEventType:eventType path:path oldPath:oldPath newPath:newPath extra:extra];
}

@end
