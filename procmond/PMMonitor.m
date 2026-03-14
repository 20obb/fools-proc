#import "PMMonitor.h"

#import <fcntl.h>
#import <sys/event.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <unistd.h>

#import "../shared/PMConfig.h"
#import "../shared/PMEvent.h"

@interface PMMonitor ()
@property (nonatomic, strong) PMConfig *config;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t rescanTimer;

@property (nonatomic, assign) int kqueueFD;
@property (nonatomic, strong) dispatch_source_t kqueueReadSource;

@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *fdToPath;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *pathToFD;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *lastEventTimeByPath;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *lastModifyEmitByPath;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *directorySnapshots;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *plistSnapshots;

@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) NSUInteger stormDroppedCount;
@end

@implementation PMMonitor

- (instancetype)initWithConfig:(PMConfig *)config {
    self = [super init];
    if (self) {
        _config = config;
        _queue = dispatch_queue_create("com.procmonrootless.monitor", DISPATCH_QUEUE_SERIAL);
        _kqueueFD = -1;
        _fdToPath = [NSMutableDictionary dictionary];
        _pathToFD = [NSMutableDictionary dictionary];
        _lastEventTimeByPath = [NSMutableDictionary dictionary];
        _lastModifyEmitByPath = [NSMutableDictionary dictionary];
        _directorySnapshots = [NSMutableDictionary dictionary];
        _plistSnapshots = [NSMutableDictionary dictionary];
        _running = NO;
        _stormDroppedCount = 0;
    }
    return self;
}

- (void)reloadConfig:(PMConfig *)config {
    if (!config) {
        return;
    }

    dispatch_async(self.queue, ^{
        self.config = config;
        if (self.running) {
            [self rebuildWatchers];
        }
    });
}

- (void)start {
    dispatch_async(self.queue, ^{
        if (self.running) {
            return;
        }

        self.kqueueFD = kqueue();
        if (self.kqueueFD < 0) {
            return;
        }

        self.running = YES;
        [self rebuildWatchers];
        [self installKqueueReadSource];
        [self installRescanTimer];
    });
}

- (void)stop {
    dispatch_async(self.queue, ^{
        [self teardownLocked];
    });
}

- (BOOL)isRunning {
    __block BOOL running = NO;
    dispatch_sync(self.queue, ^{
        running = self.running;
    });
    return running;
}

- (NSUInteger)watcherCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.queue, ^{
        count = self.pathToFD.count;
    });
    return count;
}

- (NSDictionary *)statusSnapshot {
    __block NSDictionary *snapshot = @{};
    dispatch_sync(self.queue, ^{
        snapshot = @{
            @"running": @(self.running),
            @"watcher_count": @(self.pathToFD.count),
            @"storm_dropped": @(self.stormDroppedCount)
        };
    });
    return snapshot;
}

- (void)installKqueueReadSource {
    if (self.kqueueFD < 0 || self.kqueueReadSource) {
        return;
    }

    self.kqueueReadSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)self.kqueueFD, 0, self.queue);
    __weak typeof(self) weakSelf = self;

    dispatch_source_set_event_handler(self.kqueueReadSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf processKqueueEvents];
    });

    dispatch_source_set_cancel_handler(self.kqueueReadSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf.kqueueFD >= 0) {
            close(strongSelf.kqueueFD);
            strongSelf.kqueueFD = -1;
        }
    });

    dispatch_resume(self.kqueueReadSource);
}

- (void)installRescanTimer {
    if (self.rescanTimer) {
        return;
    }

    self.rescanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.rescanTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                              45 * NSEC_PER_SEC,
                              5 * NSEC_PER_SEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.rescanTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.running) {
            return;
        }
        [strongSelf rebuildWatchers];
    });

    dispatch_resume(self.rescanTimer);
}

