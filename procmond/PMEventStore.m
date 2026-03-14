#import "PMEventStore.h"

#import "../shared/PMConfig.h"
#import "../shared/PMEvent.h"

@interface PMEventStore ()
@property (nonatomic, strong) PMConfig *config;
@property (nonatomic, strong) NSMutableArray<PMEvent *> *recentEvents;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation PMEventStore

- (instancetype)initWithConfig:(PMConfig *)config {
    self = [super init];
    if (self) {
        _config = config;
        _recentEvents = [NSMutableArray array];
        _queue = dispatch_queue_create("com.procmonrootless.eventstore", DISPATCH_QUEUE_SERIAL);
        [PMConfig ensureRuntimeDirectories];
    }
    return self;
}

- (void)reloadConfig:(PMConfig *)config {
    if (!config) {
        return;
    }

    dispatch_async(self.queue, ^{
        self.config = config;
    });
}

- (void)appendEvent:(PMEvent *)event {
    if (!event) {
        return;
    }

    dispatch_async(self.queue, ^{
        [self.recentEvents addObject:event];
        NSUInteger maxRecent = [PMConfig maxRecentEvents];
        if (self.recentEvents.count > maxRecent) {
            NSUInteger removeCount = self.recentEvents.count - maxRecent;
            [self.recentEvents removeObjectsInRange:NSMakeRange(0, removeCount)];
        }

        [self appendLine:event.humanReadableLine toPath:[PMConfig humanLogPath]];

        NSError *jsonError = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:[event toDictionary] options:0 error:&jsonError];
        if (jsonData && !jsonError) {
            NSMutableData *lineData = [jsonData mutableCopy];
            const char newline = '\n';
            [lineData appendBytes:&newline length:1];
            [self appendData:lineData toPath:[PMConfig jsonLogPath]];
        }
    });
}

- (NSArray<NSDictionary *> *)recentEventsWithLimit:(NSUInteger)limit {
    __block NSArray<NSDictionary *> *snapshot = @[];
    dispatch_sync(self.queue, ^{
        NSUInteger count = self.recentEvents.count;
        NSUInteger effectiveLimit = limit == 0 ? MIN((NSUInteger)50, count) : MIN(limit, count);
        NSRange range = NSMakeRange(count - effectiveLimit, effectiveLimit);
        NSArray<PMEvent *> *slice = [self.recentEvents subarrayWithRange:range];

        NSMutableArray<NSDictionary *> *events = [NSMutableArray arrayWithCapacity:slice.count];
        for (PMEvent *event in slice) {
            [events addObject:[event toDictionary]];
        }
        snapshot = [events copy];
    });
    return snapshot;
}

- (NSUInteger)recentCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.queue, ^{
        count = self.recentEvents.count;
    });
    return count;
}

- (BOOL)clearLogs:(NSError **)error {
    __block BOOL success = YES;
    __block NSError *localError = nil;

    dispatch_sync(self.queue, ^{
        [self.recentEvents removeAllObjects];
        success = [@"" writeToFile:[PMConfig humanLogPath] atomically:YES encoding:NSUTF8StringEncoding error:&localError];
        if (success) {
            success = [@"" writeToFile:[PMConfig jsonLogPath] atomically:YES encoding:NSUTF8StringEncoding error:&localError];
        }
    });

    if (!success && error) {
        *error = localError;
    }

    return success;
}

- (nullable NSString *)exportLogs:(NSError **)error {
    __block NSString *exportPath = nil;
    __block NSError *localError = nil;

    dispatch_sync(self.queue, ^{
        [PMConfig ensureRuntimeDirectories];

        NSString *fileName = [NSString stringWithFormat:@"procmon-export-%.0f.json", [[NSDate date] timeIntervalSince1970]];
        exportPath = [[PMConfig exportDirectoryPath] stringByAppendingPathComponent:fileName];

        NSMutableDictionary *exportObject = [NSMutableDictionary dictionary];
        exportObject[@"generated_at"] = @([[NSDate date] timeIntervalSince1970]);
        NSMutableArray<NSDictionary *> *recent = [NSMutableArray arrayWithCapacity:self.recentEvents.count];
        for (PMEvent *event in self.recentEvents) {
            [recent addObject:[event toDictionary]];
        }
        exportObject[@"recent"] = [recent copy];

        NSString *humanLog = [NSString stringWithContentsOfFile:[PMConfig humanLogPath] encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSString *jsonLog = [NSString stringWithContentsOfFile:[PMConfig jsonLogPath] encoding:NSUTF8StringEncoding error:nil] ?: @"";
        exportObject[@"human_log"] = humanLog;
        exportObject[@"jsonl_log"] = jsonLog;

        NSData *data = [NSJSONSerialization dataWithJSONObject:exportObject options:NSJSONWritingPrettyPrinted error:&localError];
        if (!data || localError) {
            exportPath = nil;
            return;
        }

        if (![data writeToFile:exportPath options:NSDataWritingAtomic error:&localError]) {
            exportPath = nil;
        }
    });

    if (!exportPath && error) {
        *error = localError;
    }

    return exportPath;
}

- (void)appendLine:(NSString *)line toPath:(NSString *)path {
    NSString *safeLine = line ?: @"";
    NSData *data = [[safeLine stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    [self appendData:data toPath:path];
}

- (void)appendData:(NSData *)data toPath:(NSString *)path {
    if (!data || data.length == 0 || path.length == 0) {
        return;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:path]) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        return;
    }

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *exception) {
    } @finally {
        @try {
            [handle closeFile];
        } @catch (__unused NSException *exception) {
        }
    }
}

@end
