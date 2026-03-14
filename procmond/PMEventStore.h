#import <Foundation/Foundation.h>

@class PMConfig;
@class PMEvent;

NS_ASSUME_NONNULL_BEGIN

@interface PMEventStore : NSObject

- (instancetype)initWithConfig:(PMConfig *)config;

- (void)reloadConfig:(PMConfig *)config;
- (void)appendEvent:(PMEvent *)event;
- (NSArray<NSDictionary *> *)recentEventsWithLimit:(NSUInteger)limit;
- (NSUInteger)recentCount;
- (BOOL)clearLogs:(NSError **)error;
- (nullable NSString *)exportLogs:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
