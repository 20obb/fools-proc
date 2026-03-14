#import <Foundation/Foundation.h>

@class PMConfig;
@class PMEvent;

NS_ASSUME_NONNULL_BEGIN

@interface PMMonitor : NSObject

@property (nonatomic, copy, nullable) void (^eventHandler)(PMEvent *event);

- (instancetype)initWithConfig:(PMConfig *)config;
- (void)reloadConfig:(PMConfig *)config;

- (void)start;
- (void)stop;

- (BOOL)isRunning;
- (NSUInteger)watcherCount;
- (NSDictionary *)statusSnapshot;

@end

NS_ASSUME_NONNULL_END
