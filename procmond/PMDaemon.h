#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PMDaemon : NSObject

- (BOOL)start:(NSError **)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
