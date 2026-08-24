#import "GeminiGeckoBridge.h"
#import "GeminiGeckoCAPI.h"

static NSString * const GeminiGeckoBridgeErrorDomain = @"GeminiGeckoBridge";

@interface GeminiGeckoBridge () {
    GGGeckoRuntime *_runtime;
    GGGeckoSession *_session;
    __weak UIView *_nativeView;
    NSURL *_currentURL;
    NSString *_sessionContextId;
}
@property(nonatomic, readwrite, getter=isStarted) BOOL started;
@property(nonatomic, readwrite) GeminiGeckoJITState jitState;
@property(nonatomic, readwrite) NSInteger jitReason;
- (void)handleCommittedURLString:(NSString *)value;
- (void)handleProgress:(double)progress;
- (void)handleContentProcessTermination;
- (void)handleJITState:(GeminiGeckoJITState)state reason:(NSInteger)reason;
@end

@interface GGJSONCompletionBox : NSObject
@property(nonatomic, copy) void (^completion)(NSData * _Nullable jsonData);
@end

@implementation GGJSONCompletionBox
@end


static void GGJSONDidFinish(void *context,
                            bool success,
                            const char *jsonUTF8) {
    GGJSONCompletionBox *box = (__bridge_transfer GGJSONCompletionBox *)context;
    NSData *data = nil;
    if (success && jsonUTF8) {
        data = [[NSString stringWithUTF8String:jsonUTF8]
            dataUsingEncoding:NSUTF8StringEncoding];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (box.completion) {
            box.completion(data);
        }
    });
}

static NSError *GGMakeError(GGGeckoResult result, NSString *operation) {
    return [NSError errorWithDomain:GeminiGeckoBridgeErrorDomain
                               code:(NSInteger)result
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ failed (%ld)", operation, (long)result]
    }];
}

static void GGDidCommitURL(void *context, const char *urlUTF8) {
    if (!context || !urlUTF8) { return; }
    GeminiGeckoBridge *bridge = (__bridge GeminiGeckoBridge *)context;
    NSString *value = [NSString stringWithUTF8String:urlUTF8];
    if (value.length == 0) { return; }
    [bridge handleCommittedURLString:value];
}

static void GGDidChangeTitle(void *context, const char *titleUTF8) {
    (void)context;
    (void)titleUTF8;
}

static void GGDidChangeProgress(void *context, double progress) {
    if (!context) { return; }
    GeminiGeckoBridge *bridge = (__bridge GeminiGeckoBridge *)context;
    [bridge handleProgress:progress];
}

static void GGDidTerminateContentProcess(void *context, int32_t reason) {
    (void)reason;
    if (!context) { return; }
    GeminiGeckoBridge *bridge = (__bridge GeminiGeckoBridge *)context;
    [bridge handleContentProcessTermination];
}

static void GGDidChangeJITState(void *context,
                                GGGeckoJITState state,
                                int32_t reason) {
    if (!context) { return; }
    GeminiGeckoBridge *bridge = (__bridge GeminiGeckoBridge *)context;
    [bridge handleJITState:(GeminiGeckoJITState)state reason:(NSInteger)reason];
}

static void GGDidRequestSafeLogout(void *context) {
    if (!context) { return; }
    GeminiGeckoBridge *bridge = (__bridge GeminiGeckoBridge *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (bridge.safeLogoutHandler) {
            bridge.safeLogoutHandler();
        }
    });
}

@interface GGClearDataCompletionBox : NSObject
@property(nonatomic, copy) void (^completion)(BOOL success);
@end


@implementation GGClearDataCompletionBox
@end


static void GGClearDataDidFinish(void *context, bool success) {
    GGClearDataCompletionBox *box = (__bridge_transfer GGClearDataCompletionBox *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (box.completion) {
            box.completion(success);
        }
    });
}

@implementation GeminiGeckoBridge

- (void)handleCommittedURLString:(NSString *)value {
    _currentURL = [NSURL URLWithString:value];
}

- (void)handleProgress:(double)progress {
    if (self.progressHandler) {
        self.progressHandler(MAX(0.0, MIN(1.0, progress)));
    }
}

