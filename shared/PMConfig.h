#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PMConfig : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL hudEnabled;
@property (nonatomic, assign) BOOL liveNotificationsEnabled;
@property (nonatomic, assign) BOOL plistParsingEnabled;
@property (nonatomic, assign) BOOL hudHidden;
@property (nonatomic, copy) NSArray<NSString *> *ignoredPaths;

+ (instancetype)loadCurrentConfig;

+ (NSString *)preferencesDomain;
+ (NSString *)preferencesFilePath;

+ (NSString *)socketPath;
+ (NSString *)runDirectoryPath;
+ (NSString *)humanLogPath;
+ (NSString *)jsonLogPath;
+ (NSString *)exportDirectoryPath;

+ (NSArray<NSString *> *)defaultDiscoveryRoots;
+ (NSArray<NSString *> *)sensitivePaths;

+ (NSUInteger)maxWatcherCount;
+ (NSUInteger)maxRecentEvents;
+ (NSUInteger)maxLiveSubscribers;
+ (NSUInteger)maxIPCLineBytes;

+ (void)ensureRuntimeDirectories;
+ (BOOL)isNoisyPathForDisplay:(NSString *)path;

- (BOOL)shouldIgnorePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
