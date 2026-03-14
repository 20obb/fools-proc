#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PMEvent : NSObject

@property (nonatomic, copy) NSString *eventType;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy, nullable) NSString *oldPath;
@property (nonatomic, copy, nullable, getter=pmNewPath, setter=setPMNewPath:) NSString *newPath;
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic, assign) int pid;
@property (nonatomic, copy) NSString *processName;
@property (nonatomic, assign) uid_t uid;
@property (nonatomic, assign) gid_t gid;
@property (nonatomic, assign) mode_t mode;
@property (nonatomic, assign) unsigned long long inode;
@property (nonatomic, assign) unsigned long long size;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *extraMetadata;
@property (nonatomic, copy, nullable) NSString *plistDiffSummary;

+ (instancetype)eventWithType:(NSString *)eventType path:(NSString *)path;
+ (nullable instancetype)eventFromDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)toDictionary;
- (NSString *)humanReadableLine;

@end

NS_ASSUME_NONNULL_END
