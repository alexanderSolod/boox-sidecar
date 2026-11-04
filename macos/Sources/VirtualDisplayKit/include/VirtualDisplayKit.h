#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
/// Experimental adapter for private CoreGraphics classes, resolved at runtime.
typedef NS_ENUM(NSInteger, BXDisplayOrientation) {
    BXDisplayOrientationLandscape = 0,
    BXDisplayOrientationPortrait = 1
};

@interface BXVirtualDisplayController : NSObject
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, readonly, nullable) NSString *lastError;
@property(nonatomic, copy, nullable) void (^onConfigurationChanged)(void);
- (CGDirectDisplayID)createExtendedDisplayWithOrientation:(BXDisplayOrientation)orientation NS_SWIFT_NAME(createExtendedDisplay(orientation:));
/// Call after the new display appears in CGGetActiveDisplayList.
- (BOOL)arrangeExtendedDisplayAtOrigin:(CGPoint)origin NS_SWIFT_NAME(arrangeExtendedDisplay(at:));
- (void)removeDisplay;
@end
NS_ASSUME_NONNULL_END
