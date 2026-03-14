#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PMHUDController : NSObject

+ (instancetype)sharedInstance;
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