- (void)processKqueueEvents {
    if (self.kqueueFD < 0 || !self.running) {
        return;
    }

    struct kevent events[64];
    struct timespec timeout = {0, 0};

    int eventCount = kevent(self.kqueueFD, NULL, 0, events, 64, &timeout);
    if (eventCount <= 0) {
        return;
    }

    for (int i = 0; i < eventCount; i++) {
        struct kevent kev = events[i];
        NSNumber *fdKey = @((int)kev.ident);
        NSString *path = self.fdToPath[fdKey];
        if (path.length == 0) {
            continue;
        }

        if ([self shouldDropAsStorm:path]) {
            continue;
        }

        if ([self isDirectoryPath:path] && (kev.fflags & (NOTE_WRITE | NOTE_RENAME | NOTE_EXTEND))) {
            [self emitDirectoryDiffEventsForPath:path];
        }

        PMEvent *event = [self eventFromPath:path flags:kev.fflags];
        if (event && self.eventHandler) {
            self.eventHandler(event);
        }

        if (kev.fflags & (NOTE_DELETE | NOTE_REVOKE)) {
            [self unregisterFD:(int)kev.ident];
        } else if (kev.fflags & NOTE_RENAME) {
            [self refreshWatchForPath:path];
        }

        if (kev.fflags & NOTE_WRITE) {
            [self maybeDiscoverNearbyForPath:path];
        }
    }
}

- (BOOL)shouldDropAsStorm:(NSString *)path {
    NSDate *now = [NSDate date];
    NSDate *previous = self.lastEventTimeByPath[path];
    self.lastEventTimeByPath[path] = now;

    if (!previous) {
        return NO;
    }

    NSTimeInterval interval = [now timeIntervalSinceDate:previous];
    if (interval < 0.05) {
        self.stormDroppedCount += 1;
        return YES;
    }

    return NO;
}

- (PMEvent *)eventFromPath:(NSString *)path flags:(uint32_t)flags {
    if ([self.config shouldIgnorePath:path]) {
        return nil;
    }

    BOOL isDirectory = [self isDirectoryPath:path];
    NSString *eventType = [self eventTypeForFlags:flags path:path];
    if (eventType.length == 0) {
        return nil;
    }

    if (isDirectory && (flags & (NOTE_WRITE | NOTE_EXTEND)) && [eventType isEqualToString:@"ATTRIB_CHANGED"]) {
        return nil;
    }

    if ([eventType isEqualToString:@"MODIFY_CONTENT"] && [self shouldCoalesceModifyEventForPath:path]) {
        return nil;
    }

    if ([self shouldSuppressEventType:eventType path:path]) {
        return nil;
    }

    PMEvent *event = [PMEvent eventWithType:eventType path:path];
    event.source = @"watcher";

    struct stat statInfo;
    if (lstat(path.fileSystemRepresentation, &statInfo) == 0) {
        event.uid = statInfo.st_uid;
        event.gid = statInfo.st_gid;
        event.mode = statInfo.st_mode;
        event.inode = statInfo.st_ino;
        event.size = statInfo.st_size;
    }

    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    metadata[@"fflags"] = @(flags);
    metadata[@"is_directory"] = @(isDirectory);

    if (self.config.plistParsingEnabled && [[path lowercaseString] hasSuffix:@".plist"]) {
        NSString *summary = [self plistDiffSummaryForPath:path eventType:eventType];
        if (summary.length > 0) {
            event.plistDiffSummary = summary;
            if ([summary containsString:@"changed"] || [summary containsString:@"diff added="] || [summary containsString:@"array count"]) {
                event.eventType = @"PLIST_VALUE_CHANGED";
            } else if ([summary containsString:@"baseline captured"] || [summary containsString:@"parse failed"] || [summary containsString:@"read failed"]) {
                event.eventType = @"PLIST_FILE_REWRITTEN";
            }
        }
    }

    if (metadata.count > 0) {
        event.extraMetadata = [metadata copy];
    }

    return event;
}

