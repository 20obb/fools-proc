#import "PMTweakClient.h"

#import <errno.h>
#import <fcntl.h>
#import <spawn.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

#import "../shared/PMConfig.h"
#import "../shared/PMIPCProtocol.h"

extern char **environ;

@interface PMTweakClient ()
@property (nonatomic, assign) int socketFD;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) dispatch_source_t reconnectTimer;
@property (nonatomic, strong) NSMutableData *readBuffer;
@property (nonatomic, assign) BOOL connected;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) NSTimeInterval reconnectDelay;
@property (nonatomic, assign) BOOL monitoringRunning;
@property (nonatomic, assign) BOOL procmonEnabled;
@property (nonatomic, assign) NSTimeInterval lastDaemonLaunchAttempt;
- (BOOL)writeDataLocked:(NSData *)data;
- (void)attemptDaemonLaunchLocked;
- (void)spawnProcessAtPath:(NSString *)path arguments:(NSArray<NSString *> *)arguments;
@end

@implementation PMTweakClient

+ (instancetype)sharedInstance {
    static PMTweakClient *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[PMTweakClient alloc] initPrivate];
    });
    return shared;
}

- (instancetype)init {
    [NSException raise:@"Singleton" format:@"Use +sharedInstance"]; 
    return nil;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        signal(SIGPIPE, SIG_IGN);
        _socketFD = -1;
        _queue = dispatch_queue_create("com.procmonrootless.tweakclient", DISPATCH_QUEUE_SERIAL);
        _readBuffer = [NSMutableData data];
        _running = NO;
        _connected = NO;
        _reconnectDelay = 1.0;
        _monitoringRunning = NO;
        _procmonEnabled = YES;
        _lastDaemonLaunchAttempt = 0;
    }
    return self;
}

- (void)start {
    dispatch_async(self.queue, ^{
        self.running = YES;
        [self connectIfNeeded];
    });
}

- (void)stop {
    dispatch_async(self.queue, ^{
        self.running = NO;
        [self invalidateReconnectTimer];
        [self closeConnectionLocked];
    });
}

- (void)requestStatus {
    dispatch_async(self.queue, ^{
        if (!self.connected) {
            [self connectIfNeeded];
            return;
        }
        // Force monitor to stay active, then fetch current status.
        [self sendCommandLocked:@{ @"command": @"start" }];
        [self sendCommandLocked:@{ @"command": @"status" }];
    });
}

- (void)sendHookEventType:(NSString *)eventType
                     path:(NSString *)path
                  oldPath:(nullable NSString *)oldPath
                  newPath:(nullable NSString *)newPath
                    extra:(nullable NSDictionary *)extra {
    if (eventType.length == 0 || path.length == 0) {
        return;
    }

    dispatch_async(self.queue, ^{
        if (!self.connected) {
            [self connectIfNeeded];
            return;
        }

        NSMutableDictionary *event = [NSMutableDictionary dictionary];
        event[@"event_type"] = eventType;
        event[@"path"] = path;
        event[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
        event[@"pid"] = @(getpid());
        event[@"process_name"] = @"SpringBoard";
        event[@"source"] = @"hook";
        if (oldPath.length > 0) {
            event[@"old_path"] = oldPath;
        }
        if (newPath.length > 0) {
            event[@"new_path"] = newPath;
        }
        if (extra.count > 0) {
            event[@"extra_metadata"] = extra;
        }

        NSDictionary *request = @{
            @"command": @"report_hook_event",
            @"event": event
        };

        [self sendCommandLocked:request];
    });
}

- (void)connectIfNeeded {
    if (!self.running || self.connected) {
        return;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        [self scheduleReconnectLocked];
        return;
    }
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, [PMConfig socketPath].fileSystemRepresentation, sizeof(addr.sun_path));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int connectErrno = errno;
        close(fd);
        if (connectErrno == ENOENT || connectErrno == ECONNREFUSED || connectErrno == EACCES || connectErrno == EPERM) {
            [self attemptDaemonLaunchLocked];
        }
        [self scheduleReconnectLocked];
        return;
    }

    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0) {
        close(fd);
        [self scheduleReconnectLocked];
        return;
    }

    self.socketFD = fd;
    self.connected = YES;
    self.reconnectDelay = 1.0;
    [self installReadSourceLocked];

    [self notifyStatusChangedLocked];

    [self sendCommandLocked:@{ @"command": @"subscribe_live" }];
    [self sendCommandLocked:@{ @"command": @"start" }];
    [self sendCommandLocked:@{ @"command": @"status" }];
}

