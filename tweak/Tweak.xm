#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "HUD/PMHUDController.h"
#import "PMHookReporter.h"
#import "../shared/PMConfig.h"

static BOOL PMShouldReportPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return NO;
    }

    NSString *logDir = [[PMConfig humanLogPath] stringByDeletingLastPathComponent];
    if ([path hasPrefix:logDir] || [path isEqualToString:[PMConfig socketPath]]) {
        return NO;
    }

    PMConfig *config = [PMConfig loadCurrentConfig];
    if (!config.enabled) {
        return NO;
    }

    if ([PMConfig isNoisyPathForDisplay:path]) {
        return NO;
    }

    return ![config shouldIgnorePath:path];
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[PMHUDController sharedInstance] start];
    });
}

%end

%hook NSFileManager

- (BOOL)createFileAtPath:(NSString *)path contents:(NSData *)data attributes:(NSDictionary<NSFileAttributeKey,id> *)attr {
    BOOL result = %orig;
    if (result && PMShouldReportPath(path)) {
        NSDictionary *extra = @{
            @"op": @"create",
            @"bytes": @(data.length),
            @"has_attributes": @(attr.count > 0)
        };
        [PMHookReporter reportEventType:@"CREATE_FILE" path:path oldPath:nil newPath:nil extra:extra];
    }
    return result;
}

- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    BOOL result = %orig;
    if (result && PMShouldReportPath(path)) {
        [PMHookReporter reportEventType:@"DELETE" path:path oldPath:nil newPath:nil extra:@{ @"op": @"remove" }];
    }
    return result;
}

- (BOOL)moveItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    BOOL result = %orig;
    if (result && PMShouldReportPath(srcPath)) {
        NSDictionary *extra = @{
            @"op": @"move"
        };
        [PMHookReporter reportEventType:@"RENAME_MOVE" path:dstPath ?: srcPath oldPath:srcPath newPath:dstPath extra:extra];
    }
    return result;
}

- (BOOL)setAttributes:(NSDictionary<NSFileAttributeKey,id> *)attributes ofItemAtPath:(NSString *)path error:(NSError **)error {
    BOOL result = %orig;
    if (result && PMShouldReportPath(path)) {
        NSDictionary *extra = @{
            @"op": @"set_attributes",
            @"keys": attributes.allKeys ?: @[]
        };
        [PMHookReporter reportEventType:@"PERMISSION_CHANGED" path:path oldPath:nil newPath:nil extra:extra];
    }
    return result;
}

- (BOOL)createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary<NSFileAttributeKey,id> *)attributes error:(NSError **)error {
    BOOL result = %orig;
    if (result && PMShouldReportPath(path)) {
        NSDictionary *extra = @{
            @"op": @"mkdir",
            @"intermediate": @(createIntermediates)
        };
        [PMHookReporter reportEventType:@"CREATE_DIR" path:path oldPath:nil newPath:nil extra:extra];
    }
    return result;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[PMHUDController sharedInstance] start];
            });
        }
    }
}
