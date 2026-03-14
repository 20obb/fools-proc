#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PMHUDView : UIView

@property (nonatomic, assign, getter=isCollapsed) BOOL collapsed;

+ (CGFloat)collapsedHeight;
+ (CGFloat)expandedHeight;

- (void)updateProcMonEnabled:(BOOL)enabled monitoring:(BOOL)monitoring connected:(BOOL)connected;
- (void)appendEventWithType:(NSString *)eventType
                      source:(NSString *)source
                        path:(NSString *)path
                   timestamp:(NSDate *)timestamp
                  processName:(nullable NSString *)processName
                          pid:(int)pid;
- (void)clearEvents;
- (void)setCollapsed:(BOOL)collapsed animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