- (void)installReadSourceLocked {
    if (self.readSource || self.socketFD < 0) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    self.readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)self.socketFD, 0, self.queue);

    dispatch_source_set_event_handler(self.readSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf readIncomingLocked];
    });

    dispatch_source_set_cancel_handler(self.readSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (strongSelf.socketFD >= 0) {
            close(strongSelf.socketFD);
            strongSelf.socketFD = -1;
        }
    });

    dispatch_resume(self.readSource);
}

- (void)readIncomingLocked {
    while (1) {
        uint8_t buffer[4096];
        ssize_t bytesRead = read(self.socketFD, buffer, sizeof(buffer));
        if (bytesRead > 0) {
            [self.readBuffer appendBytes:buffer length:(NSUInteger)bytesRead];
            if (self.readBuffer.length > (128 * 1024)) {
                [self.readBuffer setLength:0];
            }
            continue;
        }

        if (bytesRead == 0) {
            [self handleDisconnectLocked];
            return;
        }

        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            break;
        }

        [self handleDisconnectLocked];
        return;
    }

    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    while (1) {
        NSRange range = [self.readBuffer rangeOfData:newline options:0 range:NSMakeRange(0, self.readBuffer.length)];
        if (range.location == NSNotFound) {
            break;
        }

        NSData *line = [self.readBuffer subdataWithRange:NSMakeRange(0, range.location)];
        [self.readBuffer replaceBytesInRange:NSMakeRange(0, range.location + 1) withBytes:NULL length:0];

        if (line.length == 0 || line.length > [PMConfig maxIPCLineBytes]) {
            continue;
        }

        NSError *error = nil;
        NSDictionary *message = [PMIPCProtocol dictionaryFromLineData:line error:&error];
        if (!message || error) {
            continue;
        }

        [self handleMessageLocked:message];
    }
}

- (void)handleMessageLocked:(NSDictionary *)message {
    NSString *type = [message[@"type"] isKindOfClass:[NSString class]] ? message[@"type"] : nil;
    if ([type isEqualToString:@"event"]) {
        NSDictionary *event = [message[@"event"] isKindOfClass:[NSDictionary class]] ? message[@"event"] : nil;
        if (!event) {
            return;
        }

        void (^handler)(NSDictionary *) = self.eventHandler;
        if (handler) {
            dispatch_async(dispatch_get_main_queue(), ^{
                handler(event);
            });
        }
        return;
    }

    if (![type isEqualToString:@"response"]) {
        return;
    }

    BOOL ok = [message[@"ok"] respondsToSelector:@selector(boolValue)] ? [message[@"ok"] boolValue] : NO;
    NSString *command = [message[@"command"] isKindOfClass:[NSString class]] ? message[@"command"] : nil;

    if (ok && [command isEqualToString:@"status"]) {
        NSDictionary *data = [message[@"data"] isKindOfClass:[NSDictionary class]] ? message[@"data"] : nil;
        if (data) {
            self.monitoringRunning = [data[@"monitoring_running"] respondsToSelector:@selector(boolValue)] ? [data[@"monitoring_running"] boolValue] : NO;
            self.procmonEnabled = [data[@"procmon_enabled"] respondsToSelector:@selector(boolValue)] ? [data[@"procmon_enabled"] boolValue] : YES;
            [self notifyStatusChangedLocked];
        }
    }
}

- (void)notifyStatusChangedLocked {
    void (^statusHandler)(BOOL, BOOL, BOOL) = self.statusHandler;
    if (statusHandler) {
        BOOL connected = self.connected;
        BOOL monitoring = self.monitoringRunning;
        BOOL enabled = self.procmonEnabled;
        dispatch_async(dispatch_get_main_queue(), ^{
            statusHandler(connected, monitoring, enabled);
        });
    }
}

