#import "PMDaemon.h"

#import "PMEventStore.h"
#import "PMIPCServer.h"
#import "PMMonitor.h"
#import <unistd.h>
#import "../shared/PMConfig.h"
#import "../shared/PMEvent.h"
#import "../shared/PMIPCProtocol.h"

@interface PMDaemon ()
@property (nonatomic, strong) PMConfig *config;
@property (nonatomic, strong) PMEventStore *eventStore;
@property (nonatomic, strong) PMMonitor *monitor;
@property (nonatomic, strong) PMIPCServer *ipcServer;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t configTimer;
- (BOOL)shouldAcceptEvent:(PMEvent *)event;
@end

@implementation PMDaemon

- (BOOL)start:(NSError **)error {
    self.queue = dispatch_queue_create("com.procmonrootless.daemon", DISPATCH_QUEUE_SERIAL);
    self.config = [PMConfig loadCurrentConfig];
    [PMConfig ensureRuntimeDirectories];

    self.eventStore = [[PMEventStore alloc] initWithConfig:self.config];
    self.monitor = [[PMMonitor alloc] initWithConfig:self.config];

    __weak typeof(self) weakSelf = self;
    self.monitor.eventHandler = ^(PMEvent *event) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        if (![strongSelf shouldAcceptEvent:event]) {
            return;
        }

        [strongSelf.eventStore appendEvent:event];
        [strongSelf.ipcServer broadcastEvent:event];
    };

    self.ipcServer = [[PMIPCServer alloc] initWithSocketPath:[PMConfig socketPath]];
    self.ipcServer.commandHandler = ^NSDictionary * _Nullable(NSDictionary *request, BOOL *keepAlive, BOOL *subscribeClient) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return [PMIPCProtocol errorResponseForCommand:nil code:@"daemon_unavailable" message:@"Daemon unavailable"];
        }
        return [strongSelf handleRequest:request keepAlive:keepAlive subscribeClient:subscribeClient];
    };

    if (![self.ipcServer start:error]) {
        return NO;
    }

    [self.monitor start];

    [self installConfigTimer];

    PMEvent *startup = [PMEvent eventWithType:@"SERVICE_STARTED" path:@"/var/jb/usr/libexec/procmond"];
    startup.source = @"daemon";
    startup.pid = getpid();
    startup.processName = @"procmond";
    startup.extraMetadata = @{ @"service_name": @"procmond", @"monitor_started": @([self.monitor isRunning]) };
    [self.eventStore appendEvent:startup];
    [self.ipcServer broadcastEvent:startup];

    return YES;
}

- (void)stop {
    PMEvent *shutdown = [PMEvent eventWithType:@"SERVICE_STOPPED" path:@"/var/jb/usr/libexec/procmond"];
    shutdown.source = @"daemon";
    shutdown.pid = getpid();
    shutdown.processName = @"procmond";
    shutdown.extraMetadata = @{ @"service_name": @"procmond" };
    [self.eventStore appendEvent:shutdown];
    [self.ipcServer broadcastEvent:shutdown];

    if (self.configTimer) {
        dispatch_source_cancel(self.configTimer);
        self.configTimer = nil;
    }
    [self.monitor stop];
    [self.ipcServer stop];
}

- (void)installConfigTimer {
    self.configTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.configTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              5 * NSEC_PER_SEC,
                              1 * NSEC_PER_SEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.configTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf reloadConfigAndApply];
    });

    dispatch_resume(self.configTimer);
}

- (void)reloadConfigAndApply {
    PMConfig *newConfig = [PMConfig loadCurrentConfig];
    self.config = newConfig;

    [self.eventStore reloadConfig:newConfig];
    [self.monitor reloadConfig:newConfig];

    // Stability-first: keep monitor running continuously.
    if (![self.monitor isRunning]) {
        [self.monitor start];
    }
}

