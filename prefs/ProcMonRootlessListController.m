#import "ProcMonRootlessListController.h"

#import <notify.h>
#import <spawn.h>
#import <signal.h>
#import <string.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

#import "../shared/PMConfig.h"
#import "../shared/PMIPCProtocol.h"

extern char **environ;

@interface ProcMonRootlessListController ()
@property (nonatomic, copy) NSString *daemonStatusText;
@property (nonatomic, copy) NSString *monitorStatusText;
@property (nonatomic, assign) BOOL usingFallbackSpecifiers;
@end

@implementation ProcMonRootlessListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *loaded = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (loaded.count == 0) {
            _specifiers = [[self fallbackSpecifiers] copy];
            self.usingFallbackSpecifiers = YES;
        } else {
            _specifiers = [loaded copy];
            [self normalizeLoadedSpecifiers];
        }
    }
    return _specifiers;
}

- (void)normalizeLoadedSpecifiers {
    NSString *domain = [PMConfig preferencesDomain];
    for (PSSpecifier *specifier in _specifiers) {
        NSString *key = [specifier propertyForKey:@"key"];
        if (key.length > 0) {
            if (![specifier propertyForKey:@"defaults"]) {
                [specifier setProperty:domain forKey:@"defaults"];
            }
            if (![specifier propertyForKey:@"PostNotification"]) {
                [specifier setProperty:@"com.procmonrootless.settings/ReloadPrefs" forKey:@"PostNotification"];
            }
        }
    }
}

- (NSArray<PSSpecifier *> *)fallbackSpecifiers {
    NSMutableArray<PSSpecifier *> *items = [NSMutableArray array];

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"ProcMon Rootless"];
    [group setProperty:@"Fallback settings view." forKey:@"footerText"];
    [items addObject:group];

    PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"Enable ProcMon"
                                                          target:self
                                                             set:@selector(setPreferenceValue:specifier:)
                                                             get:@selector(readPreferenceValue:)
                                                          detail:nil
                                                            cell:PSSwitchCell
                                                            edit:nil];
    [enabled setProperty:@"Enabled" forKey:@"key"];
    [enabled setProperty:@YES forKey:@"default"];
    [enabled setProperty:[PMConfig preferencesDomain] forKey:@"defaults"];
    [items addObject:enabled];

    PSSpecifier *hud = [PSSpecifier preferenceSpecifierNamed:@"Enable HUD"
                                                      target:self
                                                         set:@selector(setPreferenceValue:specifier:)
                                                         get:@selector(readPreferenceValue:)
                                                      detail:nil
                                                        cell:PSSwitchCell
                                                        edit:nil];
    [hud setProperty:@"HUDEnabled" forKey:@"key"];
    [hud setProperty:@YES forKey:@"default"];
    [hud setProperty:[PMConfig preferencesDomain] forKey:@"defaults"];
    [items addObject:hud];

    PSSpecifier *refresh = [PSSpecifier preferenceSpecifierNamed:@"Refresh Status"
                                                          target:self
                                                             set:nil
                                                             get:nil
                                                          detail:nil
                                                            cell:PSButtonCell
                                                            edit:nil];
    [refresh setProperty:NSStringFromSelector(@selector(refreshStatusTapped:)) forKey:@"action"];
    [items addObject:refresh];

    return [items copy];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatusTapped:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.usingFallbackSpecifiers) {
        self.usingFallbackSpecifiers = NO;
        [self showAlertWithTitle:@"ProcMon Rootless"
                         message:@"Root specifiers failed to load. Fallback view is active. Verify Root.plist format and keys."];
    }
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:[PMConfig preferencesFilePath]];
    NSString *key = [specifier propertyForKey:@"key"];
    id value = prefs[key];

    if ([key isEqualToString:@"IgnoredPathsString"] || [key isEqualToString:@"AllowedEventTypesString"]) {
        NSString *targetKey = [key isEqualToString:@"IgnoredPathsString"] ? @"IgnoredPaths" : @"AllowedEventTypes";
        id rawList = prefs[targetKey];
        if ([rawList isKindOfClass:[NSArray class]]) {
            return [(NSArray *)rawList componentsJoinedByString:@", "];
        }
        if ([rawList isKindOfClass:[NSString class]]) {
            return rawList;
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
        prefs[@"IgnoredPaths"] = [self normalizedListFromValue:value uppercase:NO];
    } else if ([key isEqualToString:@"AllowedEventTypesString"]) {
        prefs[@"AllowedEventTypes"] = [self normalizedListFromValue:value uppercase:YES];
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

- (NSArray<NSString *> *)normalizedListFromValue:(id)value uppercase:(BOOL)uppercase {
    NSString *stringValue = [value isKindOfClass:[NSString class]] ? value : @"";
    NSArray *components = [stringValue componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",\n"]];
    NSMutableOrderedSet<NSString *> *items = [NSMutableOrderedSet orderedSet];
    for (NSString *component in components) {
        NSString *trimmed = [component stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            continue;
        }
        [items addObject:(uppercase ? [trimmed uppercaseString] : trimmed)];
    }
    return items.array ?: @[];
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

- (void)startMonitorTapped:(id)sender {
    (void)sender;

    NSDictionary *response = [self sendCommand:@{ @"command": @"start" } timeout:1.5];
    BOOL ok = [response[@"ok"] respondsToSelector:@selector(boolValue)] ? [response[@"ok"] boolValue] : NO;
    [self showAlertWithTitle:@"ProcMon Rootless" message:(ok ? @"Monitor start sent." : (response[@"error"] ?: @"Unable to start monitor."))];
    [self refreshStatusTapped:nil];
}

- (void)restartDaemonTapped:(id)sender {
    (void)sender;

    NSString *launchctl = [[NSFileManager defaultManager] isExecutableFileAtPath:@"/var/jb/bin/launchctl"] ? @"/var/jb/bin/launchctl" : @"/bin/launchctl";
    NSString *command = [NSString stringWithFormat:@"%@ kickstart -k system/com.procmonrootless.procmond >/dev/null 2>&1 || true", launchctl];
    [self runShellCommand:command];
    [self sendCommand:@{ @"command": @"start" } timeout:1.0];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshStatusTapped:nil];
    });
    [self showAlertWithTitle:@"ProcMon Rootless" message:@"Daemon restart command sent."];
}

