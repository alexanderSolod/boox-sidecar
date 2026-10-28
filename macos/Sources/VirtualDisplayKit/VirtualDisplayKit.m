#import "VirtualDisplayKit.h"
#import <objc/runtime.h>

// Private API signatures independently narrowed from these public references:
// DeskPad CGVirtualDisplayPrivate.h (MIT, Bastian Andelefski; Khaos Tian header):
// https://github.com/Stengo/DeskPad/blob/main/DeskPad/CGVirtualDisplayPrivate.h
// Chromium's virtual_display_util_mac.mm (BSD, The Chromium Authors):
// https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
// These are undocumented CoreGraphics APIs. Resolve at runtime, check every
// required selector, and fail without modifying physical display configuration.
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, strong) NSString *name;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) unsigned int vendorID, productID, serialNum, serialNumber;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, strong) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation BXVirtualDisplayController {
    CGVirtualDisplay *_display;
    NSString *_lastError;
}

- (BOOL)available {
    NSDictionary<NSString *, NSArray<NSString *> *> *required = @{
        @"CGVirtualDisplayDescriptor": @[@"init", @"setName:", @"setQueue:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:", @"setVendorID:", @"setProductID:", @"setSerialNum:", @"setSerialNumber:", @"setSizeInMillimeters:", @"setRedPrimary:", @"setGreenPrimary:", @"setBluePrimary:", @"setWhitePoint:"],
        @"CGVirtualDisplaySettings": @[@"init", @"setModes:", @"setHiDPI:"],
        @"CGVirtualDisplayMode": @[@"initWithWidth:height:refreshRate:"],
        @"CGVirtualDisplay": @[@"initWithDescriptor:", @"applySettings:", @"displayID"]
    };
    for (NSString *name in required) {
        Class cls = NSClassFromString(name);
        if (!cls) return NO;
        for (NSString *selector in required[name]) {
            if (![cls instancesRespondToSelector:NSSelectorFromString(selector)]) return NO;
        }
    }
    return YES;
}

- (CGDirectDisplayID)displayID { return _display ? _display.displayID : kCGNullDirectDisplay; }
- (NSString *)lastError { return _lastError; }

- (CGDirectDisplayID)createExtendedDisplay {
    NSAssert([NSThread isMainThread], @"Create displays on the main thread");
    if (_display) return _display.displayID;
    _lastError = nil;
    if (!self.available) { _lastError = @"This macOS release does not expose the required virtual display APIs."; return 0; }
    @autoreleasepool {
    @try {
        CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        descriptor.name = @"BOOX Extended Desktop";
        descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        descriptor.maxPixelsWide = 2480;
        descriptor.maxPixelsHigh = 1860;
        descriptor.sizeInMillimeters = CGSizeMake(210, 157.5);
        descriptor.vendorID = 0xB00;
        descriptor.productID = 0x4A1C;
        // A new session identifier avoids macOS restoring a stale mirrored layout.
        unsigned int serial = arc4random_uniform(UINT32_MAX - 1) + 1;
        descriptor.serialNum = serial;
        descriptor.serialNumber = serial;
        descriptor.redPrimary = CGPointMake(0.64, 0.33);
        descriptor.greenPrimary = CGPointMake(0.30, 0.60);
        descriptor.bluePrimary = CGPointMake(0.15, 0.06);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!display) { _lastError = @"macOS refused to create the virtual display."; return 0; }
        CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = 1;
        CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1240 height:930 refreshRate:60.0];
        if (!mode) { _lastError = @"macOS refused the BOOX display mode."; return 0; }
        settings.modes = @[mode];
        if (![display applySettings:settings]) { _lastError = @"macOS could not apply the BOOX display mode."; return 0; }
        CGDirectDisplayID displayID = display.displayID;
        if (!displayID) { _lastError = @"The virtual display has no usable display ID."; return 0; }
        // Retain before yielding to WindowServer. Arrangement must wait until
        // CGGetActiveDisplayList has observed the asynchronously registered ID.
        _display = display;
        return displayID;
    } @catch (NSException *exception) {
        _lastError = [NSString stringWithFormat:@"Virtual display API failed: %@", exception.reason ?: exception.name];
        _display = nil;
        return 0;
    }
    }
}

- (BOOL)arrangeExtendedDisplay {
    NSAssert([NSThread isMainThread], @"Arrange displays on the main thread");
    _lastError = nil;
    CGDirectDisplayID displayID = self.displayID;
    uint32_t count = 0;
    CGDirectDisplayID active[64];
    CGError result = CGGetActiveDisplayList(64, active, &count);
    BOOL registered = NO;
    for (uint32_t i = 0; i < count; i++) if (active[i] == displayID) registered = YES;
    if (result != kCGErrorSuccess || !registered) {
        _lastError = @"The BOOX display is still registering with WindowServer.";
        return NO;
    }
    CGDisplayConfigRef config = NULL;
    NSString *step = @"begin configuration";
    result = CGBeginDisplayConfiguration(&config);
    if (result == kCGErrorSuccess) {
        // Re-applying an already-disabled mirror relationship can be rejected
        // while WindowServer publishes the new display. Change it only if needed.
        if (CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay) {
            step = @"disable mirroring";
            result = CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay);
        }
        if (result == kCGErrorSuccess) {
            step = @"set desktop position";
            CGRect mainBounds = CGDisplayBounds(CGMainDisplayID());
            result = CGConfigureDisplayOrigin(config, displayID, (int32_t)CGRectGetMaxX(mainBounds), (int32_t)CGRectGetMinY(mainBounds));
        }
        if (result == kCGErrorSuccess) {
            step = @"commit session arrangement";
            result = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        } else { CGCancelDisplayConfiguration(config); }
    }
    if (result != kCGErrorSuccess) {
        _lastError = [NSString stringWithFormat:@"Could not %@ for BOOX display %u (CoreGraphics %d).", step, displayID, result];
        return NO;
    }
    if (CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay) {
        _lastError = @"WindowServer is still applying the independent desktop arrangement.";
        return NO;
    }
    return YES;
}

- (void)removeDisplay {
    NSAssert([NSThread isMainThread], @"Remove displays on the main thread");
    _display = nil;
}
@end
