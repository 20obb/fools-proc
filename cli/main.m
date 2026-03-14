#import <Foundation/Foundation.h>
#import <signal.h>
#import <string.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

#import "../shared/PMConfig.h"
#import "../shared/PMIPCProtocol.h"

static volatile sig_atomic_t gShouldRun = 1;

static void handleSignal(int signo) {
    (void)signo;
    gShouldRun = 0;
}

static void printUsage(void) {
    printf("Usage: procmonctl <command> [args]\n");
    printf("Commands:\n");
    printf("  status\n");
    printf("  start\n");
    printf("  stop\n");
    printf("  recent [limit]\n");
    printf("  tail [limit]\n");
    printf("  clear-logs\n");
    printf("  export\n");
}

static int connectSocket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, [PMConfig socketPath].fileSystemRepresentation, sizeof(addr.sun_path));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }

    return fd;
}

static NSDictionary *readSingleResponse(int fd, NSTimeInterval timeout) {
    NSMutableData *buffer = [NSMutableData data];
    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(fd, &readSet);

        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 200000;

        int ready = select(fd + 1, &readSet, NULL, NULL, &tv);
        if (ready <= 0) {
            continue;
        }

        uint8_t temp[4096];
        ssize_t count = read(fd, temp, sizeof(temp));
        if (count <= 0) {
            return nil;
        }

        [buffer appendBytes:temp length:(NSUInteger)count];
        NSRange range = [buffer rangeOfData:newline options:0 range:NSMakeRange(0, buffer.length)];
        if (range.location != NSNotFound) {
            NSData *line = [buffer subdataWithRange:NSMakeRange(0, range.location)];
            return [PMIPCProtocol dictionaryFromLineData:line error:nil];
        }
    }

    return nil;
}

static BOOL sendCommand(int fd, NSDictionary *command) {
    NSData *line = [PMIPCProtocol lineDataFromJSONObject:command error:nil];
    if (!line) {
        return NO;
    }

    ssize_t written = send(fd, line.bytes, line.length, 0);
    return written >= 0 && (NSUInteger)written == line.length;
}

