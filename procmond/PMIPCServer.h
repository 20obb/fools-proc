#import <Foundation/Foundation.h>

@class PMEvent;

NS_ASSUME_NONNULL_BEGIN

typedef NSDictionary * _Nullable (^PMIPCCommandHandler)(NSDictionary *request, BOOL *keepAlive, BOOL *subscribeClient);

@interface PMIPCServer : NSObject

@property (nonatomic, copy, nullable) PMIPCCommandHandler commandHandler;

- (instancetype)initWithSocketPath:(NSString *)socketPath;
- (BOOL)start:(NSError **)error;
- (void)stop;

- (void)broadcastEvent:(PMEvent *)event;
- (NSUInteger)connectedClientCount;
- (NSUInteger)subscribedClientCount;

@end

NS_ASSUME_NONNULL_END
