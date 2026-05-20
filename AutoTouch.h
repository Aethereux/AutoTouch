//
//  AutoTouch
//
//  Synthesises iOS touches. Two files, no extra deps.
//
//  Calls into the private IOHIDDigitizer chain — it's what KIF has used since
//  iOS 9 and it's the only thing that gets a touch through both UIKit's
//  gesture recognisers and any engine plugin reading the HID stream directly
//  (Unity in particular).
//
//  Main thread only. If your caller is on a background thread, dispatch_async
//  to the main queue first.
//

#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AutoTouch : NSObject

// Tap-and-release. Returns NO when there's no foreground window (app
// backgrounded, scene not yet active).
+ (BOOL)tap:(CGPoint)point;

// Multi-phase API for drags / holds.
//   Began      → slot is ignored; returns a fresh slot id (1..N).
//   Moved/End  → pass the slot id from Began.
// Returns 0 on failure.
+ (NSInteger)touchAt:(CGPoint)point
               phase:(UITouchPhase)phase
                slot:(NSInteger)slot;

@end

NS_ASSUME_NONNULL_END
