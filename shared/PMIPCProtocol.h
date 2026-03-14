#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSUInteger const PMIPCProtocolDefaultMaxLineBytes;

@interface PMIPCProtocol : NSObject

+ (nullable NSData *)lineDataFromJSONObject:(id)object error:(NSError **)error;
+ (nullable NSDictionary *)dictionaryFromLineData:(NSData *)lineData error:(NSError **)error;

+ (NSDictionary *)okResponseForCommand:(NSString *)command payload:(nullable NSDictionary *)payload;
+ (NSDictionary *)errorResponseForCommand:(nullable NSString *)command code:(NSString *)code message:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
