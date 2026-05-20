#import "AutoTouch.h"
#import <mach/mach_time.h>

// IOHIDEventRef has no public header on iOS. Older SDKs leaked it through
// UIKit; recent ones don't. Forward-declare as an opaque CF type so the
// private setters below compile.
typedef struct __IOHIDEvent *IOHIDEventRef;


// Private UIKit setters. These have been stable since iOS 9 — if Apple
// removes them, every synthetic-touch lib in existence breaks at once.
@interface UITouch ()
- (void)setWindow:(UIWindow *)w;
- (void)setView:(UIView *)v;
- (void)setPhase:(UITouchPhase)p;
- (void)setTimestamp:(NSTimeInterval)t;
- (void)setGestureView:(UIView *)v;
- (void)setIsTap:(BOOL)b;
- (void)_setIsTapToClick:(BOOL)b;
- (void)_setIsFirstTouchForView:(BOOL)b;
- (void)_setLocationInWindow:(CGPoint)p resetPrevious:(BOOL)r;
- (void)_setHidEvent:(IOHIDEventRef)e;
@end

@interface UIEvent ()
- (void)_clearTouches;
- (void)_setHIDEvent:(IOHIDEventRef)e;
- (void)_addTouch:(UITouch *)t forDelayedDelivery:(BOOL)d;
@end

@interface UIApplication ()
- (UIEvent *)_touchesEvent;
@end


// IOKit's digitiser SPI. Field IDs encode (eventType << 16) | offset; the
// digitiser eventType is 11. The one field we actually need is
// IsDisplayIntegrated — without it, gesture recognisers treat the touch as
// coming from a stylus and finger-only handlers skip it.
typedef UInt32   IOOptionBits;
typedef uint32_t IOHIDDigitizerTransducerType;
typedef uint32_t IOHIDEventField;
#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float  IOHIDFloat;
#endif

#define kIOHIDEventFieldDigitizerIsDisplayIntegrated ((11 << 16) | 25)

enum { kIOHIDDigitizerTransducerTypeHand = 3 };
enum {
    kIOHIDDigitizerEventRange    = 0x00000001,
    kIOHIDDigitizerEventTouch    = 0x00000002,
    kIOHIDDigitizerEventPosition = 0x00000004,
};

extern "C" {
IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, AbsoluteTime ts,
    IOHIDDigitizerTransducerType type,
    uint32_t index, uint32_t identity, uint32_t eventMask, uint32_t buttonMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    Boolean range, Boolean touch, IOOptionBits options);

IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(
    CFAllocatorRef allocator, AbsoluteTime ts,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist,
    IOHIDFloat minorRadius, IOHIDFloat majorRadius,
    IOHIDFloat quality, IOHIDFloat density, IOHIDFloat irregularity,
    Boolean range, Boolean touch, IOOptionBits options);

void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child);
void IOHIDEventSetIntegerValue(IOHIDEventRef e, IOHIDEventField f, int v);
}


// 8 slots. The per-flush scan is 8 int compares, so don't grow it casually.
// Taps use one slot, drags hold one across multiple flushes; serious
// multi-touch rarely needs more than four. Ended touches stay in their slot
// for one extra flush so the liftoff actually dispatches, then get recycled.
static constexpr int kSlotCount = 8;
static UITouch * _Nullable g_slots[kSlotCount];


// -keyWindow is deprecated on iOS 13+ and returns nil during scene
// transitions. Prefer the scene API; fall back to -keyWindow when there's
// no foreground scene yet (very early in launch).
static UIWindow * _Nullable ResolveTouchWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.firstObject) return ws.windows.firstObject;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow;
#pragma clang diagnostic pop
}


// Builds one "hand" event with a "finger" child for each touch. Caller
// owns the result and must CFRelease it.
static IOHIDEventRef BuildHIDEvent(NSArray<UITouch *> *touches) {
    uint64_t mt = mach_absolute_time();
    AbsoluteTime ts; ts.hi = (UInt32)(mt >> 32); ts.lo = (UInt32)mt;

    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, ts,
        kIOHIDDigitizerTransducerTypeHand,
        /*index*/ 0, /*identity*/ 0,
        kIOHIDDigitizerEventTouch,
        /*buttonMask*/ 0,
        /*x*/ 0, /*y*/ 0, /*z*/ 0,
        /*tip*/ 0, /*barrel*/ 0,
        /*range*/ false, /*touch*/ true,
        /*options*/ 0);
    IOHIDEventSetIntegerValue(hand, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    uint32_t idx = 1;
    for (UITouch *t in touches) {
        UITouchPhase phase = t.phase;
        // Began/Ended carry Range+Touch (finger landed or lifted). Moved
        // carries Position only.
        uint32_t mask = (phase == UITouchPhaseMoved)
                        ? kIOHIDDigitizerEventPosition
                        : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);
        BOOL touching = (phase != UITouchPhaseEnded && phase != UITouchPhaseCancelled);
        CGPoint p = [t locationInView:t.window];

        IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEventWithQuality(
            kCFAllocatorDefault, ts,
            /*index*/    idx,
            /*identity*/ 2,
            /*mask*/     mask,
            /*x*/        (IOHIDFloat)p.x,
            /*y*/        (IOHIDFloat)p.y,
            /*z*/        0.0,
            /*tip*/      0,
            /*twist*/    0,
            /*minorR*/   5.0,
            /*majorR*/   5.0,
            /*quality*/  1.0,
            /*density*/  1.0,
            /*irreg*/    1.0,
            /*range*/    (IOHIDFloat)touching,
            /*touch*/    (IOHIDFloat)touching,
            /*options*/  0);
        IOHIDEventSetIntegerValue(finger, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        IOHIDEventAppendEvent(hand, finger);
        CFRelease(finger);
        idx++;
    }
    return hand;
}


