#import "PMIPCServer.h"

#import <errno.h>
#import <fcntl.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

#import "../shared/PMConfig.h"
#import "../shared/PMEvent.h"
#import "../shared/PMIPCProtocol.h"

static const void *kPMIPCServerQueueKey = &kPMIPCServerQueueKey;

@interface PMIPCClient : NSObject
@property (nonatomic, assign) int fd;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, assign) BOOL subscribed;
@property (nonatomic, assign) NSUInteger requestCountInWindow;
@property (nonatomic, assign) NSTimeInterval requestWindowStart;
@end

@implementation PMIPCClient
@end

@interface PMIPCServer ()
@property (nonatomic, copy) NSString *socketPath;
@property (nonatomic, assign) int listenFD;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, PMIPCClient *> *clients;
- (NSUInteger)subscribedClientCountLocked;
- (BOOL)writeData:(NSData *)data toClient:(PMIPCClient *)client;
@end

@implementation PMIPCServer

- (instancetype)initWithSocketPath:(NSString *)socketPath {
    self = [super init];
    if (self) {
        _socketPath = [socketPath copy];
        _listenFD = -1;
        _queue = dispatch_queue_create("com.procmonrootless.ipcserver", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, kPMIPCServerQueueKey, (void *)kPMIPCServerQueueKey, NULL);
        _clients = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *localError = nil;

    dispatch_sync(self.queue, ^{
        if (self.listenFD >= 0) {
            success = YES;
            return;
        }

        [PMConfig ensureRuntimeDirectories];

        unlink(self.socketPath.fileSystemRepresentation);

        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            localError = [NSError errorWithDomain:@"PMIPCServer" code:100 userInfo:@{NSLocalizedDescriptionKey: @"socket() failed"}];
            return;
        }

        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strlcpy(addr.sun_path, self.socketPath.fileSystemRepresentation, sizeof(addr.sun_path));

        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            close(fd);
            localError = [NSError errorWithDomain:@"PMIPCServer" code:101 userInfo:@{NSLocalizedDescriptionKey: @"bind() failed"}];
            return;
        }

        // SpringBoard, Preferences, and procmonctl may run as different users/groups
        // across jailbreak environments; keep socket world-readable/writable and
        // rely on protocol validation/rate-limits for safety.
        chmod(self.socketPath.fileSystemRepresentation, 0666);

        if (listen(fd, 16) < 0) {
            close(fd);
            localError = [NSError errorWithDomain:@"PMIPCServer" code:102 userInfo:@{NSLocalizedDescriptionKey: @"listen() failed"}];
            return;
        }

        if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0) {
            close(fd);
            localError = [NSError errorWithDomain:@"PMIPCServer" code:103 userInfo:@{NSLocalizedDescriptionKey: @"fcntl() failed"}];
            return;
        }

        self.listenFD = fd;
        [self installAcceptSource];
        success = YES;
    });

    if (!success && error) {
        *error = localError;
    }

    return success;
}

- (void)stop {
    dispatch_sync(self.queue, ^{
        if (self.acceptSource) {
            dispatch_source_cancel(self.acceptSource);
            self.acceptSource = nil;
        }

        NSArray<NSNumber *> *clientKeys = self.clients.allKeys;
        for (NSNumber *key in clientKeys) {
            [self closeClient:self.clients[key] reason:@"server_stopping"];
        }
        [self.clients removeAllObjects];

        if (self.listenFD >= 0) {
            close(self.listenFD);
            self.listenFD = -1;
        }

        unlink(self.socketPath.fileSystemRepresentation);
    });
}

- (void)installAcceptSource {
    if (self.acceptSource || self.listenFD < 0) {
        return;
    }

    self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)self.listenFD, 0, self.queue);
    __weak typeof(self) weakSelf = self;

    dispatch_source_set_event_handler(self.acceptSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        while (1) {
            int clientFD = accept(strongSelf.listenFD, NULL, NULL);
            if (clientFD < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    break;
                }
                break;
            }
            [strongSelf registerClientFD:clientFD];
        }
    });

    dispatch_resume(self.acceptSource);
}

