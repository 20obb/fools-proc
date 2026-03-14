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

    NSString *eventType = [self eventTypeForFlags:flags path:path];
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
    metadata[@"is_directory"] = @([self isDirectoryPath:path]);

    if (self.config.plistParsingEnabled && [[path lowercaseString] hasSuffix:@".plist"]) {
        NSString *summary = [self plistDiffSummaryForPath:path eventType:eventType];
        if (summary.length > 0) {
            event.plistDiffSummary = summary;
        }
    }

    if (metadata.count > 0) {
        event.extraMetadata = [metadata copy];
    }

    return event;
}

- (NSString *)eventTypeForFlags:(uint32_t)flags path:(NSString *)path {
    BOOL servicePath = ([path containsString:@"/LaunchDaemons/"] || [path containsString:@"/launchd.conf"] || [path containsString:@"/xpc/"]);

    if (flags & NOTE_DELETE) {
        return servicePath ? @"service_config_delete" : @"delete";
    }
    if (flags & NOTE_RENAME) {
        return servicePath ? @"service_config_rename" : @"rename";
    }
    if (flags & NOTE_ATTRIB) {
        return servicePath ? @"service_config_attrib" : @"attrib";
    }
    if (flags & NOTE_EXTEND) {
        return servicePath ? @"service_config_change" : @"extend";
    }
    if (flags & NOTE_REVOKE) {
        return @"revoke";
    }
    if (flags & NOTE_LINK) {
        return @"link";
    }
    if (flags & NOTE_WRITE) {
        if (servicePath) {
            return @"service_runtime_activity";
        }
        return [self isDirectoryPath:path] ? @"dir_modify" : @"write";
    }
    return @"unknown";
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
        if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
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
        if ([fileManager fileExistsAtPath:childPath isDirectory:&isDir] && isDir && ![self.config shouldIgnorePath:childPath] && !self.pathToFD[childPath]) {
            if ([self registerWatchForPath:childPath]) {
                added += 1;
            }
        }
    }
}

- (BOOL)isDirectoryPath:(NSString *)path {
    BOOL isDir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir;
}

- (NSString *)plistDiffSummaryForPath:(NSString *)path eventType:(NSString *)eventType {
    @try {
        if ([eventType isEqualToString:@"delete"]) {
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
    [self.plistSnapshots removeAllObjects];
    self.running = NO;
}

@end
