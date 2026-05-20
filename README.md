# AutoTouch

Synthesise iOS touches. Two files, no dependencies past UIKit + IOKit.

Posts touch events indistinguishable from real ones — UIKit gesture recognisers, `UIControl` target/action, and engine input plugins (Unity, Unreal) all accept them.

## Install

Drop `AutoTouch.h` and `AutoTouch.mm` in your project.

## Usage

```objc
#import "AutoTouch.h"

// Tap a point. Returns NO if the app is backgrounded.
[AutoTouch tap:CGPointMake(540, 960)];
```

Drag / hold:

```objc
NSInteger slot = [AutoTouch touchAt:CGPointMake(200, 400)
                              phase:UITouchPhaseBegan
                               slot:0];

[AutoTouch touchAt:CGPointMake(260, 400) phase:UITouchPhaseMoved slot:slot];
[AutoTouch touchAt:CGPointMake(320, 400) phase:UITouchPhaseEnded slot:slot];
```

Began returns a slot id (1..N). Pass it to subsequent Moved/Ended calls.

## Threading

Main thread only. If you're on a background queue:

```objc
dispatch_async(dispatch_get_main_queue(), ^{ [AutoTouch tap:p]; });
```

## Platforms

iOS, iPadOS, and Apple Silicon Mac running iOS binaries (PlayCover etc.). Mac Catalyst and macOS native are not supported — different event pipeline.

## License

MIT.