- (NSString *)eventTypeForFlags:(uint32_t)flags path:(NSString *)path {
    BOOL servicePath = ([path containsString:@"/LaunchDaemons/"] || [path containsString:@"/launchd.conf"] || [path containsString:@"/xpc/"]);
    BOOL packagePath = ([path containsString:@"/var/lib/dpkg/"] || [path containsString:@"/var/jb/var/lib/dpkg/"] || [path containsString:@"/apt/"]);

    if (flags & NOTE_DELETE) {
        if (packagePath) {
            return @"PACKAGE_REMOVE";
        }
        if (servicePath) {
            return @"SERVICE_STOPPED";
        }
        return @"DELETE";
    }
    if (flags & NOTE_RENAME) {
        return @"RENAME_MOVE";
    }
    if (flags & NOTE_ATTRIB) {
        return @"PERMISSION_CHANGED";
    }
    if (flags & NOTE_LINK) {
        return @"CREATE_FILE";
    }
    if (flags & NOTE_REVOKE) {
        return @"ATTRIB_CHANGED";
    }
    if (flags & NOTE_EXTEND) {
        if (packagePath) {
            return @"PACKAGE_INSTALL";
        }
        if (servicePath) {
            return @"SERVICE_STARTED";
        }
        return @"MODIFY_CONTENT";
    }
    if (flags & NOTE_WRITE) {
        if (packagePath) {
            return @"PACKAGE_INSTALL";
        }
        if (servicePath) {
            return @"SERVICE_STARTED";
        }
        return [self isDirectoryPath:path] ? @"ATTRIB_CHANGED" : @"MODIFY_CONTENT";
    }
    return @"ATTRIB_CHANGED";
}

- (void)rebuildWatchers {
    if (!self.running) {
        return;
    }

    NSSet<NSString *> *targetPaths = [NSSet setWithArray:[self discoverWatchPaths]];

    NSMutableSet<NSString *> *currentPaths = [NSMutableSet setWithArray:self.pathToFD.allKeys];
    NSMutableSet<NSString *> *toRemove = [currentPaths mutableCopy];
    [toRemove minusSet:targetPaths];

    for (NSString *path in toRemove) {
        NSNumber *fdNumber = self.pathToFD[path];
        if (fdNumber) {
            [self unregisterFD:fdNumber.intValue];
        }
    }

    NSMutableSet<NSString *> *toAdd = [targetPaths mutableCopy];
    [toAdd minusSet:currentPaths];

    NSUInteger cap = [PMConfig maxWatcherCount];
    for (NSString *path in toAdd) {
        if (self.pathToFD.count >= cap) {
            break;
        }
        [self registerWatchForPath:path];
    }
}

- (NSArray<NSString *> *)discoverWatchPaths {
    NSUInteger cap = [PMConfig maxWatcherCount];
    NSUInteger maxDepth = 3;
    NSUInteger maxChildrenPerDirectory = 80;

    NSMutableOrderedSet<NSString *> *discovered = [NSMutableOrderedSet orderedSet];
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray array];

    for (NSString *root in [PMConfig defaultDiscoveryRoots]) {
        [queue addObject:@{ @"path": root, @"depth": @(0) }];
    }

    for (NSString *sensitive in [PMConfig sensitivePaths]) {
        [queue addObject:@{ @"path": sensitive, @"depth": @(0) }];
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];

    while (queue.count > 0 && discovered.count < cap) {
        NSDictionary *entry = queue.firstObject;
        [queue removeObjectAtIndex:0];

        NSString *path = entry[@"path"];
        NSUInteger depth = [entry[@"depth"] unsignedIntegerValue];

        if (path.length == 0 || [self.config shouldIgnorePath:path] || [discovered containsObject:path]) {
            continue;
        }

        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory]) {
            continue;
        }

        if (!isDirectory) {
            if ([self shouldWatchFilePath:path]) {
                [discovered addObject:path];
            }
            continue;
        }

        [discovered addObject:path];
        if (depth >= maxDepth) {
            continue;
        }

        NSArray<NSString *> *children = [fileManager contentsOfDirectoryAtPath:path error:nil];
        if (![children isKindOfClass:[NSArray class]]) {
            continue;
        }

        NSUInteger childCount = 0;
        for (NSString *childName in children) {
            if (childCount >= maxChildrenPerDirectory || discovered.count >= cap) {
                break;
            }

            if (childName.length == 0 || [childName hasPrefix:@"."]) {
                continue;
            }

            NSString *childPath = [path stringByAppendingPathComponent:childName];
            BOOL childIsDir = NO;
            if ([fileManager fileExistsAtPath:childPath isDirectory:&childIsDir] && ![self.config shouldIgnorePath:childPath]) {
                if (!childIsDir && [self shouldWatchFilePath:childPath]) {
                    [discovered addObject:childPath];
                    childCount += 1;
                    continue;
                }
            }

            if ([fileManager fileExistsAtPath:childPath isDirectory:&childIsDir] && childIsDir && ![self.config shouldIgnorePath:childPath]) {
                [queue addObject:@{ @"path": childPath, @"depth": @(depth + 1) }];
                childCount += 1;
            }
        }
    }

    return discovered.array;
}

