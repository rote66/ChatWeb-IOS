#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GeminiGeckoMetalView : UIView

@property(nonatomic, readonly) BOOL metalAvailable;

/// Presents one GPU-cleared frame. This verifies host-side CAMetalLayer
/// lifecycle only; it is not evidence that Gecko is using Metal.
- (BOOL)renderProbeFrame:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
