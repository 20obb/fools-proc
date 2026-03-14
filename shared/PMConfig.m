#import "PMConfig.h"
#import <sys/stat.h>

@implementation PMConfig

+ (instancetype)loadCurrentConfig {
    PMConfig *config = [[PMConfig alloc] init];
    config.enabled = YES;
    config.hudEnabled = YES;
    config.liveNotificationsEnabled = NO;
    config.plistParsingEnabled = YES;
    config.hudHidden = NO;
    config.ignoredPaths = @[
        @"/var/mobile/Library/Caches",
        @"/var/mobile/Library/Logs/CrashReporter",
        @"/var/jb/var/cache",
        @"/private/var/tmp"
    ];

    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:[self preferencesFilePath]];
    if (![preferences isKindOfClass:[NSDictionary class]]) {
        return config;
    }

    id enabled = preferences[@"Enabled"];
    if ([enabled respondsToSelector:@selector(boolValue)]) {
        config.enabled = [enabled boolValue];
    }

    id hudEnabled = preferences[@"HUDEnabled"];
    if ([hudEnabled respondsToSelector:@selector(boolValue)]) {
        config.hudEnabled = [hudEnabled boolValue];
    }

    id liveNotifications = preferences[@"LiveNotifications"];
    if ([liveNotifications respondsToSelector:@selector(boolValue)]) {
        config.liveNotificationsEnabled = [liveNotifications boolValue];
    }

    id plistParsing = preferences[@"PlistParsing"];
    if ([plistParsing respondsToSelector:@selector(boolValue)]) {
        config.plistParsingEnabled = [plistParsing boolValue];
    }

    id hudHidden = preferences[@"HUDHidden"];
    if ([hudHidden respondsToSelector:@selector(boolValue)]) {
        config.hudHidden = [hudHidden boolValue];
    }

    id ignored = preferences[@"IgnoredPaths"];
    if ([ignored isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        for (id value in (NSArray *)ignored) {
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                [clean addObject:value];
            }
        }
        if (clean.count > 0) {
            config.ignoredPaths = [clean copy];
        }
    } else if ([ignored isKindOfClass:[NSString class]]) {
        NSArray *components = [(NSString *)ignored componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",\n"]];
        NSMutableArray<NSString *> *clean = [NSMutableArray array];
        for (NSString *component in components) {
            NSString *trimmed = [component stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0) {
                [clean addObject:trimmed];
            }
        }
        if (clean.count > 0) {
            config.ignoredPaths = [clean copy];
        }
    }

    return config;
}

+ (NSString *)preferencesDomain {
    return @"com.procmonrootless.settings";
}

+ (NSString *)preferencesFilePath {
    return [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:[[self preferencesDomain] stringByAppendingString:@".plist"]];
}

+ (NSString *)socketPath {
    return @"/var/mobile/Library/Caches/ProcMonRootless/procmon.sock";
}

+ (NSString *)runDirectoryPath {
    return @"/var/mobile/Library/Caches/ProcMonRootless";
}

+ (NSString *)humanLogPath {
    return @"/var/mobile/Library/Logs/ProcMonRootless/procmon.log";
}

+ (NSString *)jsonLogPath {
    return @"/var/mobile/Library/Logs/ProcMonRootless/procmon.jsonl";
}

+ (NSString *)exportDirectoryPath {
    return @"/var/mobile/Library/Logs/ProcMonRootless/exports";
}

+ (NSArray<NSString *> *)defaultDiscoveryRoots {
    return @[
        @"/var/mobile",
        @"/private/var/mobile",
        @"/var/mobile/Library",
        @"/var/mobile/Documents",
        @"/var/mobile/Containers/Data/Application",
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Shared/AppGroup",
        @"/var/mobile/Media",
        @"/var/jb",
        @"/var/jb/var/mobile",
        @"/var/jb/var/mobile/Library",
        @"/var/jb/etc",
        @"/var/jb/var/lib/dpkg",
        @"/var/lib/dpkg",
        @"/var/jb/Library/LaunchDaemons",
        @"/Library/LaunchDaemons",
        @"/System/Library/LaunchDaemons"
    ];
}

+ (NSArray<NSString *> *)sensitivePaths {
    return @[
        @"/var/mobile/Library/Preferences",
        @"/var/mobile/Library/AddressBook",
        @"/var/mobile/Library/SMS",
        @"/var/mobile/Library/Mail",
        @"/var/mobile/Library/Accounts",
        @"/var/jb/var/lib/dpkg",
        @"/var/db",
        @"/etc"
    ];
}

+ (NSUInteger)maxWatcherCount {
    return 3200;
}

+ (NSUInteger)maxRecentEvents {
    return 2000;
}

+ (NSUInteger)maxLiveSubscribers {
    return 12;
}

+ (NSUInteger)maxIPCLineBytes {
    return 8192;
}

+ (void)ensureRuntimeDirectories {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *runDir = [self runDirectoryPath];
    NSString *logDir = [[self humanLogPath] stringByDeletingLastPathComponent];
    NSString *exportDir = [self exportDirectoryPath];

    [fileManager createDirectoryAtPath:runDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];
    [fileManager createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];
    [fileManager createDirectoryAtPath:exportDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @(0777)} error:nil];

    chmod(runDir.fileSystemRepresentation, 0777);
    chmod(logDir.fileSystemRepresentation, 0777);
    chmod(exportDir.fileSystemRepresentation, 0777);
}

+ (BOOL)isNoisyPathForDisplay:(NSString *)path {
    if (path.length == 0) {
        return YES;
    }

    NSString *lower = [path lowercaseString];
    if ([lower hasSuffix:@".db-wal"] || [lower hasSuffix:@".db-shm"] || [lower hasSuffix:@".sqlite-wal"] || [lower hasSuffix:@".sqlite-shm"]) {
        return YES;
    }
    if ([lower hasSuffix:@".tmp"] || [lower hasSuffix:@".temp"] || [lower hasSuffix:@".lock"]) {
        return YES;
    }
    if ([lower containsString:@"/tmp/"] || [lower containsString:@"/private/var/tmp/"]) {
        return YES;
    }
    if ([lower containsString:@"/analytics"] || [lower containsString:@"/logs/"]) {
        return YES;
    }
    if ([lower containsString:@"/caches/"]) {
        return YES;
    }
    return NO;
}

- (BOOL)shouldIgnorePath:(NSString *)path {
    if (path.length == 0) {
        return YES;
    }

    for (NSString *ignoredPrefix in self.ignoredPaths) {
        if (ignoredPrefix.length > 0 && [path hasPrefix:ignoredPrefix]) {
            return YES;
        }
    }

    if ([path hasPrefix:[[PMConfig humanLogPath] stringByDeletingLastPathComponent]] || [path isEqualToString:[PMConfig socketPath]]) {
        return YES;
    }

    return NO;
}

@end
