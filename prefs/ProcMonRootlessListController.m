#import "ProcMonRootlessListController.h"

#import <notify.h>
#import <signal.h>
#import <string.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

#import "../shared/PMConfig.h"
#import "../shared/PMIPCProtocol.h"

@interface ProcMonRootlessListController ()
@property (nonatomic, copy) NSString *daemonStatusText;
@property (nonatomic, copy) NSString *monitorStatusText;
@end

@implementation ProcMonRootlessListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatusTapped:nil];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:[PMConfig preferencesFilePath]];
    NSString *key = [specifier propertyForKey:@"key"];
    id value = prefs[key];

    if ([key isEqualToString:@"IgnoredPathsString"]) {
        id rawIgnored = prefs[@"IgnoredPaths"];
        if ([rawIgnored isKindOfClass:[NSArray class]]) {
            return [(NSArray *)rawIgnored componentsJoinedByString:@", "];
        }
        if ([rawIgnored isKindOfClass:[NSString class]]) {
            return rawIgnored;
        }
        return [specifier propertyForKey:@"default"] ?: @"";
    }

    if (!value) {
        value = [specifier propertyForKey:@"default"];
    }
    return value;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:[PMConfig preferencesFilePath]];
    if (![prefs isKindOfClass:[NSMutableDictionary class]]) {
        prefs = [NSMutableDictionary dictionary];
    }

    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"IgnoredPathsString"]) {
        NSString *stringValue = [value isKindOfClass:[NSString class]] ? value : @"";
        NSArray *components = [stringValue componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",\n"]];
        NSMutableArray *paths = [NSMutableArray array];
        for (NSString *component in components) {
            NSString *trimmed = [component stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0) {
                [paths addObject:trimmed];
            }
        }
        prefs[@"IgnoredPaths"] = [paths copy];
    } else if (key.length > 0) {
        if (value) {
            prefs[key] = value;
        } else {
            [prefs removeObjectForKey:key];
        }
    }

    [prefs writeToFile:[PMConfig preferencesFilePath] atomically:YES];
    notify_post("com.procmonrootless.settings/ReloadPrefs");
}

- (id)readDaemonStatus:(PSSpecifier *)specifier {
    (void)specifier;
    return self.daemonStatusText ?: @"Unknown";
}

- (id)readMonitorStatus:(PSSpecifier *)specifier {
    (void)specifier;
    return self.monitorStatusText ?: @"Unknown";
}

- (void)refreshStatusTapped:(id)sender {
    (void)sender;

    NSDictionary *response = [self sendCommand:@{ @"command": @"status" } timeout:1.5];
    BOOL ok = [response[@"ok"] respondsToSelector:@selector(boolValue)] ? [response[@"ok"] boolValue] : NO;

    if (!ok) {
        self.daemonStatusText = @"Disconnected";
        self.monitorStatusText = @"Unknown";
        [self reloadSpecifiers];
        return;
    }

    NSDictionary *data = [response[@"data"] isKindOfClass:[NSDictionary class]] ? response[@"data"] : nil;
    BOOL daemonRunning = [data[@"daemon_running"] respondsToSelector:@selector(boolValue)] ? [data[@"daemon_running"] boolValue] : NO;
    BOOL monitoringRunning = [data[@"monitoring_running"] respondsToSelector:@selector(boolValue)] ? [data[@"monitoring_running"] boolValue] : NO;
    NSUInteger watchers = [data[@"watcher_count"] respondsToSelector:@selector(unsignedIntegerValue)] ? [data[@"watcher_count"] unsignedIntegerValue] : 0;

    self.daemonStatusText = daemonRunning ? @"Connected" : @"Disconnected";
    self.monitorStatusText = [NSString stringWithFormat:@"%@ (%lu watchers)", monitoringRunning ? @"Running" : @"Paused", (unsigned long)watchers];
    [self reloadSpecifiers];
}

- (void)clearLogsTapped:(id)sender {
    (void)sender;

    NSDictionary *response = [self sendCommand:@{ @"command": @"clear_logs" } timeout:1.5];
    BOOL ok = [response[@"ok"] respondsToSelector:@selector(boolValue)] ? [response[@"ok"] boolValue] : NO;

    NSString *message = ok ? @"Logs cleared." : (response[@"error"] ?: @"Unable to clear logs.");
    [self showAlertWithTitle:@"ProcMon Rootless" message:message];
}

- (void)restoreHUDTapped:(id)sender {
    (void)sender;

    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:[PMConfig preferencesFilePath]];
    if (![prefs isKindOfClass:[NSMutableDictionary class]]) {
        prefs = [NSMutableDictionary dictionary];
    }

    prefs[@"HUDHidden"] = @NO;
    [prefs writeToFile:[PMConfig preferencesFilePath] atomically:YES];
    notify_post("com.procmonrootless.settings/ReloadPrefs");

    [self showAlertWithTitle:@"ProcMon Rootless" message:@"HUD restored."];
}

- (NSDictionary *)sendCommand:(NSDictionary *)command timeout:(NSTimeInterval)timeout {
    signal(SIGPIPE, SIG_IGN);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return @{};
    }
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, [PMConfig socketPath].fileSystemRepresentation, sizeof(addr.sun_path));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return @{};
    }

    NSError *jsonError = nil;
    NSData *line = [PMIPCProtocol lineDataFromJSONObject:command error:&jsonError];
    if (!line || jsonError) {
        close(fd);
        return @{};
    }

    ssize_t written = send(fd, line.bytes, line.length, 0);
    if (written < 0 || (NSUInteger)written != line.length) {
        close(fd);
        return @{};
    }

    NSMutableData *buffer = [NSMutableData data];
    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(fd, &readSet);

        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 150000;

        int ready = select(fd + 1, &readSet, NULL, NULL, &tv);
        if (ready <= 0) {
            continue;
        }

        uint8_t temp[2048];
        ssize_t count = read(fd, temp, sizeof(temp));
        if (count <= 0) {
            break;
        }

        [buffer appendBytes:temp length:(NSUInteger)count];
        NSRange newlineRange = [buffer rangeOfData:newline options:0 range:NSMakeRange(0, buffer.length)];
        if (newlineRange.location != NSNotFound) {
            NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, newlineRange.location)];
            NSError *parseError = nil;
            NSDictionary *response = [PMIPCProtocol dictionaryFromLineData:lineData error:&parseError];
            close(fd);
            return response ?: @{};
        }
    }

    close(fd);
    return @{};
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
