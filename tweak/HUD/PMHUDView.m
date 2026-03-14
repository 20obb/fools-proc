#import "PMHUDView.h"
#import <QuartzCore/QuartzCore.h>

@interface PMHUDView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UILabel *daemonLabel;
@property (nonatomic, strong) UILabel *monitorLabel;
@property (nonatomic, strong) UILabel *procmonLabel;
@property (nonatomic, strong) UITextView *eventsView;
@property (nonatomic, strong) NSMutableArray<NSAttributedString *> *eventLines;
@end

@implementation PMHUDView

+ (CGFloat)collapsedHeight {
    return 82.0;
}

+ (CGFloat)expandedHeight {
    return 228.0;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
        self.layer.cornerRadius = 14.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.12] CGColor];
        self.clipsToBounds = YES;

        _eventLines = [NSMutableArray array];

        _titleLabel = [self makeLabelWithFont:[UIFont boldSystemFontOfSize:13.5] color:[UIColor colorWithWhite:0.96 alpha:1.0]];
        _titleLabel.text = @"ProcMon Rootless";

        _hintLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:10.5] color:[UIColor colorWithWhite:0.72 alpha:1.0]];
        _hintLabel.text = @"Tap collapse | Long-press hide";

        _daemonLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:12] color:[UIColor lightGrayColor]];
        _monitorLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:12] color:[UIColor lightGrayColor]];
        _procmonLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:12] color:[UIColor lightGrayColor]];

        _eventsView = [[UITextView alloc] initWithFrame:CGRectZero];
        _eventsView.backgroundColor = [UIColor clearColor];
        _eventsView.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        _eventsView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        _eventsView.editable = NO;
        _eventsView.selectable = NO;
        _eventsView.scrollEnabled = NO;
        _eventsView.text = @"Waiting for live events...";
        _eventsView.textContainerInset = UIEdgeInsetsMake(3.0, 2.0, 2.0, 2.0);

        [self addSubview:_titleLabel];
        [self addSubview:_hintLabel];
        [self addSubview:_daemonLabel];
        [self addSubview:_monitorLabel];
        [self addSubview:_procmonLabel];
        [self addSubview:_eventsView];

        [self updateProcMonEnabled:YES monitoring:NO connected:NO];
        [self setCollapsed:NO animated:NO];
    }
    return self;
}

- (UILabel *)makeLabelWithFont:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 1;
    return label;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat padding = 10.0;
    CGFloat width = CGRectGetWidth(self.bounds) - (padding * 2.0);

    self.titleLabel.frame = CGRectMake(padding, padding, width, 16.0);
    self.hintLabel.frame = CGRectMake(padding, CGRectGetMaxY(self.titleLabel.frame) + 1.0, width, 12.0);
    self.procmonLabel.frame = CGRectMake(padding, CGRectGetMaxY(self.hintLabel.frame) + 3.0, width, 14.0);
    self.monitorLabel.frame = CGRectMake(padding, CGRectGetMaxY(self.procmonLabel.frame) + 2.0, width, 14.0);
    self.daemonLabel.frame = CGRectMake(padding, CGRectGetMaxY(self.monitorLabel.frame) + 2.0, width, 14.0);

    CGFloat eventsY = CGRectGetMaxY(self.daemonLabel.frame) + 5.0;
    self.eventsView.frame = CGRectMake(padding - 2.0, eventsY, width + 4.0, MAX(0.0, CGRectGetHeight(self.bounds) - eventsY - padding));
}

- (void)updateProcMonEnabled:(BOOL)enabled monitoring:(BOOL)monitoring connected:(BOOL)connected {
    self.procmonLabel.text = [NSString stringWithFormat:@"ProcMon: %@", enabled ? @"ON" : @"OFF"];
    self.monitorLabel.text = connected ? [NSString stringWithFormat:@"Monitor: %@", monitoring ? @"Running" : @"Paused"] : @"Monitor: Unknown";
    self.daemonLabel.text = [NSString stringWithFormat:@"Daemon: %@", connected ? @"Connected" : @"Disconnected"];

    self.procmonLabel.textColor = enabled ? [UIColor colorWithRed:0.37 green:0.95 blue:0.45 alpha:1.0] : [UIColor colorWithRed:0.98 green:0.42 blue:0.42 alpha:1.0];
    self.monitorLabel.textColor = connected ? (monitoring ? [UIColor colorWithRed:0.37 green:0.95 blue:0.45 alpha:1.0] : [UIColor colorWithWhite:0.72 alpha:1.0]) : [UIColor colorWithRed:0.95 green:0.9 blue:0.42 alpha:1.0];
    self.daemonLabel.textColor = connected ? [UIColor colorWithRed:0.37 green:0.95 blue:0.45 alpha:1.0] : [UIColor colorWithRed:0.98 green:0.42 blue:0.42 alpha:1.0];
}

