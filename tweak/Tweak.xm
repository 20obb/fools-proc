#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/stat.h>
#import <unistd.h>

#import "HUD/PMHUDController.h"
#import "PMHookReporter.h"
#import "../shared/PMConfig.h"

static PMConfig *PMCurrentConfig(void) {
    static PMConfig *cached = nil;
    static CFAbsoluteTime lastLoad = 0.0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized ([PMHookReporter class]) {
        if (!cached || (now - lastLoad) > 1.0) {
            cached = [PMConfig loadCurrentConfig];
            lastLoad = now;
        }
        return cached;
    }
}

static NSString *PMProcessName(void) {
    NSString *procName = [[NSProcessInfo processInfo] processName];
    return procName.length > 0 ? procName : @"unknown";
}

static BOOL PMShouldReportEvent(NSString *eventType, NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return NO;
    }

    if (![path hasPrefix:@"/"]) {
        return NO;
    }

    NSString *logDir = [[PMConfig humanLogPath] stringByDeletingLastPathComponent];
    if ([path hasPrefix:logDir] || [path isEqualToString:[PMConfig socketPath]]) {
        return NO;
    }

    PMConfig *config = PMCurrentConfig();
    if (!config.enabled) {
        return NO;
    }

    if ([config shouldIgnorePath:path]) {
        return NO;
    }

    return [config shouldDisplayEventType:eventType path:path processName:PMProcessName()];
}

static NSString *PMStringFromCString(const char *cPath) {
    if (!cPath) {
        return nil;
    }
    NSString *path = [NSString stringWithUTF8String:cPath];
    if (path.length > 0) {
        return path;
    }
    return [[NSFileManager defaultManager] stringWithFileSystemRepresentation:cPath length:strlen(cPath)];
}