static NSString *eventSummary(NSDictionary *event) {
    NSString *source = [event[@"source"] isKindOfClass:[NSString class]] ? event[@"source"] : @"src";
    NSString *type = [event[@"event_type"] isKindOfClass:[NSString class]] ? event[@"event_type"] : @"evt";
    NSString *path = [event[@"path"] isKindOfClass:[NSString class]] ? event[@"path"] : @"(null)";
    int pid = [event[@"pid"] respondsToSelector:@selector(intValue)] ? [event[@"pid"] intValue] : -1;
    NSString *proc = [event[@"process_name"] isKindOfClass:[NSString class]] ? event[@"process_name"] : @"unknown";
    NSString *timeString = @"--:--:--";
    if ([event[@"timestamp"] respondsToSelector:@selector(doubleValue)]) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:[event[@"timestamp"] doubleValue]];
        static NSDateFormatter *fmt = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            fmt = [[NSDateFormatter alloc] init];
            fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            fmt.dateFormat = @"HH:mm:ss";
        });
        timeString = [fmt stringFromDate:date] ?: timeString;
    }

    NSString *line = [NSString stringWithFormat:@"[%@] [%@] %@ %@ proc=%@ pid=%d", timeString, source, type, path, proc, pid];
    NSString *plistDiff = [event[@"plist_diff_summary"] isKindOfClass:[NSString class]] ? event[@"plist_diff_summary"] : nil;
    if (plistDiff.length > 0) {
        line = [line stringByAppendingFormat:@" plist=%@", plistDiff];
    }
    return line;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);

        if (argc < 2) {
            printUsage();
            return 1;
        }

        NSString *commandName = [NSString stringWithUTF8String:argv[1]];
        NSMutableDictionary *request = [NSMutableDictionary dictionary];

        if ([commandName isEqualToString:@"status"]) {
            request[@"command"] = @"status";
        } else if ([commandName isEqualToString:@"start"]) {
            request[@"command"] = @"start";
        } else if ([commandName isEqualToString:@"stop"]) {
            request[@"command"] = @"stop";
        } else if ([commandName isEqualToString:@"recent"]) {
            request[@"command"] = @"recent";
            if (argc >= 3) {
                request[@"limit"] = @((NSUInteger)MAX(1, atoi(argv[2])));
            }
        } else if ([commandName isEqualToString:@"tail"]) {
            request[@"command"] = @"tail";
            if (argc >= 3) {
                request[@"limit"] = @((NSUInteger)MAX(1, atoi(argv[2])));
            }
        } else if ([commandName isEqualToString:@"clear-logs"]) {
            request[@"command"] = @"clear_logs";
        } else if ([commandName isEqualToString:@"export"]) {
            request[@"command"] = @"export";
        } else {
            printUsage();
            return 1;
        }

        int fd = connectSocket();
        if (fd < 0) {
            fprintf(stderr, "Unable to connect to %s\n", [PMConfig socketPath].UTF8String);
            return 2;
        }

        if (!sendCommand(fd, request)) {
            fprintf(stderr, "Failed to send command\n");
            close(fd);
            return 2;
        }

        if ([commandName isEqualToString:@"tail"]) {
            signal(SIGINT, handleSignal);
            signal(SIGTERM, handleSignal);

            NSMutableData *buffer = [NSMutableData data];
            NSData *newline = [NSData dataWithBytes:"\n" length:1];

            while (gShouldRun) {
                fd_set readSet;
                FD_ZERO(&readSet);
                FD_SET(fd, &readSet);

                struct timeval tv;
                tv.tv_sec = 1;
                tv.tv_usec = 0;

                int ready = select(fd + 1, &readSet, NULL, NULL, &tv);
                if (ready <= 0) {
                    continue;
                }

                uint8_t temp[4096];
                ssize_t count = read(fd, temp, sizeof(temp));
                if (count <= 0) {
                    break;
                }

                [buffer appendBytes:temp length:(NSUInteger)count];

                while (1) {
                    NSRange range = [buffer rangeOfData:newline options:0 range:NSMakeRange(0, buffer.length)];
                    if (range.location == NSNotFound) {
                        break;
                    }

                    NSData *line = [buffer subdataWithRange:NSMakeRange(0, range.location)];
                    [buffer replaceBytesInRange:NSMakeRange(0, range.location + 1) withBytes:NULL length:0];

                    NSDictionary *message = [PMIPCProtocol dictionaryFromLineData:line error:nil];
                    if (![message isKindOfClass:[NSDictionary class]]) {
                        continue;
                    }

                    NSString *type = [message[@"type"] isKindOfClass:[NSString class]] ? message[@"type"] : nil;
                    if ([type isEqualToString:@"response"]) {
                        BOOL ok = [message[@"ok"] respondsToSelector:@selector(boolValue)] ? [message[@"ok"] boolValue] : NO;
                        if (!ok) {
                            NSString *error = [message[@"error"] isKindOfClass:[NSString class]] ? message[@"error"] : @"Unknown error";
                            printf("error: %s\n", error.UTF8String);
                            continue;
                        }

                        NSDictionary *data = [message[@"data"] isKindOfClass:[NSDictionary class]] ? message[@"data"] : nil;
                        NSArray *recent = [data[@"recent"] isKindOfClass:[NSArray class]] ? data[@"recent"] : nil;
                        for (NSDictionary *event in recent) {
                            printf("%s\n", eventSummary(event).UTF8String);
                        }
                    } else if ([type isEqualToString:@"event"]) {
                        NSDictionary *event = [message[@"event"] isKindOfClass:[NSDictionary class]] ? message[@"event"] : nil;
                        if (event) {
                            printf("%s\n", eventSummary(event).UTF8String);
                        }
                    }
                }
            }

            close(fd);
            return 0;
        }

        NSDictionary *response = readSingleResponse(fd, 2.0);
        close(fd);

        if (![response isKindOfClass:[NSDictionary class]]) {
            fprintf(stderr, "No response from daemon\n");
            return 3;
        }

        BOOL ok = [response[@"ok"] respondsToSelector:@selector(boolValue)] ? [response[@"ok"] boolValue] : NO;
        if (!ok) {
            NSString *error = [response[@"error"] isKindOfClass:[NSString class]] ? response[@"error"] : @"Unknown error";
            fprintf(stderr, "error: %s\n", error.UTF8String);
            return 4;
        }

        NSString *command = [response[@"command"] isKindOfClass:[NSString class]] ? response[@"command"] : @"";
        NSDictionary *data = [response[@"data"] isKindOfClass:[NSDictionary class]] ? response[@"data"] : @{};

        if ([command isEqualToString:@"recent"]) {
            NSArray *events = [data[@"events"] isKindOfClass:[NSArray class]] ? data[@"events"] : @[];
            for (NSDictionary *event in events) {
                printf("%s\n", eventSummary(event).UTF8String);
            }
            return 0;
        }

        NSData *pretty = [NSJSONSerialization dataWithJSONObject:data options:NSJSONWritingPrettyPrinted error:nil];
        if (pretty.length > 0) {
            NSString *text = [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding];
            printf("%s\n", text.UTF8String);
        } else {
            printf("ok\n");
        }

        return 0;
    }
}
