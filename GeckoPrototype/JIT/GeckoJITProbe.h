#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GeckoJITPreflightResult) {
    GeckoJITPreflightResultUnavailable = 0,
    GeckoJITPreflightResultExecutablePageTransitionAvailable = 1,
};

/// A non-crashing preflight hint. It never executes generated code and cannot
/// by itself prove that SpiderMonkey JIT is usable in a Gecko content process.
GeckoJITPreflightResult GeckoJITPreflight(void);

NS_ASSUME_NONNULL_END
