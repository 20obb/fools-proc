#import "PMEvent.h"

@implementation PMEvent

+ (instancetype)eventWithType:(NSString *)eventType path:(NSString *)path {
    PMEvent *event = [[PMEvent alloc] init];
    event.eventType = eventType.length > 0 ? eventType : @"unknown";
    event.path = path.length > 0 ? path : @"(null)";
    event.timestamp = [NSDate date];
    event.pid = -1;
    event.processName = @"unknown";
    event.uid = (uid_t)-1;
    event.gid = (gid_t)-1;
    event.mode = 0;
    event.inode = 0;
    event.size = 0;
    event.source = @"watcher";
    return event;
}

+ (nullable instancetype)eventFromDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *eventType = [dictionary[@"event_type"] isKindOfClass:[NSString class]] ? dictionary[@"event_type"] : nil;
    NSString *path = [dictionary[@"path"] isKindOfClass:[NSString class]] ? dictionary[@"path"] : nil;
    if (eventType.length == 0 || path.length == 0) {
        return nil;
    }

    PMEvent *event = [PMEvent eventWithType:eventType path:path];

    if ([dictionary[@"old_path"] isKindOfClass:[NSString class]]) {
        event.oldPath = dictionary[@"old_path"];
    }
    if ([dictionary[@"new_path"] isKindOfClass:[NSString class]]) {
        event.newPath = dictionary[@"new_path"];
    }
    if ([dictionary[@"timestamp"] isKindOfClass:[NSNumber class]]) {
        event.timestamp = [NSDate dateWithTimeIntervalSince1970:[dictionary[@"timestamp"] doubleValue]];
    }
    if ([dictionary[@"pid"] respondsToSelector:@selector(intValue)]) {
        event.pid = [dictionary[@"pid"] intValue];
    }
    if ([dictionary[@"process_name"] isKindOfClass:[NSString class]]) {
        event.processName = dictionary[@"process_name"];
    }
    if ([dictionary[@"uid"] respondsToSelector:@selector(unsignedIntValue)]) {
        event.uid = (uid_t)[dictionary[@"uid"] unsignedIntValue];
    }
    if ([dictionary[@"gid"] respondsToSelector:@selector(unsignedIntValue)]) {
        event.gid = (gid_t)[dictionary[@"gid"] unsignedIntValue];
    }
    if ([dictionary[@"mode"] respondsToSelector:@selector(unsignedIntValue)]) {
        event.mode = (mode_t)[dictionary[@"mode"] unsignedIntValue];
    }
    if ([dictionary[@"inode"] respondsToSelector:@selector(unsignedLongLongValue)]) {
        event.inode = [dictionary[@"inode"] unsignedLongLongValue];
    }
    if ([dictionary[@"size"] respondsToSelector:@selector(unsignedLongLongValue)]) {
        event.size = [dictionary[@"size"] unsignedLongLongValue];
    }
    if ([dictionary[@"source"] isKindOfClass:[NSString class]]) {
        event.source = dictionary[@"source"];
    }
    if ([dictionary[@"extra_metadata"] isKindOfClass:[NSDictionary class]]) {
        event.extraMetadata = dictionary[@"extra_metadata"];
    }
    if ([dictionary[@"plist_diff_summary"] isKindOfClass:[NSString class]]) {
        event.plistDiffSummary = dictionary[@"plist_diff_summary"];
    }

    return event;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    dictionary[@"event_type"] = self.eventType ?: @"unknown";
    dictionary[@"path"] = self.path ?: @"(null)";
    if (self.oldPath.length > 0) {
        dictionary[@"old_path"] = self.oldPath;
    }
    if (self.newPath.length > 0) {
        dictionary[@"new_path"] = self.newPath;
    }
    dictionary[@"timestamp"] = @([self.timestamp timeIntervalSince1970]);
    dictionary[@"pid"] = @(self.pid);
    dictionary[@"process_name"] = self.processName ?: @"unknown";
    dictionary[@"uid"] = @(self.uid);
    dictionary[@"gid"] = @(self.gid);
    dictionary[@"mode"] = @(self.mode);
    dictionary[@"inode"] = @(self.inode);
    dictionary[@"size"] = @(self.size);
    dictionary[@"source"] = self.source ?: @"unknown";
    if (self.extraMetadata.count > 0) {
        dictionary[@"extra_metadata"] = self.extraMetadata;
    }
    if (self.plistDiffSummary.length > 0) {
        dictionary[@"plist_diff_summary"] = self.plistDiffSummary;
    }
    return dictionary;
}

- (NSString *)humanReadableLine {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone localTimeZone];
    });

    NSString *dateString = [formatter stringFromDate:self.timestamp ?: [NSDate date]];
    NSMutableString *line = [NSMutableString stringWithFormat:@"[%@] [%@] %@ %@ pid=%d proc=%@",
                             dateString,
                             self.source ?: @"unknown",
                             self.eventType ?: @"unknown",
                             self.path ?: @"(null)",
                             self.pid,
                             self.processName ?: @"unknown"];

    if (self.oldPath.length > 0 || self.newPath.length > 0) {
        [line appendFormat:@" old=%@ new=%@", self.oldPath ?: @"-", self.newPath ?: @"-"];
    }

    if (self.plistDiffSummary.length > 0) {
        [line appendFormat:@" plist=%@", self.plistDiffSummary];
    }

    return line;
}

@end