- (void)exportCookiesWithCompletion:(void (^)(NSData * _Nullable))completion {
    if (!_runtime || !completion) {
        if (completion) { completion(nil); }
        return;
    }
    GGJSONCompletionBox *box = [[GGJSONCompletionBox alloc] init];
    box.completion = completion;
    void *context = (__bridge_retained void *)box;
    GGGeckoResult result = GGGeckoRuntimeExportCookies(
        _runtime, context, GGJSONDidFinish);
    if (result != GGGeckoResultOK) {
        CFBridgingRelease(context);
        completion(nil);
    }
}

- (void)importCookiesFromJSONData:(NSData *)jsonData
                       completion:(void (^)(BOOL))completion {
    if (!_runtime || !jsonData.length) {
        if (completion) { completion(NO); }
        return;
    }
    NSString *json = [[NSString alloc] initWithData:jsonData
                                           encoding:NSUTF8StringEncoding];
    if (!json.length) {
        if (completion) { completion(NO); }
        return;
    }
    GGClearDataCompletionBox *box = [[GGClearDataCompletionBox alloc] init];
    box.completion = completion;
    void *context = (__bridge_retained void *)box;
    GGGeckoResult result = GGGeckoRuntimeImportCookies(
        _runtime, json.UTF8String, context, GGClearDataDidFinish);
    if (result != GGGeckoResultOK) {
        CFBridgingRelease(context);
        if (completion) { completion(NO); }
    }
}

- (void)handleContentProcessTermination {
    _nativeView = nil;
}

- (void)handleJITState:(GeminiGeckoJITState)state reason:(NSInteger)reason {
    self.jitState = state;
    self.jitReason = reason;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _runtime = nullptr;
        _session = nullptr;
        _started = NO;
        _jitState = GeminiGeckoJITStateUnresolved;
        _jitReason = 0;
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (UIView *)nativeView { return _nativeView; }
- (NSURL *)currentURL { return _currentURL; }
- (BOOL)canGoBack { return _session ? GGGeckoSessionCanGoBack(_session) : NO; }
- (BOOL)canGoForward { return _session ? GGGeckoSessionCanGoForward(_session) : NO; }

- (BOOL)startWithProfileDirectory:(NSURL *)profileDirectory
                        jitPolicy:(GeminiGeckoJITPolicy)jitPolicy
                 sessionContextId:(NSString *)sessionContextId
                        userAgent:(NSString *)userAgent
                          platform:(NSString *)platform
                        appVersion:(NSString *)appVersion
                              oscpu:(NSString *)oscpu
                useDesktopViewport:(BOOL)useDesktopViewport
                            error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Gecko bridge must start on the main thread");
    if (_started) { return YES; }
    if (!profileDirectory.isFileURL || !userAgent.length || !platform.length ||
        !appVersion.length || !oscpu.length) {
        if (error) { *error = GGMakeError(GGGeckoResultInvalidArgument, @"profile path"); }
        return NO;
    }

    _sessionContextId = [sessionContextId copy];

    GGGeckoRuntimeOptions options = {};
    options.profile_path_utf8 = profileDirectory.path.UTF8String;
    options.jit_mode = jitPolicy == GeminiGeckoJITPolicyRequired
        ? GGGeckoJITModeRequired
        : GGGeckoJITModeDisabled;

    GGGeckoResult result = GGGeckoRuntimeCreate(&options, &_runtime);
    if (result != GGGeckoResultOK || !_runtime) {
        if (error) { *error = GGMakeError(result, @"runtime creation"); }
        _runtime = nullptr;
        return NO;
    }

    GGGeckoSessionCallbacks callbacks = {};
    callbacks.context = (__bridge void *)self;
    callbacks.did_commit_url = GGDidCommitURL;
    callbacks.did_change_title = GGDidChangeTitle;
    callbacks.did_change_progress = GGDidChangeProgress;
    callbacks.did_terminate_content_process = GGDidTerminateContentProcess;
    callbacks.did_change_jit_state = GGDidChangeJITState;
    callbacks.did_request_safe_logout = GGDidRequestSafeLogout;

    GGGeckoUserAgentSettings userAgentSettings = {};
    userAgentSettings.user_agent_utf8 = userAgent.UTF8String;
    userAgentSettings.platform_utf8 = platform.UTF8String;
    userAgentSettings.app_version_utf8 = appVersion.UTF8String;
    userAgentSettings.oscpu_utf8 = oscpu.UTF8String;
    userAgentSettings.use_desktop_viewport = useDesktopViewport;
    result = GGGeckoSessionCreate(
        _runtime,
        &callbacks,
        _sessionContextId.length ? _sessionContextId.UTF8String : nullptr,
        &userAgentSettings,
        &_session);
    if (result != GGGeckoResultOK || !_session) {
        GGGeckoRuntimeDestroy(_runtime);
        _runtime = nullptr;
        if (error) { *error = GGMakeError(result, @"session creation"); }
        return NO;
    }

    void *native = GGGeckoSessionGetNativeView(_session);
    _nativeView = native ? (__bridge UIView *)native : nil;
    if (!_nativeView) {
        [self close];
        if (error) { *error = GGMakeError(GGGeckoResultSessionFailure, @"native view creation"); }
        return NO;
    }

    _started = YES;
    return YES;
}

