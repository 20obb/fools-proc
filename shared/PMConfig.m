#import "PMConfig.h"
#import <sys/stat.h>

static NSString *PMTrimmedString(id rawValue) {
    if (![rawValue isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [(NSString *)rawValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSArray<NSString *> *PMStringListFromValue(id rawValue, BOOL uppercase) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    if ([rawValue isKindOfClass:[NSArray class]]) {
        for (id value in (NSArray *)rawValue) {
            NSString *trimmed = PMTrimmedString(value);
            if (trimmed.length == 0) {
                continue;
            }
            [result addObject:uppercase ? [trimmed uppercaseString] : trimmed];
        }
    } else if ([rawValue isKindOfClass:[NSString class]]) {
        NSArray<NSString *> *parts = [(NSString *)rawValue componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",\n"]];
        for (NSString *part in parts) {
            NSString *trimmed = PMTrimmedString(part);
            if (trimmed.length == 0) {
                continue;
            }
            [result addObject:uppercase ? [trimmed uppercaseString] : trimmed];
        }
    }

    if (result.count == 0) {
        return @[];
    }

    NSMutableOrderedSet *dedup = [NSMutableOrderedSet orderedSet];
    for (NSString *item in result) {
        [dedup addObject:item];
    }
    return dedup.array;
}

@implementation PMConfig

+ (instancetype)loadCurrentConfig {
    PMConfig *config = [[PMConfig alloc] init];
    config.enabled = YES;
    config.hudEnabled = YES;
    config.liveNotificationsEnabled = NO;
    config.plistParsingEnabled = YES;
    config.hudHidden = NO;
    config.includeNoisyPaths = NO;
    config.comprehensiveMode = NO;
    config.autoReconnectLive = YES;
    config.monitorGuard = YES;
    config.liveSource = @"daemon_socket";
    config.pathScopePrefix = @"";
    config.pathContains = @"";
    config.pathRegex = @"";
    config.processContains = @"";
    config.ignoredPaths = @[
        @"/var/mobile/Library/Caches",
        @"/var/mobile/Library/Logs/CrashReporter",
        @"/var/jb/var/cache",
        @"/private/var/tmp"
    ];
    config.allowedEventTypes = @[
        @"CREATE_FILE",
        @"CREATE_DIR",
        @"DELETE",
        @"RENAME_MOVE",
        @"MODIFY_CONTENT",
        @"PLIST_VALUE_CHANGED",
        @"PERMISSION_CHANGED",
        @"SERVICE_STARTED",
        @"SERVICE_STOPPED",
        @"PACKAGE_INSTALL",
        @"PACKAGE_REMOVE"
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

    id includeNoisy = preferences[@"IncludeNoisyPaths"];
    if ([includeNoisy respondsToSelector:@selector(boolValue)]) {
        config.includeNoisyPaths = [includeNoisy boolValue];
    }

    id comprehensiveMode = preferences[@"ComprehensiveMode"];
    if ([comprehensiveMode respondsToSelector:@selector(boolValue)]) {
        config.comprehensiveMode = [comprehensiveMode boolValue];
    }

    id autoReconnectLive = preferences[@"AutoReconnectLive"];
    if ([autoReconnectLive respondsToSelector:@selector(boolValue)]) {
        config.autoReconnectLive = [autoReconnectLive boolValue];
    }

    id monitorGuard = preferences[@"MonitorGuard"];
    if ([monitorGuard respondsToSelector:@selector(boolValue)]) {
        config.monitorGuard = [monitorGuard boolValue];
    }

    NSString *liveSource = PMTrimmedString(preferences[@"LiveSource"]);
    if (liveSource.length > 0) {
        config.liveSource = liveSource;
    }

    NSString *pathScopePrefix = PMTrimmedString(preferences[@"PathScopePrefix"]);
    if (pathScopePrefix.length > 0) {
        config.pathScopePrefix = pathScopePrefix;
    }

    NSString *pathContains = PMTrimmedString(preferences[@"PathContains"]);
    if (pathContains.length > 0) {
        config.pathContains = [pathContains lowercaseString];
    }

    NSString *pathRegex = PMTrimmedString(preferences[@"PathRegex"]);
    if (pathRegex.length > 0) {
        config.pathRegex = pathRegex;
    }

    NSString *processContains = PMTrimmedString(preferences[@"ProcessContains"]);
    if (processContains.length > 0) {
        config.processContains = [processContains lowercaseString];
    }

    id ignored = preferences[@"IgnoredPaths"];
    NSArray<NSString *> *ignoredList = PMStringListFromValue(ignored, NO);
    if (ignoredList.count > 0) {
        config.ignoredPaths = ignoredList;
    }

    NSArray<NSString *> *allowedTypes = PMStringListFromValue(preferences[@"AllowedEventTypes"], YES);
    if (allowedTypes.count > 0) {
        config.allowedEventTypes = allowedTypes;
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

- (BOOL)shouldDisplayEventType:(NSString *)eventType path:(NSString *)path processName:(NSString *)processName {
    if (eventType.length == 0 || path.length == 0) {
        return NO;
    }
    if ([self shouldIgnorePath:path]) {
        return NO;
    }

    NSString *upperType = [eventType uppercaseString];
    NSString *lowerPath = [path lowercaseString];
    NSString *lowerProc = [PMTrimmedString(processName) lowercaseString];

    if (!self.comprehensiveMode && self.allowedEventTypes.count > 0 && ![self.allowedEventTypes containsObject:upperType]) {
        return NO;
    }

    if (self.pathScopePrefix.length > 0 && ![path hasPrefix:self.pathScopePrefix]) {
        return NO;
    }

    if (self.pathContains.length > 0 && ![lowerPath containsString:self.pathContains]) {
        return NO;
    }

    if (self.pathRegex.length > 0) {
        NSError *regexError = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:self.pathRegex options:NSRegularExpressionCaseInsensitive error:&regexError];
        if (!regexError && regex) {
            NSRange fullRange = NSMakeRange(0, path.length);
            if ([regex firstMatchInString:path options:0 range:fullRange] == nil) {
                return NO;
            }
        }
    }

    if (self.processContains.length > 0) {
        if (lowerProc.length > 0 && ![lowerProc isEqualToString:@"unknown"] && ![lowerProc containsString:self.processContains]) {
            return NO;
        }
    }

    if (self.includeNoisyPaths) {
        return YES;
    }

    if (![PMConfig isNoisyPathForDisplay:path]) {
        return YES;
    }

    static NSSet<NSString *> *allowOnNoisyPaths = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowOnNoisyPaths = [NSSet setWithArray:@[
            @"PACKAGE_INSTALL",
            @"PACKAGE_REMOVE",
            @"SERVICE_STARTED",
            @"SERVICE_STOPPED",
            @"CREATE_FILE",
            @"CREATE_DIR",
            @"DELETE",
            @"RENAME_MOVE",
            @"PERMISSION_CHANGED",
            @"PLIST_VALUE_CHANGED",
            @"PLIST_FILE_REWRITTEN"
        ]];
    });

    if (![allowOnNoisyPaths containsObject:upperType]) {
        return NO;
    }

    // Always suppress temp/cache churn unless user explicitly broadens ignored paths.
    if ([lowerPath hasSuffix:@".tmp"] || [lowerPath hasSuffix:@".temp"] || [lowerPath hasSuffix:@".lock"] ||
        [lowerPath hasSuffix:@".db-wal"] || [lowerPath hasSuffix:@".db-shm"] ||
        [lowerPath hasSuffix:@".sqlite-wal"] || [lowerPath hasSuffix:@".sqlite-shm"] ||
        [lowerPath containsString:@"/tmp/"] || [lowerPath containsString:@"/private/var/tmp/"]) {
        return NO;
    }

    return YES;
}

@end
