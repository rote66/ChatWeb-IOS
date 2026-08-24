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
@property(nonatomic, copy, nullable) void (^safeLogoutHandler)(void);

- (BOOL)startWithProfileDirectory:(NSURL *)profileDirectory
                        jitPolicy:(GeminiGeckoJITPolicy)jitPolicy
                 sessionContextId:(nullable NSString *)sessionContextId
                        userAgent:(NSString *)userAgent
                          platform:(NSString *)platform
                        appVersion:(NSString *)appVersion
                              oscpu:(NSString *)oscpu
                useDesktopViewport:(BOOL)useDesktopViewport
                          textZoom:(double)textZoom
                    autoplayDefault:(NSInteger)autoplayDefault
          suspendMediaWhenInactive:(BOOL)suspendMediaWhenInactive
                     cookieBehavior:(NSInteger)cookieBehavior
              useTrackingProtection:(BOOL)useTrackingProtection
               useStrictTrackingList:(BOOL)useStrictTrackingList
                            error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(start(profileDirectory:jitPolicy:sessionContextId:userAgent:platform:appVersion:oscpu:useDesktopViewport:textZoom:autoplayDefault:suspendMediaWhenInactive:cookieBehavior:useTrackingProtection:useStrictTrackingList:));
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
- (BOOL)setUserAgent:(NSString *)userAgent
             platform:(NSString *)platform
           appVersion:(NSString *)appVersion
                 oscpu:(NSString *)oscpu
    useDesktopViewport:(BOOL)useDesktopViewport
    NS_SWIFT_NAME(setUserAgent(_:platform:appVersion:oscpu:useDesktopViewport:));
- (void)setContentConfigurationWithTextZoom:(double)textZoom
                            autoplayDefault:(NSInteger)autoplayDefault
                  suspendMediaWhenInactive:(BOOL)suspendMediaWhenInactive
                             cookieBehavior:(NSInteger)cookieBehavior
                      useTrackingProtection:(BOOL)useTrackingProtection
                       useStrictTrackingList:(BOOL)useStrictTrackingList
                                  completion:(void (^)(BOOL success))completion
    NS_SWIFT_NAME(setContentConfiguration(textZoom:autoplayDefault:suspendMediaWhenInactive:cookieBehavior:useTrackingProtection:useStrictTrackingList:completion:));
- (void)setRequestedLocales:(NSArray<NSString *> *)locales;
- (void)enterBackground;
- (void)enterForeground;
- (void)clearCacheForBaseDomain:(NSString *)baseDomain
                     completion:(void (^)(BOOL success))completion;
- (void)clearCookiesForBaseDomain:(NSString *)baseDomain
                       completion:(void (^)(BOOL success))completion;
- (void)clearPermissionsForBaseDomain:(NSString *)baseDomain
                           completion:(void (^)(BOOL success))completion;
- (void)migrateCookiesToShared:(BOOL)toShared
                    contextIds:(NSArray<NSString *> *)contextIds
                    completion:(void (^)(BOOL success))completion;
- (void)exportCookiesWithCompletion:(void (^)(NSData * _Nullable jsonData))completion;
- (void)importCookiesFromJSONData:(NSData *)jsonData
                       completion:(void (^)(BOOL success))completion;
- (void)setDiskCacheSmartSizeEnabled:(BOOL)enabled
                           completion:(void (^)(BOOL success))completion;
- (void)setDiskCacheCapacityKB:(NSInteger)capacityKB
                     completion:(void (^)(BOOL success))completion;
- (void)close;

@end

NS_ASSUME_NONNULL_END