- (BOOL)loadURL:(NSURL *)url error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Gecko navigation must run on the main thread");
    if (!_session || !url.absoluteString.length) {
        if (error) { *error = GGMakeError(GGGeckoResultInvalidArgument, @"load URL"); }
        return NO;
    }
    GGGeckoResult result = GGGeckoSessionLoadURL(_session, url.absoluteString.UTF8String);
    if (result != GGGeckoResultOK) {
        if (error) { *error = GGMakeError(result, @"load URL"); }
        return NO;
    }
    return YES;
}

- (void)reload { if (_session) GGGeckoSessionReload(_session); }
- (void)reloadIgnoringCache { if (_session) GGGeckoSessionReloadIgnoringCache(_session); }
- (void)stopLoading { if (_session) GGGeckoSessionStop(_session); }
- (void)goBack { if (_session) GGGeckoSessionGoBack(_session); }
- (void)goForward { if (_session) GGGeckoSessionGoForward(_session); }
- (void)setActive:(BOOL)active { if (_session) GGGeckoSessionSetActive(_session, active); }
- (void)setFocused:(BOOL)focused { if (_session) GGGeckoSessionSetFocused(_session, focused); }
- (BOOL)setUserAgent:(NSString *)userAgent
             platform:(NSString *)platform
           appVersion:(NSString *)appVersion
                 oscpu:(NSString *)oscpu
    useDesktopViewport:(BOOL)useDesktopViewport {
    if (!_session || !userAgent.length || !platform.length ||
        !appVersion.length || !oscpu.length) {
        return NO;
    }
    GGGeckoUserAgentSettings settings = {};
    settings.user_agent_utf8 = userAgent.UTF8String;
    settings.platform_utf8 = platform.UTF8String;
    settings.app_version_utf8 = appVersion.UTF8String;
    settings.oscpu_utf8 = oscpu.UTF8String;
    settings.use_desktop_viewport = useDesktopViewport;
    return GGGeckoSessionSetUserAgentSettings(_session, &settings) == GGGeckoResultOK;
}
- (void)setRequestedLocales:(NSArray<NSString *> *)locales {
    if (!_runtime || locales.count == 0) { return; }
    NSString *csv = [locales componentsJoinedByString:@","];
    GGGeckoRuntimeSetLocales(_runtime, csv.UTF8String);
}
- (void)enterBackground { if (_runtime) GGGeckoRuntimeEnterBackground(_runtime); }
- (void)enterForeground { if (_runtime) GGGeckoRuntimeEnterForeground(_runtime); }

- (void)clearCacheForBaseDomain:(NSString *)baseDomain
                     completion:(void (^)(BOOL))completion {
    if (!_runtime) {
        if (completion) { completion(NO); }
        return;
    }
    // Network/image caches are only part of Gecko's on-disk footprint. Web
    // applications also keep sizeable quota-managed data in IndexedDB and the
    // Cache API. Clear those as well, while deliberately leaving cookies out
    // of this operation so the dedicated "清除 Cookie" action stays separate.
    uint32_t flags = GGGeckoClearDataNetworkCache |
                     GGGeckoClearDataImageCache |
                     GGGeckoClearDataDOMStorages;

    GGClearDataCompletionBox *box = nil;
    void *context = nullptr;
    GGGeckoOperationCallback callback = nullptr;
    if (completion) {
        box = [[GGClearDataCompletionBox alloc] init];
        box.completion = completion;
        context = (__bridge_retained void *)box;
        callback = GGClearDataDidFinish;
    }

    GGGeckoResult result = GGGeckoRuntimeClearData(_runtime,
                                                   flags,
                                                   baseDomain.UTF8String,
                                                   _sessionContextId.length ? _sessionContextId.UTF8String : nullptr,
                                                   context,
                                                   callback);
    if (result != GGGeckoResultOK && context) {
        // The callback will never run when dispatch was rejected, so balance
        // the retained bridge context here and report the failure ourselves.
        CFBridgingRelease(context);
        completion(NO);
    }
}

