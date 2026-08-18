#import "GeminiGeckoBridge.h"
#import "GeminiGeckoCAPI.h"

static NSString * const GeminiGeckoBridgeErrorDomain = @"GeminiGeckoBridge";

@interface GeminiGeckoBridge () {
    GGGeckoRuntime *_runtime;
    GGGeckoSession *_session;
    __weak UIView *_nativeView;
    NSURL *_currentURL;
}
@property(nonatomic, readwrite, getter=isStarted) BOOL started;
@property(nonatomic, readwrite) GeminiGeckoJITState jitState;
@property(nonatomic, readwrite) NSInteger jitReason;
- (void)handleCommittedURLString:(NSString *)value;
- (void)handleProgress:(double)progress;
- (void)handleContentProcessTermination;
- (void)handleJITState:(GeminiGeckoJITState)state reason:(NSInteger)reason;
@end

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
                            error:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"Gecko bridge must start on the main thread");
    if (_started) { return YES; }
    if (!profileDirectory.isFileURL) {
        if (error) { *error = GGMakeError(GGGeckoResultInvalidArgument, @"profile path"); }
        return NO;
    }

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

    result = GGGeckoSessionCreate(_runtime, &callbacks, &_session);
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
- (void)setRequestedLocales:(NSArray<NSString *> *)locales {
    if (!_runtime || locales.count == 0) { return; }
    NSString *csv = [locales componentsJoinedByString:@","];
    GGGeckoRuntimeSetLocales(_runtime, csv.UTF8String);
}
- (void)enterBackground { if (_runtime) GGGeckoRuntimeEnterBackground(_runtime); }
- (void)enterForeground { if (_runtime) GGGeckoRuntimeEnterForeground(_runtime); }

- (void)clearCacheWithCompletion:(void (^)(BOOL))completion {
    if (!_runtime) {
        if (completion) { completion(NO); }
        return;
    }
    uint32_t flags = GGGeckoClearDataNetworkCache | GGGeckoClearDataImageCache;
    GGGeckoResult result = GGGeckoRuntimeClearData(_runtime,
                                                   flags,
                                                   nullptr,
                                                   nullptr);
    // Treat completion here as "request accepted". The UIKit async callback
    // bridge does not currently propagate Promise-backed ClearData completion
    // reliably, so callers use a bypass-cache reload as the visible/effective
    // completion path.
    if (completion) { completion(result == GGGeckoResultOK); }
}

- (void)clearCookiesForBaseDomain:(NSString *)baseDomain
                       completion:(void (^)(BOOL))completion {
    if (!_runtime) {
        if (completion) { completion(NO); }
        return;
    }
    GGGeckoResult result = GGGeckoRuntimeClearBaseDomainData(
        _runtime,
        baseDomain.UTF8String,
        GGGeckoClearDataCookies);
    if (completion) { completion(result == GGGeckoResultOK); }
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