- (void)registerClientFD:(int)fd {
    if (fd < 0) {
        return;
    }

    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0) {
        close(fd);
        return;
    }
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

    PMIPCClient *client = [[PMIPCClient alloc] init];
    client.fd = fd;
    client.subscribed = NO;
    client.buffer = [NSMutableData data];
    client.requestCountInWindow = 0;
    client.requestWindowStart = CFAbsoluteTimeGetCurrent();

    __weak typeof(self) weakSelf = self;
    dispatch_source_t readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.queue);
    client.readSource = readSource;

    dispatch_source_set_event_handler(readSource, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf readFromClient:client];
    });

    dispatch_source_set_cancel_handler(readSource, ^{
        close(fd);
    });

    self.clients[@(fd)] = client;
    dispatch_resume(readSource);
}

- (void)readFromClient:(PMIPCClient *)client {
    if (!client) {
        return;
    }

    while (1) {
        uint8_t buffer[4096];
        ssize_t bytesRead = read(client.fd, buffer, sizeof(buffer));
        if (bytesRead > 0) {
            [client.buffer appendBytes:buffer length:(NSUInteger)bytesRead];
            if (client.buffer.length > (64 * 1024)) {
                [self sendResponse:[PMIPCProtocol errorResponseForCommand:nil code:@"buffer_overflow" message:@"Client buffer overflow"] toClient:client];
                [self closeClient:client reason:@"buffer_overflow"];
                return;
            }
            continue;
        }

        if (bytesRead == 0) {
            [self closeClient:client reason:@"read_eof"];
            return;
        }

        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            break;
        }

        [self closeClient:client reason:@"read_error"];
        return;
    }

    [self processLinesForClient:client];
}

- (void)processLinesForClient:(PMIPCClient *)client {
    NSData *newline = [NSData dataWithBytes:"\n" length:1];

    while (1) {
        NSRange range = [client.buffer rangeOfData:newline options:0 range:NSMakeRange(0, client.buffer.length)];
        if (range.location == NSNotFound) {
            break;
        }

        NSData *lineData = [client.buffer subdataWithRange:NSMakeRange(0, range.location)];
        NSRange removeRange = NSMakeRange(0, range.location + 1);
        [client.buffer replaceBytesInRange:removeRange withBytes:NULL length:0];

        if (lineData.length == 0) {
            continue;
        }

        if (lineData.length > [PMConfig maxIPCLineBytes]) {
            [self sendResponse:[PMIPCProtocol errorResponseForCommand:nil code:@"line_too_large" message:@"Line exceeds max length"] toClient:client];
            [self closeClient:client reason:@"line_too_large"];
            return;
        }

        if (![self consumeRateTokenForClient:client]) {
            [self sendResponse:[PMIPCProtocol errorResponseForCommand:nil code:@"rate_limited" message:@"Too many requests"] toClient:client];
            [self closeClient:client reason:@"rate_limited"];
            return;
        }

        NSError *error = nil;
        NSDictionary *request = [PMIPCProtocol dictionaryFromLineData:lineData error:&error];
        if (!request || error) {
            [self sendResponse:[PMIPCProtocol errorResponseForCommand:nil code:@"invalid_json" message:@"Malformed JSON request"] toClient:client];
            continue;
        }

        NSString *command = [request[@"command"] isKindOfClass:[NSString class]] ? request[@"command"] : nil;
        if (command.length == 0) {
            [self sendResponse:[PMIPCProtocol errorResponseForCommand:nil code:@"missing_command" message:@"Request missing command"] toClient:client];
            continue;
        }

        BOOL keepAlive = YES;
        BOOL subscribe = NO;

        NSDictionary *response = nil;
        if (self.commandHandler) {
            response = self.commandHandler(request, &keepAlive, &subscribe);
        }

        if (!response) {
            response = [PMIPCProtocol errorResponseForCommand:command code:@"unsupported" message:@"Unsupported command"];
        }

        if (subscribe) {
            if ([self subscribedClientCountLocked] >= [PMConfig maxLiveSubscribers]) {
                response = [PMIPCProtocol errorResponseForCommand:command code:@"too_many_subscribers" message:@"Live subscriber limit reached"];
                subscribe = NO;
            } else {
                client.subscribed = YES;
            }
        }

        [self sendResponse:response toClient:client];

        if (!keepAlive) {
            [self closeClient:client reason:@"command_closed"];
            return;
        }
    }
}

