#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PMTweakClient : NSObject

@property (nonatomic, copy, nullable) void (^eventHandler)(NSDictionary *eventDictionary);
@property (nonatomic, copy, nullable) void (^statusHandler)(BOOL connected, BOOL monitoringRunning, BOOL procmonEnabled);
@property (nonatomic, assign, readonly) BOOL connected;

+ (instancetype)sharedInstance;

- (void)start;
- (void)stop;
- (void)requestStatus;

- (void)sendHookEventType:(NSString *)eventType
                     path:(NSString *)path
                  oldPath:(nullable NSString *)oldPath
                  newPath:(nullable NSString *)newPath
                    extra:(nullable NSDictionary *)extra;

@end

NS_ASSUME_NONNULL_END
