#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
/// Experimental adapter for private CoreGraphics classes, resolved at runtime.
@interface BXVirtualDisplayController : NSObject
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, readonly, nullable) NSString *lastError;
@property(nonatomic, copy, nullable) void (^onConfigurationChanged)(void);
- (CGDirectDisplayID)createExtendedDisplay;
/// Call after the new display appears in CGGetActiveDisplayList.
- (BOOL)arrangeExtendedDisplayAtOrigin:(CGPoint)origin NS_SWIFT_NAME(arrangeExtendedDisplay(at:));
- (void)removeDisplay;
@end
NS_ASSUME_NONNULL_END