- (BOOL)consumeRateTokenForClient:(PMIPCClient *)client {
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - client.requestWindowStart > 60.0) {
        client.requestWindowStart = now;
        client.requestCountInWindow = 0;
    }

    client.requestCountInWindow += 1;
    return client.requestCountInWindow <= 240;
}

- (void)broadcastEvent:(PMEvent *)event {
    if (!event) {
        return;
    }

    NSDictionary *message = @{
        @"type": @"event",
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"event": [event toDictionary]
    };

    dispatch_async(self.queue, ^{
        NSArray<PMIPCClient *> *clients = self.clients.allValues;
        for (PMIPCClient *client in clients) {
            if (!client.subscribed) {
                continue;
            }
            [self sendResponse:message toClient:client];
        }
    });
}

- (void)sendResponse:(NSDictionary *)response toClient:(PMIPCClient *)client {
    if (!response || !client) {
        return;
    }

    NSError *error = nil;
    NSData *lineData = [PMIPCProtocol lineDataFromJSONObject:response error:&error];
    if (!lineData || error) {
        return;
    }

    if (lineData.length > [PMConfig maxIPCLineBytes]) {
        [self closeClient:client reason:@"response_too_large"];
        return;
    }

    if (![self writeData:lineData toClient:client]) {
        [self closeClient:client reason:@"write_failed"];
    }
}

- (void)closeClient:(PMIPCClient *)client reason:(NSString *)reason {
    if (!client) {
        return;
    }

    NSNumber *key = @(client.fd);
    PMIPCClient *stored = self.clients[key];
    if (!stored) {
        return;
    }

    [self.clients removeObjectForKey:key];

    if (client.readSource) {
        dispatch_source_cancel(client.readSource);
        client.readSource = nil;
    } else if (client.fd >= 0) {
        close(client.fd);
    }

    (void)reason;
}

- (NSUInteger)connectedClientCount {
    if (dispatch_get_specific(kPMIPCServerQueueKey) == kPMIPCServerQueueKey) {
        return self.clients.count;
    }

    __block NSUInteger count = 0;
    dispatch_sync(self.queue, ^{
        count = self.clients.count;
    });
    return count;
}

- (NSUInteger)subscribedClientCount {
    if (dispatch_get_specific(kPMIPCServerQueueKey) == kPMIPCServerQueueKey) {
        return [self subscribedClientCountLocked];
    }

    __block NSUInteger count = 0;
    dispatch_sync(self.queue, ^{
        count = [self subscribedClientCountLocked];
    });
    return count;
}

- (NSUInteger)subscribedClientCountLocked {
    NSUInteger count = 0;
    for (PMIPCClient *client in self.clients.allValues) {
        if (client.subscribed) {
            count += 1;
        }
    }
    return count;
}

- (BOOL)writeData:(NSData *)data toClient:(PMIPCClient *)client {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger remaining = data.length;
    NSUInteger offset = 0;
    int eagainCount = 0;

    while (remaining > 0) {
        ssize_t sent = send(client.fd, bytes + offset, remaining, 0);
        if (sent > 0) {
            offset += (NSUInteger)sent;
            remaining -= (NSUInteger)sent;
            continue;
        }

        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
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

@end