- (void)sendCommandLocked:(NSDictionary *)command {
    if (self.socketFD < 0) {
        return;
    }

    NSError *error = nil;
    NSData *line = [PMIPCProtocol lineDataFromJSONObject:command error:&error];
    if (!line || error || line.length > [PMConfig maxIPCLineBytes]) {
        return;
    }

    if (![self writeDataLocked:line]) {
        [self handleDisconnectLocked];
    }
}

- (void)handleDisconnectLocked {
    [self closeConnectionLocked];
    [self scheduleReconnectLocked];
}

- (void)closeConnectionLocked {
    if (self.readSource) {
        dispatch_source_cancel(self.readSource);
        self.readSource = nil;
    } else if (self.socketFD >= 0) {
        close(self.socketFD);
        self.socketFD = -1;
    }

    self.connected = NO;
    self.monitoringRunning = NO;
    [self.readBuffer setLength:0];
    [self notifyStatusChangedLocked];
}

- (void)scheduleReconnectLocked {
    if (!self.running || self.reconnectTimer) {
        return;
    }

    NSTimeInterval delay = self.reconnectDelay;
    self.reconnectDelay = MIN(self.reconnectDelay * 1.8, 30.0);

    self.reconnectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.reconnectTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              0);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.reconnectTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf invalidateReconnectTimer];
        [strongSelf connectIfNeeded];
    });

    dispatch_resume(self.reconnectTimer);
}

- (void)invalidateReconnectTimer {
    if (self.reconnectTimer) {
        dispatch_source_cancel(self.reconnectTimer);
        self.reconnectTimer = nil;
    }
}

- (BOOL)writeDataLocked:(NSData *)data {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger remaining = data.length;
    NSUInteger offset = 0;
    int eagainCount = 0;

    while (remaining > 0) {
        ssize_t written = send(self.socketFD, bytes + offset, remaining, 0);
        if (written > 0) {
            offset += (NSUInteger)written;
            remaining -= (NSUInteger)written;
            continue;
        }

        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            eagainCount += 1;
            if (eagainCount > 8) {
                return NO;
            }
            usleep(1000);
            continue;
        }

        return NO;
    }

    return YES;
}

- (void)attemptDaemonLaunchLocked {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if ((now - self.lastDaemonLaunchAttempt) < 8.0) {
        return;
    }
    self.lastDaemonLaunchAttempt = now;

    [PMConfig ensureRuntimeDirectories];
    unlink([PMConfig socketPath].fileSystemRepresentation);

    NSString *label = @"system/com.procmonrootless.procmond";
    NSString *plistPath = @"/var/jb/Library/LaunchDaemons/com.procmonrootless.procmond.plist";

    NSString *launchctlPath = nil;
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:@"/var/jb/bin/launchctl"]) {
        launchctlPath = @"/var/jb/bin/launchctl";
    } else if ([[NSFileManager defaultManager] isExecutableFileAtPath:@"/bin/launchctl"]) {
        launchctlPath = @"/bin/launchctl";
    }

    if (launchctlPath.length > 0) {
        [self spawnProcessAtPath:launchctlPath arguments:@[@"bootstrap", @"system", plistPath]];
        [self spawnProcessAtPath:launchctlPath arguments:@[@"enable", label]];
        [self spawnProcessAtPath:launchctlPath arguments:@[@"kickstart", @"-k", label]];
    }

    // Fallback: run daemon directly if launchctl actions are blocked in this context.
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:@"/var/jb/usr/libexec/procmond"]) {
        [self spawnProcessAtPath:@"/var/jb/usr/libexec/procmond" arguments:@[]];
    }
}

- (void)spawnProcessAtPath:(NSString *)path arguments:(NSArray<NSString *> *)arguments {
    if (path.length == 0 || ![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        return;
    }

    NSUInteger argCount = arguments.count + 2;
    char **argv = (char **)calloc(argCount, sizeof(char *));
    if (!argv) {
        return;
    }

    argv[0] = strdup(path.fileSystemRepresentation);
    for (NSUInteger idx = 0; idx < arguments.count; idx++) {
        NSString *arg = arguments[idx];
        argv[idx + 1] = strdup(arg.UTF8String ?: "");
    }
    argv[argCount - 1] = NULL;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, argv, environ);
    (void)rc;

    for (NSUInteger idx = 0; idx < argCount - 1; idx++) {
        if (argv[idx]) {
            free(argv[idx]);
        }
    }
    free(argv);
}

@end