static void PMReportCEvent(NSString *eventType, const char *pathC, const char *oldPathC, const char *newPathC, NSDictionary *extra) {
    NSString *path = PMStringFromCString(pathC);
    NSString *oldPath = PMStringFromCString(oldPathC);
    NSString *newPath = PMStringFromCString(newPathC);

    NSString *displayPath = path;
    if (newPath.length > 0) {
        displayPath = newPath;
    }

    if (displayPath.length == 0 || !PMShouldReportEvent(eventType, displayPath)) {
        return;
    }

    [PMHookReporter reportEventType:eventType path:displayPath oldPath:oldPath newPath:newPath extra:extra];
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
    if (result && PMShouldReportEvent(@"CREATE_FILE", path)) {
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
    if (result && PMShouldReportEvent(@"DELETE", path)) {
        [PMHookReporter reportEventType:@"DELETE" path:path oldPath:nil newPath:nil extra:@{ @"op": @"remove" }];
    }
    return result;
}

- (BOOL)moveItemAtPath:(NSString *)srcPath toPath:(NSString *)dstPath error:(NSError **)error {
    BOOL result = %orig;
    NSString *eventPath = dstPath.length > 0 ? dstPath : srcPath;
    if (result && PMShouldReportEvent(@"RENAME_MOVE", eventPath)) {
        NSDictionary *extra = @{
            @"op": @"move"
        };
        [PMHookReporter reportEventType:@"RENAME_MOVE" path:dstPath ?: srcPath oldPath:srcPath newPath:dstPath extra:extra];
    }
    return result;
}

- (BOOL)setAttributes:(NSDictionary<NSFileAttributeKey,id> *)attributes ofItemAtPath:(NSString *)path error:(NSError **)error {
    BOOL result = %orig;
    if (result && PMShouldReportEvent(@"PERMISSION_CHANGED", path)) {
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
    if (result && PMShouldReportEvent(@"CREATE_DIR", path)) {
        NSDictionary *extra = @{
            @"op": @"mkdir",
            @"intermediate": @(createIntermediates)
        };
        [PMHookReporter reportEventType:@"CREATE_DIR" path:path oldPath:nil newPath:nil extra:extra];
    }
    return result;
}

- (BOOL)removeItemAtURL:(NSURL *)URL error:(NSError **)error {
    BOOL result = %orig;
    NSString *path = URL.path;
    if (result && PMShouldReportEvent(@"DELETE", path)) {
        [PMHookReporter reportEventType:@"DELETE" path:path oldPath:nil newPath:nil extra:@{ @"op": @"remove_url" }];
    }
    return result;
}

- (BOOL)moveItemAtURL:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error {
    BOOL result = %orig;
    NSString *srcPath = srcURL.path;
    NSString *dstPath = dstURL.path;
    NSString *eventPath = dstPath.length > 0 ? dstPath : srcPath;
    if (result && PMShouldReportEvent(@"RENAME_MOVE", eventPath)) {
        [PMHookReporter reportEventType:@"RENAME_MOVE" path:eventPath oldPath:srcPath newPath:dstPath extra:@{ @"op": @"move_url" }];
    }
    return result;
}

- (BOOL)createDirectoryAtURL:(NSURL *)url withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary<NSFileAttributeKey,id> *)attributes error:(NSError **)error {
    BOOL result = %orig;
    NSString *path = url.path;
    if (result && PMShouldReportEvent(@"CREATE_DIR", path)) {
        NSDictionary *extra = @{ @"op": @"mkdir_url", @"intermediate": @(createIntermediates), @"has_attributes": @(attributes.count > 0) };
        [PMHookReporter reportEventType:@"CREATE_DIR" path:path oldPath:nil newPath:nil extra:extra];
    }
    return result;
}

- (NSURL *)replaceItemAtURL:(NSURL *)originalItemURL
               withItemAtURL:(NSURL *)newItemURL
              backupItemName:(NSString *)backupItemName
                     options:(NSFileManagerItemReplacementOptions)options
            resultingItemURL:(NSURL *__autoreleasing *)resultingURL
                       error:(NSError *__autoreleasing *)error {
    NSURL *result = %orig;
    NSString *dstPath = originalItemURL.path ?: newItemURL.path;
    NSString *srcPath = newItemURL.path;
    if (result && PMShouldReportEvent(@"MODIFY_CONTENT", dstPath)) {
        NSDictionary *extra = @{ @"op": @"replace_item", @"backup_name": backupItemName ?: @"", @"options": @(options) };
        [PMHookReporter reportEventType:@"MODIFY_CONTENT" path:dstPath oldPath:srcPath newPath:dstPath extra:extra];
    }
    return result;
}

%end

%hookf(int, rename, const char *oldPath, const char *newPath) {
    int rc = %orig;
    if (rc == 0) {
        PMReportCEvent(@"RENAME_MOVE", newPath, oldPath, newPath, @{ @"op": @"rename" });
    }
    return rc;
}

%hookf(int, unlink, const char *path) {
    int rc = %orig;
    if (rc == 0) {
        PMReportCEvent(@"DELETE", path, NULL, NULL, @{ @"op": @"unlink" });
    }
    return rc;
}

%hookf(int, unlinkat, int fd, const char *path, int flags) {
    int rc = %orig;
    if (rc == 0) {
        PMReportCEvent(@"DELETE", path, NULL, NULL, @{ @"op": @"unlinkat", @"fd": @(fd), @"flags": @(flags) });
    }
    return rc;
}

%hookf(int, mkdir, const char *path, mode_t mode) {
    int rc = %orig;
    if (rc == 0) {
        PMReportCEvent(@"CREATE_DIR", path, NULL, NULL, @{ @"op": @"mkdir", @"mode": @((unsigned int)mode) });
    }
    return rc;
}

%hookf(int, rmdir, const char *path) {
    int rc = %orig;
    if (rc == 0) {
        PMReportCEvent(@"DELETE", path, NULL, NULL, @{ @"op": @"rmdir" });
    }
    return rc;
}

%hookf(int, chmod, const char *path, mode_t mode) {
    int rc = %orig;
    if (rc == 0) {
        PMReportCEvent(@"PERMISSION_CHANGED", path, NULL, NULL, @{ @"op": @"chmod", @"mode": @((unsigned int)mode) });
    }
    return rc;
}

%hookf(int, chown, const char *path, uid_t owner, gid_t group) {
    int rc = %orig;
    if (rc == 0) {
        PMReportCEvent(@"PERMISSION_CHANGED", path, NULL, NULL, @{ @"op": @"chown", @"uid": @(owner), @"gid": @(group) });
    }
    return rc;
}

%hookf(int, symlink, const char *target, const char *linkPath) {
    int rc = %orig;
    if (rc == 0) {
        PMReportCEvent(@"SYMLINK_CREATED", linkPath, target, linkPath, @{ @"op": @"symlink" });
    }
    return rc;
}

%hookf(int, link, const char *target, const char *linkPath) {
    int rc = %orig;
    if (rc == 0) {
        PMReportCEvent(@"HARDLINK_CREATED", linkPath, target, linkPath, @{ @"op": @"hardlink" });
    }
    return rc;
}

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
