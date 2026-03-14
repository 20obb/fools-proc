#import "PMHUDController.h"

#import <UIKit/UIKit.h>
#import <notify.h>

#import "PMHUDView.h"
#import "../PMTweakClient.h"
#import "../../shared/PMConfig.h"

@interface PMHUDController ()
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) PMHUDView *hudView;
@property (nonatomic, strong) NSTimer *statusTimer;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *recentHUDKeys;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL procmonEnabled;
@property (nonatomic, assign) BOOL monitoringRunning;
@property (nonatomic, assign) BOOL daemonConnected;
@property (nonatomic, assign) int notifyToken;
@end

@implementation PMHUDController

+ (instancetype)sharedInstance {
    static PMHUDController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[PMHUDController alloc] initPrivate];
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
        _started = NO;
        _recentHUDKeys = [NSMutableDictionary dictionary];
        _procmonEnabled = YES;
        _monitoringRunning = NO;
        _daemonConnected = NO;
        _notifyToken = 0;
    }
    return self;
}

- (void)start {
    if (self.started) {
        return;
    }

    self.started = YES;
    [self applyConfig:[PMConfig loadCurrentConfig]];
    [self registerPrefsNotification];
    [self configureClientCallbacks];

    [[PMTweakClient sharedInstance] start];

    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:4.0
                                                        target:self
                                                      selector:@selector(requestStatus)
                                                      userInfo:nil
                                                        repeats:YES];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureHUDVisible];
    });
}

- (void)stop {
    if (!self.started) {
        return;
    }

    self.started = NO;
    [self.statusTimer invalidate];
    self.statusTimer = nil;

    [[PMTweakClient sharedInstance] stop];

    if (self.notifyToken != 0) {
        notify_cancel(self.notifyToken);
        self.notifyToken = 0;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.window.hidden = YES;
        self.window = nil;
        self.hudView = nil;
    });
}

- (void)requestStatus {
    PMConfig *config = [PMConfig loadCurrentConfig];
    if (config.enabled && config.hudEnabled && !config.hudHidden) {
        [self ensureHUDVisible];
    }
    [[PMTweakClient sharedInstance] requestStatus];
}

- (void)registerPrefsNotification {
    if (self.notifyToken != 0) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    int token = 0;
    notify_register_dispatch("com.procmonrootless.settings/ReloadPrefs", &token, dispatch_get_main_queue(), ^(int _token) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf applyConfig:[PMConfig loadCurrentConfig]];
    });

    self.notifyToken = token;
}

- (void)configureClientCallbacks {
    __weak typeof(self) weakSelf = self;
    PMTweakClient *client = [PMTweakClient sharedInstance];

    client.eventHandler = ^(NSDictionary *eventDictionary) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf handleLiveEvent:eventDictionary];
    };

    client.statusHandler = ^(BOOL connected, BOOL monitoringRunning, BOOL procmonEnabled) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.daemonConnected = connected;
        strongSelf.monitoringRunning = monitoringRunning;
        strongSelf.procmonEnabled = procmonEnabled;
        [strongSelf refreshHUDStatus];
    };
}

- (void)applyConfig:(PMConfig *)config {
    self.procmonEnabled = config.enabled;

    if (!config.enabled || !config.hudEnabled || config.hudHidden) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.window) {
                self.window.hidden = YES;
            }
        });
        return;
    }

    [self ensureHUDVisible];
    [self refreshHUDStatus];
}

- (void)ensureHUDVisible {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *activeScene = nil;
        if (@available(iOS 13.0, *)) {
            activeScene = [self activeWindowScene];
            if (!activeScene) {
                return;
            }
        }

        if (!self.window) {
            CGRect screenBounds = activeScene ? activeScene.coordinateSpace.bounds : [UIScreen mainScreen].bounds;
            CGFloat width = MIN(360.0, CGRectGetWidth(screenBounds) - 20.0);
            CGFloat originX = 10.0;
            CGFloat originY = MAX(60.0, screenBounds.origin.y + 70.0);

            self.window = [[UIWindow alloc] initWithFrame:CGRectMake(originX, originY, width, [PMHUDView expandedHeight])];
            if (@available(iOS 13.0, *)) {
                self.window.windowScene = activeScene;
            }
            self.window.windowLevel = UIWindowLevelStatusBar + 280.0;
            self.window.backgroundColor = [UIColor clearColor];
            self.window.hidden = NO;

            UIViewController *rootVC = [[UIViewController alloc] init];
            rootVC.view.backgroundColor = [UIColor clearColor];
            self.window.rootViewController = rootVC;

            self.hudView = [[PMHUDView alloc] initWithFrame:rootVC.view.bounds];
            self.hudView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [rootVC.view addSubview:self.hudView];

            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
            [self.hudView addGestureRecognizer:tap];

            UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
            longPress.minimumPressDuration = 0.7;
            [self.hudView addGestureRecognizer:longPress];

            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
            [self.hudView addGestureRecognizer:pan];
        } else if (@available(iOS 13.0, *)) {
            if (self.window.windowScene != activeScene && activeScene) {
                self.window.windowScene = activeScene;
            }
        }

        self.window.hidden = NO;
        self.hudView.frame = self.window.rootViewController.view.bounds;
        [self refreshHUDStatus];
    });
}