- (BOOL)registerWatchForPath:(NSString *)path {
    if (path.length == 0 || self.pathToFD[path] != nil || self.kqueueFD < 0) {
        return NO;
    }

    int fd = open(path.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) {
        return NO;
    }

    struct kevent kev;
    EV_SET(&kev,
           fd,
           EVFILT_VNODE,
           EV_ADD | EV_CLEAR,
           NOTE_DELETE | NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_LINK | NOTE_RENAME | NOTE_REVOKE,
           0,
           NULL);

    if (kevent(self.kqueueFD, &kev, 1, NULL, 0, NULL) < 0) {
        close(fd);
        return NO;
    }

    NSString *normalizedPath = [path copy];
    NSNumber *fdNumber = @(fd);
    self.fdToPath[fdNumber] = normalizedPath;
    self.pathToFD[normalizedPath] = fdNumber;

    if ([self isDirectoryPath:normalizedPath]) {
        NSDictionary *snapshot = [self snapshotDirectoryForPath:normalizedPath];
        if (snapshot) {
            self.directorySnapshots[normalizedPath] = snapshot;
        }
    }

    return YES;
}

- (void)refreshWatchForPath:(NSString *)path {
    NSNumber *fdNumber = self.pathToFD[path];
    if (fdNumber) {
        [self unregisterFD:fdNumber.intValue];
    }
    [self registerWatchForPath:path];
}

- (void)unregisterFD:(int)fd {
    NSNumber *fdNumber = @(fd);
    NSString *path = self.fdToPath[fdNumber];
    if (path) {
        [self.pathToFD removeObjectForKey:path];
        [self.lastEventTimeByPath removeObjectForKey:path];
        [self.lastModifyEmitByPath removeObjectForKey:path];
        [self.directorySnapshots removeObjectForKey:path];
    }
    [self.fdToPath removeObjectForKey:fdNumber];

    if (self.kqueueFD >= 0) {
        struct kevent kev;
        EV_SET(&kev, fd, EVFILT_VNODE, EV_DELETE, 0, 0, NULL);
        kevent(self.kqueueFD, &kev, 1, NULL, 0, NULL);
    }

    close(fd);
}

