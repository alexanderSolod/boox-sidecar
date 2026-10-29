#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
/// Experimental adapter for private CoreGraphics classes, resolved at runtime.
typedef NS_ENUM(NSInteger, BXDisplaySide) {
    BXDisplaySideRight = 0,
    BXDisplaySideLeft = 1
};

@interface BXVirtualDisplayController : NSObject
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, readonly, nullable) NSString *lastError;
- (CGDirectDisplayID)createExtendedDisplay;
/// Call after the new display appears in CGGetActiveDisplayList.
- (BOOL)arrangeExtendedDisplayOnSide:(BXDisplaySide)side;
- (void)removeDisplay;
@end
NS_ASSUME_NONNULL_END