- (UIWindowScene *)activeWindowScene API_AVAILABLE(ios(13.0)) {
    NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
    UIWindowScene *fallback = nil;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (!fallback) {
            fallback = windowScene;
        }
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
    }
    return fallback;
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) {
        return;
    }

    BOOL collapsed = !self.hudView.isCollapsed;
    [self resizeWindowForCollapsedState:collapsed animated:YES];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }

    [self persistHUDHidden:YES];
    self.window.hidden = YES;
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    if (!self.window) {
        return;
    }

    CGPoint translation = [gesture translationInView:self.window.superview];
    CGRect frame = self.window.frame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;

    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat maxX = MAX(0.0, CGRectGetWidth(bounds) - CGRectGetWidth(frame));
    CGFloat maxY = MAX(0.0, CGRectGetHeight(bounds) - CGRectGetHeight(frame));
    frame.origin.x = MIN(MAX(0.0, frame.origin.x), maxX);
    frame.origin.y = MIN(MAX(20.0, frame.origin.y), maxY);
    self.window.frame = frame;

    [gesture setTranslation:CGPointZero inView:self.window.superview];
}

- (void)resizeWindowForCollapsedState:(BOOL)collapsed animated:(BOOL)animated {
    [self.hudView setCollapsed:collapsed animated:animated];

    CGFloat targetHeight = collapsed ? [PMHUDView collapsedHeight] : [PMHUDView expandedHeight];
    CGRect targetFrame = self.window.frame;
    targetFrame.size.height = targetHeight;

    void (^applyFrame)(void) = ^{
        self.window.frame = targetFrame;
        self.hudView.frame = self.window.rootViewController.view.bounds;
    };

    if (animated) {
        [UIView animateWithDuration:0.22 animations:applyFrame];
    } else {
        applyFrame();
    }
}

- (void)persistHUDHidden:(BOOL)hidden {
    NSString *prefsPath = [PMConfig preferencesFilePath];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:prefsPath];
    if (![prefs isKindOfClass:[NSMutableDictionary class]]) {
        prefs = [NSMutableDictionary dictionary];
    }
    prefs[@"HUDHidden"] = @(hidden);
    [prefs writeToFile:prefsPath atomically:YES];
    notify_post("com.procmonrootless.settings/ReloadPrefs");
}

- (void)handleLiveEvent:(NSDictionary *)eventDictionary {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.hudView || self.window.hidden) {
            return;
        }

        NSString *eventType = [eventDictionary[@"event_type"] isKindOfClass:[NSString class]] ? eventDictionary[@"event_type"] : @"evt";
        NSString *path = [eventDictionary[@"path"] isKindOfClass:[NSString class]] ? eventDictionary[@"path"] : @"(null)";
        if (![self shouldDisplayEventType:eventType path:path]) {
            return;
        }
        if ([self shouldThrottleHUDLineForEventType:eventType path:path]) {
            return;
        }
        NSString *source = [eventDictionary[@"source"] isKindOfClass:[NSString class]] ? eventDictionary[@"source"] : @"src";
        NSNumber *timestamp = [eventDictionary[@"timestamp"] isKindOfClass:[NSNumber class]] ? eventDictionary[@"timestamp"] : nil;
        NSDate *date = timestamp ? [NSDate dateWithTimeIntervalSince1970:[timestamp doubleValue]] : [NSDate date];

        [self.hudView appendEventWithType:eventType source:source path:path timestamp:date];
    });
}

- (void)refreshHUDStatus {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.hudView) {
            return;
        }

        [self.hudView updateProcMonEnabled:self.procmonEnabled
                                 monitoring:self.monitoringRunning
                                  connected:self.daemonConnected];
    });
}

- (BOOL)shouldDisplayEventType:(NSString *)eventType path:(NSString *)path {
    if (eventType.length == 0 || path.length == 0) {
        return NO;
    }

    NSString *upperType = [eventType uppercaseString];
    NSString *lowerPath = [path lowercaseString];
    if ([upperType containsString:@"OPEN"] || [upperType containsString:@"READ"] || [upperType containsString:@"ACCESS"] || [upperType containsString:@"CLOSE"]) {
        return NO;
    }
    if ([upperType isEqualToString:@"UNKNOWN"]) {
        return NO;
    }

    if ([PMConfig isNoisyPathForDisplay:path]) {
        NSSet<NSString *> *allowOnNoisy = [NSSet setWithArray:@[
            @"CREATE_FILE",
            @"CREATE_DIR",
            @"DELETE",
            @"RENAME_MOVE",
            @"PERMISSION_CHANGED",
            @"PLIST_VALUE_CHANGED",
            @"SERVICE_STARTED",
            @"SERVICE_STOPPED",
            @"PACKAGE_INSTALL",
            @"PACKAGE_REMOVE"
        ]];
        if (![allowOnNoisy containsObject:upperType]) {
            return NO;
        }

        if ([lowerPath hasSuffix:@".tmp"] || [lowerPath hasSuffix:@".temp"] || [lowerPath hasSuffix:@".lock"] ||
            [lowerPath hasSuffix:@".db-wal"] || [lowerPath hasSuffix:@".db-shm"] ||
            [lowerPath hasSuffix:@".sqlite-wal"] || [lowerPath hasSuffix:@".sqlite-shm"] ||
            [lowerPath containsString:@"/tmp/"] || [lowerPath containsString:@"/private/var/tmp/"]) {
            return NO;
        }
    }

    return YES;
}

- (BOOL)shouldThrottleHUDLineForEventType:(NSString *)eventType path:(NSString *)path {
    NSString *key = [NSString stringWithFormat:@"%@|%@", eventType ?: @"", path ?: @""];
    NSDate *now = [NSDate date];
    NSDate *previous = self.recentHUDKeys[key];
    self.recentHUDKeys[key] = now;

    if (self.recentHUDKeys.count > 200) {
        [self.recentHUDKeys removeAllObjects];
    }

    if (previous && [now timeIntervalSinceDate:previous] < 0.6) {
        return YES;
    }
    return NO;
}

@end