- (void)clearCookiesForBaseDomain:(NSString *)baseDomain
                       completion:(void (^)(BOOL))completion {
    if (!_runtime) {
        if (completion) { completion(NO); }
        return;
    }

    GGClearDataCompletionBox *box = nil;
    void *context = nullptr;
    GGGeckoOperationCallback callback = nullptr;
    if (completion) {
        box = [[GGClearDataCompletionBox alloc] init];
        box.completion = completion;
        context = (__bridge_retained void *)box;
        callback = GGClearDataDidFinish;
    }

    GGGeckoResult result = GGGeckoRuntimeClearBaseDomainData(
        _runtime,
        baseDomain.UTF8String,
        GGGeckoClearDataCookies,
        _sessionContextId.length ? _sessionContextId.UTF8String : nullptr,
        context,
        callback);
    if (result != GGGeckoResultOK && context) {
        CFBridgingRelease(context);
        completion(NO);
    }
}

- (void)migrateCookiesToShared:(BOOL)toShared
                    contextIds:(NSArray<NSString *> *)contextIds
                    completion:(void (^)(BOOL))completion {
    if (!_runtime || contextIds.count != 2 ||
        ![contextIds[0] isKindOfClass:NSString.class] ||
        ![contextIds[1] isKindOfClass:NSString.class]) {
        if (completion) { completion(NO); }
        return;
    }

    GGClearDataCompletionBox *box = [[GGClearDataCompletionBox alloc] init];
    box.completion = completion;
    void *context = (__bridge_retained void *)box;
    GGGeckoResult result = GGGeckoRuntimeMigrateCookies(
        _runtime,
        contextIds[0].UTF8String,
        contextIds[1].UTF8String,
        toShared,
        context,
        GGClearDataDidFinish);
    if (result != GGGeckoResultOK) {
        CFBridgingRelease(context);
        if (completion) { completion(NO); }
    }
}

- (void)setDiskCacheSmartSizeEnabled:(BOOL)enabled
                           completion:(void (^)(BOOL))completion {
    if (!_runtime) {
        if (completion) { completion(NO); }
        return;
    }
    GGClearDataCompletionBox *box = [[GGClearDataCompletionBox alloc] init];
    box.completion = completion;
    void *context = (__bridge_retained void *)box;
    GGGeckoResult result = GGGeckoRuntimeSetDiskCacheSmartSizeEnabled(
        _runtime, enabled, context, GGClearDataDidFinish);
    if (result != GGGeckoResultOK) {
        CFBridgingRelease(context);
        if (completion) { completion(NO); }
    }
}

- (void)setDiskCacheCapacityKB:(NSInteger)capacityKB
                     completion:(void (^)(BOOL))completion {
    if (!_runtime || capacityKB < 0 || capacityKB > INT32_MAX) {
        if (completion) { completion(NO); }
        return;
    }
    GGClearDataCompletionBox *box = [[GGClearDataCompletionBox alloc] init];
    box.completion = completion;
    void *context = (__bridge_retained void *)box;
    GGGeckoResult result = GGGeckoRuntimeSetDiskCacheCapacityKB(
        _runtime, (uint32_t)capacityKB, context, GGClearDataDidFinish);
    if (result != GGGeckoResultOK) {
        CFBridgingRelease(context);
        if (completion) { completion(NO); }
    }
}

- (void)close {
    NSAssert(NSThread.isMainThread, @"Gecko bridge must close on the main thread");
    if (_session) {
        GGGeckoSessionSetFocused(_session, false);
        GGGeckoSessionSetActive(_session, false);
        GGGeckoSessionDestroy(_session);
        _session = nullptr;
    }
    _nativeView = nil;
    _currentURL = nil;
    _sessionContextId = nil;
    self.progressHandler = nil;
    _jitState = GeminiGeckoJITStateUnresolved;
    _jitReason = 0;
    if (_runtime) {
        GGGeckoRuntimeDestroy(_runtime);
        _runtime = nullptr;
    }
    _started = NO;
}

@end