- (void)maybeDiscoverNearbyForPath:(NSString *)path {
    if ([self.pathToFD count] >= [PMConfig maxWatcherCount]) {
        return;
    }

    NSString *parent = [path stringByDeletingLastPathComponent];
    if (parent.length == 0 || [self.config shouldIgnorePath:parent]) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *children = [fileManager contentsOfDirectoryAtPath:parent error:nil];
    NSUInteger added = 0;

    for (NSString *childName in children) {
        if (added >= 8 || [self.pathToFD count] >= [PMConfig maxWatcherCount]) {
            break;
        }

        NSString *childPath = [parent stringByAppendingPathComponent:childName];
        BOOL isDir = NO;
        if ([fileManager fileExistsAtPath:childPath isDirectory:&isDir] && ![self.config shouldIgnorePath:childPath] && !self.pathToFD[childPath]) {
            if (!isDir && [self shouldWatchFilePath:childPath]) {
                if ([self registerWatchForPath:childPath]) {
                    added += 1;
                }
                continue;
            }

            if (isDir && [self registerWatchForPath:childPath]) {
                added += 1;
            }
        }
    }
}

- (BOOL)isDirectoryPath:(NSString *)path {
    BOOL isDir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir;
}

- (NSNumber *)fileKindForPath:(NSString *)path {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) != 0) {
        return nil;
    }

    if (S_ISDIR(st.st_mode)) {
        return @(1); // directory
    }
    if (S_ISLNK(st.st_mode)) {
        return @(2); // symlink
    }
    return @(0); // regular/other file
}

- (BOOL)shouldWatchFilePath:(NSString *)path {
    if (path.length == 0 || [self.config shouldIgnorePath:path]) {
        return NO;
    }

    NSString *lower = [path lowercaseString];
    if ([lower hasSuffix:@".plist"]) {
        return YES;
    }
    if ([lower hasSuffix:@".conf"] && [lower containsString:@"/launch"]) {
        return YES;
    }
    if ([lower containsString:@"/var/lib/dpkg/status"] || [lower containsString:@"/var/jb/var/lib/dpkg/status"]) {
        return YES;
    }
    if ([lower containsString:@"/var/lib/dpkg/info/"] || [lower containsString:@"/var/jb/var/lib/dpkg/info/"]) {
        return YES;
    }
    return NO;
}

- (BOOL)shouldSuppressEventType:(NSString *)eventType path:(NSString *)path {
    if (eventType.length == 0 || path.length == 0) {
        return YES;
    }

    if (![PMConfig isNoisyPathForDisplay:path]) {
        return NO;
    }

    static NSSet<NSString *> *allowOnNoisyPaths = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allowOnNoisyPaths = [NSSet setWithArray:@[
            @"PACKAGE_INSTALL",
            @"PACKAGE_REMOVE",
            @"SERVICE_STARTED",
            @"SERVICE_STOPPED",
            @"PLIST_VALUE_CHANGED",
            @"PLIST_FILE_REWRITTEN"
        ]];
    });

    return ![allowOnNoisyPaths containsObject:eventType];
}

- (BOOL)shouldCoalesceModifyEventForPath:(NSString *)path {
    NSDate *now = [NSDate date];
    NSDate *previous = self.lastModifyEmitByPath[path];
    if (previous && [now timeIntervalSinceDate:previous] < 1.2) {
        return YES;
    }
    self.lastModifyEmitByPath[path] = now;
    return NO;
}