- (NSDictionary *)handleRequest:(NSDictionary *)request keepAlive:(BOOL *)keepAlive subscribeClient:(BOOL *)subscribeClient {
    NSString *command = [request[@"command"] isKindOfClass:[NSString class]] ? request[@"command"] : nil;
    if (command.length == 0) {
        return [PMIPCProtocol errorResponseForCommand:nil code:@"missing_command" message:@"Request missing command"];
    }

    if ([command isEqualToString:@"status"]) {
        return [self statusResponse];
    }

    if ([command isEqualToString:@"start"]) {
        [self.monitor start];
        return [PMIPCProtocol okResponseForCommand:command payload:@{
            @"monitoring_running": @([self.monitor isRunning]),
            @"always_on": @YES
        }];
    }

    if ([command isEqualToString:@"stop"]) {
        // Keep monitor alive even if stop is requested.
        [self.monitor start];
        return [PMIPCProtocol okResponseForCommand:command payload:@{
            @"monitoring_running": @([self.monitor isRunning]),
            @"always_on": @YES,
            @"note": @"monitor is pinned to running"
        }];
    }

    if ([command isEqualToString:@"recent"]) {
        NSUInteger limit = [self integerValueFromRequest:request key:@"limit" fallback:50 min:1 max:500];
        NSArray *events = [self.eventStore recentEventsWithLimit:limit];
        return [PMIPCProtocol okResponseForCommand:command payload:@{ @"events": events }];
    }

    if ([command isEqualToString:@"tail"]) {
        NSUInteger limit = [self integerValueFromRequest:request key:@"limit" fallback:20 min:1 max:200];
        NSArray *events = [self.eventStore recentEventsWithLimit:limit];
        if (subscribeClient) {
            *subscribeClient = YES;
        }
        return [PMIPCProtocol okResponseForCommand:command payload:@{ @"streaming": @YES, @"recent": events }];
    }

    if ([command isEqualToString:@"subscribe_live"]) {
        if (subscribeClient) {
            *subscribeClient = YES;
        }
        return [PMIPCProtocol okResponseForCommand:command payload:@{ @"streaming": @YES }];
    }

    if ([command isEqualToString:@"clear_logs"]) {
        NSError *clearError = nil;
        BOOL success = [self.eventStore clearLogs:&clearError];
        if (!success) {
            return [PMIPCProtocol errorResponseForCommand:command code:@"clear_failed" message:clearError.localizedDescription ?: @"Unable to clear logs"];
        }

        return [PMIPCProtocol okResponseForCommand:command payload:@{ @"cleared": @YES }];
    }

    if ([command isEqualToString:@"export"]) {
        NSError *exportError = nil;
        NSString *path = [self.eventStore exportLogs:&exportError];
        if (!path) {
            return [PMIPCProtocol errorResponseForCommand:command code:@"export_failed" message:exportError.localizedDescription ?: @"Unable to export logs"];
        }

        return [PMIPCProtocol okResponseForCommand:command payload:@{ @"path": path }];
    }

    if ([command isEqualToString:@"report_hook_event"]) {
        NSDictionary *eventObject = [request[@"event"] isKindOfClass:[NSDictionary class]] ? request[@"event"] : nil;
        if (!eventObject) {
            return [PMIPCProtocol errorResponseForCommand:command code:@"invalid_event" message:@"Missing hook event dictionary"];
        }

        PMEvent *event = [PMEvent eventFromDictionary:eventObject];
        if (!event) {
            return [PMIPCProtocol errorResponseForCommand:command code:@"invalid_event" message:@"Hook event validation failed"];
        }

        [self sanitizeHookEvent:event];
        if (![self shouldAcceptEvent:event]) {
            return [PMIPCProtocol okResponseForCommand:command payload:@{ @"accepted": @NO, @"filtered": @YES }];
        }
        [self.eventStore appendEvent:event];
        [self.ipcServer broadcastEvent:event];

        return [PMIPCProtocol okResponseForCommand:command payload:@{ @"accepted": @YES }];
    }

    if (keepAlive) {
        *keepAlive = NO;
    }
    return [PMIPCProtocol errorResponseForCommand:command code:@"unsupported_command" message:@"Unsupported command"];
}

- (NSDictionary *)statusResponse {
    NSDictionary *monitorStatus = [self.monitor statusSnapshot];

    NSDictionary *payload = @{
        @"daemon_running": @YES,
        @"procmon_enabled": @(self.config.enabled),
        @"hud_enabled": @(self.config.hudEnabled),
        @"plist_parsing": @(self.config.plistParsingEnabled),
        @"monitoring_running": @([self.monitor isRunning]),
        @"paused_by_command": @NO,
        @"always_on": @YES,
        @"watcher_count": monitorStatus[@"watcher_count"] ?: @0,
        @"storm_dropped": monitorStatus[@"storm_dropped"] ?: @0,
        @"recent_count": @([self.eventStore recentCount]),
        @"clients_connected": @([self.ipcServer connectedClientCount]),
        @"live_subscribers": @([self.ipcServer subscribedClientCount]),
        @"socket_path": [PMConfig socketPath],
        @"human_log": [PMConfig humanLogPath],
        @"json_log": [PMConfig jsonLogPath]
    };

    return [PMIPCProtocol okResponseForCommand:@"status" payload:payload];
}

- (NSUInteger)integerValueFromRequest:(NSDictionary *)request key:(NSString *)key fallback:(NSUInteger)fallback min:(NSUInteger)min max:(NSUInteger)max {
    id value = request[key];
    NSUInteger parsed = fallback;
    if ([value respondsToSelector:@selector(unsignedIntegerValue)]) {
        parsed = [value unsignedIntegerValue];
    }

    if (parsed < min) {
        parsed = min;
    }
    if (parsed > max) {
        parsed = max;
    }

    return parsed;
}

- (void)sanitizeHookEvent:(PMEvent *)event {
    event.source = @"hook";

    if (event.timestamp == nil) {
        event.timestamp = [NSDate date];
    }

    if (event.path.length == 0) {
        event.path = @"(null)";
    }

    if (event.path.length > 1024) {
        event.path = [event.path substringToIndex:1024];
    }

    if (event.eventType.length == 0) {
        event.eventType = @"ATTRIB_CHANGED";
    }

    if (event.processName.length == 0) {
        event.processName = @"unknown";
    }

    if (event.pid <= 0) {
        event.pid = -1;
    }

    NSMutableDictionary *metadata = [NSMutableDictionary dictionaryWithDictionary:event.extraMetadata ?: @{}];
    metadata[@"received_at"] = @([[NSDate date] timeIntervalSince1970]);
    event.extraMetadata = [metadata copy];
}

- (BOOL)shouldAcceptEvent:(PMEvent *)event {
    if (!event || event.eventType.length == 0 || event.path.length == 0) {
        return NO;
    }
    return [self.config shouldDisplayEventType:event.eventType path:event.path processName:event.processName];
}

@end