- (void)recentEventsTapped:(id)sender {
    (void)sender;

    NSDictionary *response = [self sendCommand:@{ @"command": @"recent", @"limit": @12 } timeout:1.8];
    BOOL ok = [response[@"ok"] respondsToSelector:@selector(boolValue)] ? [response[@"ok"] boolValue] : NO;
    if (!ok) {
        [self showAlertWithTitle:@"ProcMon Rootless" message:(response[@"error"] ?: @"Unable to read recent events.")];
        return;
    }

    NSDictionary *data = [response[@"data"] isKindOfClass:[NSDictionary class]] ? response[@"data"] : @{};
    NSArray *events = [data[@"events"] isKindOfClass:[NSArray class]] ? data[@"events"] : @[];
    if (events.count == 0) {
        [self showAlertWithTitle:@"Recent Events" message:@"No recent events yet."];
        return;
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"HH:mm:ss";

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *event in events) {
        NSString *eventType = [event[@"event_type"] isKindOfClass:[NSString class]] ? event[@"event_type"] : @"EVENT";
        NSString *path = [event[@"path"] isKindOfClass:[NSString class]] ? event[@"path"] : @"(null)";
        NSString *time = @"--:--:--";
        if ([event[@"timestamp"] respondsToSelector:@selector(doubleValue)]) {
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:[event[@"timestamp"] doubleValue]];
            time = [formatter stringFromDate:date];
        }
        if (path.length > 80) {
            path = [NSString stringWithFormat:@"...%@", [path substringFromIndex:path.length - 77]];
        }
        [lines addObject:[NSString stringWithFormat:@"[%@] %@ %@", time, eventType, path]];
    }
    [self showAlertWithTitle:@"Recent Events" message:[lines componentsJoinedByString:@"\n"]];
}

- (void)exportLogsTapped:(id)sender {
    (void)sender;

    NSDictionary *response = [self sendCommand:@{ @"command": @"export" } timeout:2.0];
    BOOL ok = [response[@"ok"] respondsToSelector:@selector(boolValue)] ? [response[@"ok"] boolValue] : NO;
    if (!ok) {
        [self showAlertWithTitle:@"ProcMon Rootless" message:(response[@"error"] ?: @"Unable to export logs.")];
        return;
    }
    NSDictionary *data = [response[@"data"] isKindOfClass:[NSDictionary class]] ? response[@"data"] : @{};
    NSString *path = [data[@"path"] isKindOfClass:[NSString class]] ? data[@"path"] : @"(unknown)";
    [self showAlertWithTitle:@"Export Complete" message:path];
}

- (void)applyBalancedPresetTapped:(id)sender {
    (void)sender;
    [self applyPresetComprehensive:NO];
}

- (void)applyComprehensivePresetTapped:(id)sender {
    (void)sender;
    [self applyPresetComprehensive:YES];
}

- (void)applyPresetComprehensive:(BOOL)comprehensive {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:[PMConfig preferencesFilePath]];
    if (![prefs isKindOfClass:[NSMutableDictionary class]]) {
        prefs = [NSMutableDictionary dictionary];
    }

    prefs[@"IncludeNoisyPaths"] = comprehensive ? @YES : @NO;
    prefs[@"ComprehensiveMode"] = comprehensive ? @YES : @NO;
    prefs[@"PathScopePrefix"] = @"";
    prefs[@"PathContains"] = @"";
    prefs[@"PathRegex"] = @"";
    prefs[@"ProcessContains"] = @"";

    if (!comprehensive) {
        prefs[@"AllowedEventTypes"] = @[
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
    }

    [prefs writeToFile:[PMConfig preferencesFilePath] atomically:YES];
    notify_post("com.procmonrootless.settings/ReloadPrefs");
    [self reloadSpecifiers];
    [self showAlertWithTitle:@"ProcMon Rootless" message:(comprehensive ? @"Comprehensive preset applied." : @"Balanced preset applied.")];
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

- (void)runShellCommand:(NSString *)command {
    if (command.length == 0) {
        return;
    }

    pid_t pid = 0;
    char *argv[] = {
        (char *)"/bin/sh",
        (char *)"-c",
        (char *)[command UTF8String],
        NULL
    };
    posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ);
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