- (NSDictionary<NSString *, NSNumber *> *)snapshotDirectoryForPath:(NSString *)directoryPath {
    if (![self isDirectoryPath:directoryPath] || [self.config shouldIgnorePath:directoryPath]) {
        return nil;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *children = [fileManager contentsOfDirectoryAtPath:directoryPath error:nil];
    if (![children isKindOfClass:[NSArray class]]) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSNumber *> *snapshot = [NSMutableDictionary dictionary];
    NSUInteger count = 0;
    for (NSString *child in children) {
        if (count >= 200) {
            break;
        }
        if (child.length == 0 || [child hasPrefix:@"."]) {
            continue;
        }
        NSString *childPath = [directoryPath stringByAppendingPathComponent:child];
        if ([self.config shouldIgnorePath:childPath]) {
            continue;
        }
        NSNumber *kind = [self fileKindForPath:childPath];
        if (kind != nil) {
            snapshot[child] = kind;
            count += 1;
        }
    }

    return [snapshot copy];
}

- (void)emitDirectoryDiffEventsForPath:(NSString *)directoryPath {
    NSDictionary<NSString *, NSNumber *> *previous = self.directorySnapshots[directoryPath];
    NSDictionary<NSString *, NSNumber *> *current = [self snapshotDirectoryForPath:directoryPath];
    if (!current) {
        return;
    }

    self.directorySnapshots[directoryPath] = current;
    if (!previous) {
        return;
    }

    NSMutableSet<NSString *> *previousNames = [NSMutableSet setWithArray:previous.allKeys];
    NSMutableSet<NSString *> *currentNames = [NSMutableSet setWithArray:current.allKeys];

    NSMutableSet<NSString *> *added = [currentNames mutableCopy];
    [added minusSet:previousNames];

    NSMutableSet<NSString *> *removed = [previousNames mutableCopy];
    [removed minusSet:currentNames];

    if (added.count == 1 && removed.count == 1) {
        NSString *newName = added.anyObject;
        NSString *oldName = removed.anyObject;
        NSString *newPath = [directoryPath stringByAppendingPathComponent:newName];
        NSString *oldPath = [directoryPath stringByAppendingPathComponent:oldName];
        [self emitSyntheticEventType:@"RENAME_MOVE" path:newPath oldPath:oldPath newPath:newPath];
        return;
    }

    for (NSString *name in added) {
        NSString *childPath = [directoryPath stringByAppendingPathComponent:name];
        NSInteger kind = [current[name] integerValue];
        NSString *createType = @"CREATE_FILE";
        if (kind == 1) {
            createType = @"CREATE_DIR";
        }
        [self emitSyntheticEventType:createType path:childPath oldPath:nil newPath:nil];
    }

    for (NSString *name in removed) {
        NSString *childPath = [directoryPath stringByAppendingPathComponent:name];
        [self emitSyntheticEventType:@"DELETE" path:childPath oldPath:nil newPath:nil];
    }
}

- (void)emitSyntheticEventType:(NSString *)eventType path:(NSString *)path oldPath:(NSString *)oldPath newPath:(NSString *)newPath {
    if (eventType.length == 0 || path.length == 0 || [self.config shouldIgnorePath:path]) {
        return;
    }
    if ([self shouldSuppressEventType:eventType path:path]) {
        return;
    }

    PMEvent *event = [PMEvent eventWithType:eventType path:path];
    event.source = @"watcher";
    event.oldPath = oldPath;
    event.newPath = newPath;

    struct stat statInfo;
    if (lstat(path.fileSystemRepresentation, &statInfo) == 0) {
        event.uid = statInfo.st_uid;
        event.gid = statInfo.st_gid;
        event.mode = statInfo.st_mode;
        event.inode = statInfo.st_ino;
        event.size = statInfo.st_size;
    }

    if (self.config.plistParsingEnabled && [[path lowercaseString] hasSuffix:@".plist"] &&
        ([eventType isEqualToString:@"MODIFY_CONTENT"] || [eventType isEqualToString:@"CREATE_FILE"])) {
        NSString *summary = [self plistDiffSummaryForPath:path eventType:eventType];
        if (summary.length > 0) {
            event.plistDiffSummary = summary;
            if ([summary containsString:@"changed"] || [summary containsString:@"diff added="] || [summary containsString:@"array count"]) {
                event.eventType = @"PLIST_VALUE_CHANGED";
            } else if ([summary containsString:@"baseline captured"] || [summary containsString:@"parse failed"] || [summary containsString:@"read failed"]) {
                event.eventType = @"PLIST_FILE_REWRITTEN";
            }
        }
    }

    if (self.eventHandler) {
        self.eventHandler(event);
    }
}

- (NSString *)plistDiffSummaryForPath:(NSString *)path eventType:(NSString *)eventType {
    @try {
        if ([[eventType uppercaseString] isEqualToString:@"DELETE"]) {
            [self.plistSnapshots removeObjectForKey:path];
            return @"plist deleted";
        }

        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        if (!data) {
            return @"plist read failed";
        }

        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        NSError *parseError = nil;
        id newValue = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:&format error:&parseError];
        if (!newValue || parseError) {
            return @"plist parse failed";
        }

        id oldValue = self.plistSnapshots[path];
        self.plistSnapshots[path] = newValue;

        if (!oldValue) {
            return @"plist baseline captured";
        }

        if ([oldValue isKindOfClass:[NSDictionary class]] && [newValue isKindOfClass:[NSDictionary class]]) {
            NSDictionary *oldDict = (NSDictionary *)oldValue;
            NSDictionary *newDict = (NSDictionary *)newValue;

            NSMutableSet *oldKeys = [NSMutableSet setWithArray:oldDict.allKeys];
            NSMutableSet *newKeys = [NSMutableSet setWithArray:newDict.allKeys];

            NSMutableSet *added = [newKeys mutableCopy];
            [added minusSet:oldKeys];

            NSMutableSet *removed = [oldKeys mutableCopy];
            [removed minusSet:newKeys];

            NSUInteger changedCount = 0;
            for (NSString *key in oldKeys) {
                id oldObj = oldDict[key];
                id newObj = newDict[key];
                if (newObj && ![oldObj isEqual:newObj]) {
                    changedCount += 1;
                }
            }

            NSMutableArray<NSString *> *topChanges = [NSMutableArray array];
            for (NSString *key in added) {
                if (topChanges.count >= 3) {
                    break;
                }
                [topChanges addObject:[NSString stringWithFormat:@"+%@", key]];
            }
            for (NSString *key in removed) {
                if (topChanges.count >= 3) {
                    break;
                }
                [topChanges addObject:[NSString stringWithFormat:@"-%@", key]];
            }

            NSString *summary = [NSString stringWithFormat:@"plist diff added=%lu removed=%lu changed=%lu%@",
                                 (unsigned long)added.count,
                                 (unsigned long)removed.count,
                                 (unsigned long)changedCount,
                                 topChanges.count > 0 ? [NSString stringWithFormat:@" keys=%@", [topChanges componentsJoinedByString:@", "]] : @""];
            return summary;
        }

        if ([oldValue isKindOfClass:[NSArray class]] && [newValue isKindOfClass:[NSArray class]]) {
            NSInteger delta = (NSInteger)[(NSArray *)newValue count] - (NSInteger)[(NSArray *)oldValue count];
            return [NSString stringWithFormat:@"plist array count %ld -> %ld (delta=%ld)",
                    (long)[(NSArray *)oldValue count],
                    (long)[(NSArray *)newValue count],
                    (long)delta];
        }

        if (![oldValue isEqual:newValue]) {
            return @"plist value changed";
        }

        return @"plist unchanged";
    } @catch (__unused NSException *exception) {
        return @"plist diff exception";
    }
}

- (void)teardownLocked {
    if (self.rescanTimer) {
        dispatch_source_cancel(self.rescanTimer);
        self.rescanTimer = nil;
    }

    if (self.kqueueReadSource) {
        dispatch_source_cancel(self.kqueueReadSource);
        self.kqueueReadSource = nil;
    } else if (self.kqueueFD >= 0) {
        close(self.kqueueFD);
        self.kqueueFD = -1;
    }

    NSArray<NSNumber *> *allFDs = self.fdToPath.allKeys;
    for (NSNumber *fdNumber in allFDs) {
        close(fdNumber.intValue);
    }

    [self.fdToPath removeAllObjects];
    [self.pathToFD removeAllObjects];
    [self.lastEventTimeByPath removeAllObjects];
    [self.lastModifyEmitByPath removeAllObjects];
    [self.directorySnapshots removeAllObjects];
    [self.plistSnapshots removeAllObjects];
    self.running = NO;
}

@end