- (void)appendEventWithType:(NSString *)eventType
                      source:(NSString *)source
                        path:(NSString *)path
                   timestamp:(NSDate *)timestamp {
    if (path.length == 0) {
        return;
    }

    NSDate *safeTimestamp = timestamp ?: [NSDate date];
    UIColor *typeColor = [self colorForEventType:eventType];
    NSString *timeString = [self formattedTime:safeTimestamp];
    NSString *displayType = [self displayTypeForEventType:eventType];
    NSString *trimmedPath = path;
    if (trimmedPath.length > 72) {
        trimmedPath = [NSString stringWithFormat:@"...%@", [trimmedPath substringFromIndex:trimmedPath.length - 69]];
    }

    NSString *line = [NSString stringWithFormat:@"[%@] %@ %@ %@", timeString, source ?: @"watcher", displayType ?: @"event", trimmedPath];
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:line attributes:@{
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.9 alpha:1.0],
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular]
    }];

    NSRange typeRange = [line rangeOfString:displayType ?: @""];
    if (typeRange.location != NSNotFound && typeRange.length > 0) {
        [attributed addAttributes:@{
            NSForegroundColorAttributeName: typeColor,
            NSFontAttributeName: [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightSemibold]
        } range:typeRange];
    }

    [self.eventLines addObject:attributed];
    if (self.eventLines.count > 8) {
        [self.eventLines removeObjectAtIndex:0];
    }

    NSMutableAttributedString *rendered = [[NSMutableAttributedString alloc] init];
    for (NSUInteger idx = 0; idx < self.eventLines.count; idx++) {
        [rendered appendAttributedString:self.eventLines[idx]];
        if (idx + 1 < self.eventLines.count) {
            [rendered appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        }
    }
    self.eventsView.attributedText = rendered;
}

- (NSString *)displayTypeForEventType:(NSString *)eventType {
    if (eventType.length == 0) {
        return @"EVENT";
    }

    if ([eventType isEqualToString:@"RENAME_MOVE"]) {
        return @"RENAME/MOVE";
    }

    return eventType;
}

- (void)clearEvents {
    [self.eventLines removeAllObjects];
    self.eventsView.text = @"Waiting for live events...";
}

- (void)setCollapsed:(BOOL)collapsed animated:(BOOL)animated {
    _collapsed = collapsed;

    void (^layoutBlock)(void) = ^{
        self.eventsView.hidden = collapsed;
        self.hintLabel.hidden = collapsed;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    };

    if (animated) {
        [UIView animateWithDuration:0.22 animations:layoutBlock];
    } else {
        layoutBlock();
    }
}

- (UIColor *)colorForEventType:(NSString *)eventType {
    NSString *type = [eventType lowercaseString];
    if ([type containsString:@"create"] || [type containsString:@"mkdir"]) {
        return [UIColor colorWithRed:0.32 green:0.9 blue:0.4 alpha:1.0];
    }
    if ([type containsString:@"delete"] || [type containsString:@"remove"]) {
        return [UIColor colorWithRed:0.95 green:0.38 blue:0.38 alpha:1.0];
    }
    if ([type containsString:@"rename"] || [type containsString:@"move"]) {
        return [UIColor colorWithRed:0.97 green:0.72 blue:0.28 alpha:1.0];
    }
    if ([type containsString:@"attrib"] || [type containsString:@"chmod"] || [type containsString:@"chown"]) {
        return [UIColor colorWithRed:0.95 green:0.9 blue:0.42 alpha:1.0];
    }
    if ([type containsString:@"permission"]) {
        return [UIColor colorWithRed:0.95 green:0.9 blue:0.42 alpha:1.0];
    }
    if ([type containsString:@"plist"]) {
        return [UIColor colorWithRed:0.65 green:0.6 blue:0.96 alpha:1.0];
    }
    if ([type containsString:@"service"] || [type containsString:@"process"]) {
        return [UIColor colorWithRed:0.45 green:0.82 blue:0.96 alpha:1.0];
    }
    if ([type containsString:@"package"]) {
        return [UIColor colorWithRed:0.86 green:0.83 blue:0.34 alpha:1.0];
    }
    return [UIColor colorWithRed:0.58 green:0.86 blue:0.95 alpha:1.0];
}

- (NSString *)formattedTime:(NSDate *)date {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm:ss";
    });
    return [formatter stringFromDate:date];
}

@end
