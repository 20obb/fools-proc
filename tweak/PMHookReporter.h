#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PMHookReporter : NSObject

+ (void)reportEventType:(NSString *)eventType
                   path:(NSString *)path
                oldPath:(nullable NSString *)oldPath
                newPath:(nullable NSString *)newPath
                  extra:(nullable NSDictionary *)extra;

@end

NS_ASSUME_NONNULL_END
