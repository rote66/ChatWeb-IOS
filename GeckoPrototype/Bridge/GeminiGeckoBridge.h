#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GeminiGeckoJITPolicy) {
    GeminiGeckoJITPolicyDisabled = 0,
    GeminiGeckoJITPolicyRequired = 1,
};

typedef NS_ENUM(NSInteger, GeminiGeckoJITState) {
    GeminiGeckoJITStateUnresolved = 0,
    GeminiGeckoJITStateEnabled = 1,
    GeminiGeckoJITStateDegradedNoJIT = 2,
    GeminiGeckoJITStateFailed = 3,
};

@interface GeminiGeckoBridge : NSObject

@property(nonatomic, readonly, nullable) UIView *nativeView;
@property(nonatomic, readonly, nullable) NSURL *currentURL;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, readonly, getter=isStarted) BOOL started;
@property(nonatomic, readonly) GeminiGeckoJITState jitState;
@property(nonatomic, readonly) NSInteger jitReason;
@property(nonatomic, copy, nullable) void (^progressHandler)(double progress);

- (BOOL)startWithProfileDirectory:(NSURL *)profileDirectory
                        jitPolicy:(GeminiGeckoJITPolicy)jitPolicy
                            error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(start(profileDirectory:jitPolicy:));
- (BOOL)loadURL:(NSURL *)url
          error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(load(url:));
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;
- (void)goBack;
- (void)goForward;
- (void)setActive:(BOOL)active;
- (void)setFocused:(BOOL)focused;
- (void)setRequestedLocales:(NSArray<NSString *> *)locales;
- (void)enterBackground;
- (void)enterForeground;
- (void)clearCacheWithCompletion:(void (^)(BOOL success))completion;
- (void)clearCookiesForBaseDomain:(NSString *)baseDomain
                       completion:(void (^)(BOOL success))completion;
- (void)close;

@end

NS_ASSUME_NONNULL_END