static NSInteger FindFreeSlot(void) {
    for (int i = 0; i < kSlotCount; i++) {
        UITouch *t = g_slots[i];
        if (!t) return i;
        UITouchPhase p = t.phase;
        if (p == UITouchPhaseEnded || p == UITouchPhaseCancelled) return i;
    }
    return -1;
}


// Same shape as KIF's -initAtPoint:inWindow:. The keyboard-window branch
// PTFakeMetaTouch had is gone — it read an uninitialised stack variable
// and would crash if you ever tapped near a UIRemoteKeyboardWindow.
static UITouch *MakeBeganTouch(CGPoint point, UIWindow *win) {
    UITouch *t = [[UITouch alloc] init];
    [t setWindow:win];                              // first — wipes internal state
    [t _setLocationInWindow:point resetPrevious:YES];
    UIView *hit = [win hitTest:point withEvent:nil];
    [t setView:hit];
    [t setPhase:UITouchPhaseBegan];
    [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
    if (@available(iOS 14.0, *)) {
        [t _setIsTapToClick:NO];
    } else {
        [t _setIsFirstTouchForView:YES];
        [t setIsTap:NO];
    }
    if ([t respondsToSelector:@selector(setGestureView:)]) {
        [t setGestureView:hit];
    }
    // iOS 9+ requires every UITouch to carry a backing HID event before
    // gesture recognisers will accept it. Attach one here; Flush attaches
    // a separate one to the wrapping UIEvent.
    IOHIDEventRef hid = BuildHIDEvent(@[t]);
    [t _setHidEvent:hid];
    CFRelease(hid);
    return t;
}


// Collect everything alive (and the just-changed slot, which might be
// Ended), wrap it in UIKit's recycled _touchesEvent, send. Then transition
// Began/Moved to Stationary so the next flush carries them as continuing
// fingers — not as re-fired Begans.
static void Flush(NSInteger changedSlot) {
    NSMutableArray<UITouch *> *touches = [NSMutableArray arrayWithCapacity:kSlotCount];
    for (int i = 0; i < kSlotCount; i++) {
        UITouch *t = g_slots[i];
        if (!t) continue;
        UITouchPhase p = t.phase;
        BOOL alive = (p != UITouchPhaseEnded && p != UITouchPhaseCancelled);
        if (alive || i == changedSlot) {
            [touches addObject:t];
        }
    }
    if (touches.count == 0) return;

    UIApplication *app = UIApplication.sharedApplication;
    UIEvent *event = [app _touchesEvent];
    if (!event) return;

    [event _clearTouches];
    IOHIDEventRef hid = BuildHIDEvent(touches);
    [event _setHIDEvent:hid];
    CFRelease(hid);
    for (UITouch *t in touches) {
        [event _addTouch:t forDelayedDelivery:NO];
    }

    [app sendEvent:event];

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    for (UITouch *t in touches) {
        UITouchPhase p = t.phase;
        if (p == UITouchPhaseBegan || p == UITouchPhaseMoved) {
            [t setPhase:UITouchPhaseStationary];
            [t setTimestamp:now];
        }
        // Ended/Cancelled stay put. FindFreeSlot will reclaim them next time.
    }
}


@implementation AutoTouch

+ (NSInteger)touchAt:(CGPoint)point
               phase:(UITouchPhase)phase
                slot:(NSInteger)slot {
    UIWindow *win = ResolveTouchWindow();
    if (!win) return 0;

    NSInteger idx = -1;
    if (phase == UITouchPhaseBegan) {
        // Began always allocates fresh — caller's slot is ignored.
        idx = FindFreeSlot();
        if (idx < 0) return 0;
        g_slots[idx] = MakeBeganTouch(point, win);
    } else {
        if (slot < 1 || slot > kSlotCount) return 0;
        idx = slot - 1;
        UITouch *t = g_slots[idx];
        if (!t) return 0;
        [t _setLocationInWindow:point resetPrevious:NO];
        [t setTimestamp:NSProcessInfo.processInfo.systemUptime];
        [t setPhase:phase];
    }

    Flush(idx);
    return idx + 1;
}

+ (BOOL)tap:(CGPoint)point {
    NSInteger s = [self touchAt:point phase:UITouchPhaseBegan slot:0];
    if (s == 0) return NO;
    [self touchAt:point phase:UITouchPhaseEnded slot:s];
    return YES;
}

@end
