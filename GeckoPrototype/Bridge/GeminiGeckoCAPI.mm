#import "GeminiGeckoCAPI.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import <GeckoView/GeckoViewSwiftSupport.h>
#import <GeckoView/IOSBootstrap.h>

#include <memory>
#include <stdlib.h>
#include <string>
#include <vector>
#include <unistd.h>

struct GGGeckoRuntime;
struct GGGeckoSession;

@interface GGHostEventDispatcher : NSObject <SwiftEventDispatcher>
// Firefox hands us an autoreleased EventDispatcherImpl proxy and expects the
// embedder dispatcher to retain it for as long as the Gecko EventDispatcher is
// attached. The reference Swift EventDispatcher uses a strong stored property.
// Keeping this weak lets the proxy disappear at the next autorelease-pool
// drain, turning later LoadUri/Reload dispatches into no-ops.
@property(nonatomic, strong) id<GeckoEventDispatcher> gecko;
@property(nonatomic) BOOL active;
@property(nonatomic, copy, nullable) id (^messageHandler)(NSString *type,
                                                          NSDictionary * _Nullable message,
                                                          id<EventCallback> _Nullable callback);
- (void)sendToGecko:(NSString *)type message:(NSDictionary * _Nullable)message;
- (void)sendToGecko:(NSString *)type
             message:(NSDictionary * _Nullable)message
            callback:(id<EventCallback> _Nullable)callback;
@end

@interface GGBlockEventCallback : NSObject <EventCallback>
@property(nonatomic, copy, nullable) void (^completion)(BOOL success);
@end

@implementation GGBlockEventCallback
- (void)sendSuccess:(id)response {
    (void)response;
    if (self.completion) {
        NSLog(@"[GeminiGecko][Storage] clear-data callback success");
        self.completion(YES);
        self.completion = nil;
    }
}
- (void)sendError:(id)response {
    (void)response;
    if (self.completion) {
        NSLog(@"[GeminiGecko][Storage] clear-data callback error=%@",
              response ?: @"(none)");
        self.completion(NO);
        self.completion = nil;
    }
}
@end

@interface GGDocumentPickerCallbackDelegate
    : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, strong, nullable) id<EventCallback> callback;
@end

@implementation GGDocumentPickerCallbackDelegate

- (void)finishWithURLs:(NSArray<NSURL *> * _Nullable)urls {
    id<EventCallback> callback = self.callback;
    self.callback = nil;
    if (!callback) { return; }

    if (!urls.count) {
        NSLog(@"[GeminiGecko][FilePicker] cancelled");
        [callback sendSuccess:nil];
        return;
    }

    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        if (url.path.length) {
            [paths addObject:url.path];
        }
    }
    NSLog(@"[GeminiGecko][FilePicker] selected=%lu", (unsigned long)paths.count);
    [callback sendSuccess:paths.count ? @{ @"files": paths } : nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self finishWithURLs:urls];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [self finishWithURLs:nil];
}

@end


static UIViewController *GGTopPresentedViewController(UIViewController *controller) {
    if (!controller) { return nil; }
    if (controller.presentedViewController) {
        return GGTopPresentedViewController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return GGTopPresentedViewController(
            ((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return GGTopPresentedViewController(
            ((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

static UIViewController *GGPromptPresenter(void) {
    UIWindow *targetWindow = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) {
            targetWindow = window;
            break;
        }
    }
    if (!targetWindow) {
        targetWindow = UIApplication.sharedApplication.windows.firstObject;
    }
    return GGTopPresentedViewController(targetWindow.rootViewController);
}

static BOOL GGPresentFilePrompt(NSDictionary *message,
                                id<EventCallback> callback) {
    if (!callback || ![message[@"type"] isEqualToString:@"file"]) {
        return NO;
    }

    void (^present)(void) = ^{
        UIViewController *presenter = GGPromptPresenter();
        if (!presenter) {
            NSLog(@"[GeminiGecko][FilePicker] no presenter");
            [callback sendSuccess:nil];
            return;
        }

        NSString *mode = [message[@"mode"] isKindOfClass:NSString.class]
            ? message[@"mode"] : @"single";
        NSArray<NSString *> *documentTypes = [mode isEqualToString:@"folder"]
            ? @[ @"public.folder" ] : @[ @"public.item" ];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc]
                initWithDocumentTypes:documentTypes
                               inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
        picker.allowsMultipleSelection = [mode isEqualToString:@"multiple"];
        if ([message[@"title"] isKindOfClass:NSString.class] &&
            [message[@"title"] length]) {
            picker.title = message[@"title"];
        }

        GGDocumentPickerCallbackDelegate *delegate =
            [[GGDocumentPickerCallbackDelegate alloc] init];
        delegate.callback = callback;
        picker.delegate = delegate;
        objc_setAssociatedObject(picker,
                                 @selector(documentPicker:didPickDocumentsAtURLs:),
                                 delegate,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (picker.popoverPresentationController) {
            picker.popoverPresentationController.sourceView = presenter.view;
            picker.popoverPresentationController.sourceRect = CGRectMake(
                CGRectGetMidX(presenter.view.bounds),
                CGRectGetMidY(presenter.view.bounds), 1, 1);
        }
        NSLog(@"[GeminiGecko][FilePicker] present mode=%@ mime=%@ capture=%@",
              mode, message[@"mimeTypes"] ?: @[], message[@"capture"] ?: @0);
        [presenter presentViewController:picker animated:YES completion:nil];
    };

    if (NSThread.isMainThread) {
        present();
    } else {
        dispatch_async(dispatch_get_main_queue(), present);
    }
    return YES;
}

@implementation GGHostEventDispatcher {
    NSMutableArray<NSDictionary *> *_pending;
    BOOL _pendingDrainScheduled;
    NSUInteger _pendingDrainAttempts;
}

static NSSet<NSString *> *GGSupportedSessionEvents(void) {
    static NSSet<NSString *> *events;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        events = [NSSet setWithArray:@[
            @"GeminiGecko:NavTrace",
            @"GeckoView:Prompt",
            // GeckoViewNavigation
            @"GeckoView:LocationChange",
            @"GeckoView:OnNewSession",
            @"GeckoView:OnLoadError",
            @"GeckoView:OnLoadRequest",
            // GeckoViewProgress
            @"GeckoView:PageStart",
            @"GeckoView:PageStop",
            @"GeckoView:ProgressChanged",
            @"GeckoView:SecurityChanged",
            @"GeckoView:StateUpdated",
            // GeckoViewContent
            @"GeckoView:ContentCrash",
            @"GeckoView:ContentKill",
            @"GeckoView:ContextMenu",
            @"GeckoView:DOMMetaViewportFit",
            @"GeckoView:PageTitleChanged",
            @"GeckoView:DOMWindowClose",
            @"GeckoView:ExternalResponse",
            @"GeckoView:FocusRequest",
            @"GeckoView:FullScreenEnter",
            @"GeckoView:FullScreenExit",
            @"GeckoView:WebAppManifest",
            @"GeckoView:FirstContentfulPaint",
            @"GeckoView:PaintStatusReset",
            @"GeckoView:PreviewImage",
            @"GeckoView:CookieBannerEvent:Detected",
            @"GeckoView:CookieBannerEvent:Handled",
            @"GeckoView:SavePdf",
            @"GeckoView:OnProductUrl",
            // GeckoViewPermission
            @"GeckoView:ContentPermission",
            @"GeckoView:MediaPermission",
            @"GeckoView:MediaRecordingStatusChanged",
        ]];
    });
    return events;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pending = [NSMutableArray array];
    }
    return self;
}

- (void)schedulePendingDrain {
    if (!self.active || !self.gecko || !_pending.count || _pendingDrainScheduled) {
        return;
    }

    _pendingDrainScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        self->_pendingDrainScheduled = NO;

        if (!self.active || !self.gecko || !self->_pending.count) {
            return;
        }

        NSArray<NSDictionary *> *pending = [self->_pending copy];
        [self->_pending removeAllObjects];

        for (NSDictionary *entry in pending) {
            NSString *type = entry[@"type"];
            id value = entry[@"message"];
            NSDictionary *message = value == NSNull.null ? nil : value;
            id callbackValue = entry[@"callback"];
            id<EventCallback> callback = callbackValue == NSNull.null ? nil : callbackValue;
            BOOL hasListener = [self.gecko hasListener:type];

            if (hasListener) {
                if ([type isEqualToString:@"GeckoView:LoadUri"] ||
                    [type isEqualToString:@"GeckoView:Reload"]) {
                    NSLog(@"[GeminiGecko][Nav] drain %@ listener=1 uri=%@",
                          type, message[@"uri"] ?: @"(none)");
                }
                [self.gecko dispatchToGecko:type message:message callback:callback];
            } else {
                [self->_pending addObject:entry];
            }
        }

        if (self->_pending.count) {
            self->_pendingDrainAttempts += 1;
            if (self->_pendingDrainAttempts < 200) {
                [self schedulePendingDrain];
            } else {
                NSLog(@"[GeminiGecko][Nav] pending listeners not ready after %lu attempts; keeping %lu queued",
                      (unsigned long)self->_pendingDrainAttempts,
                      (unsigned long)self->_pending.count);
                self->_pendingDrainAttempts = 0;
            }
        } else {
            self->_pendingDrainAttempts = 0;
        }
    });
}

- (void)attach:(id<GeckoEventDispatcher>)gecko {
    self.gecko = gecko;
    NSLog(@"[GeminiGecko][Nav] dispatcher attach gecko=%@ active=%d",
          gecko ? @"yes" : @"no", self.active);
    GGGeckoStartupTrace("dispatcher.attach");
}

- (void)activate {
    NSLog(@"[GeminiGecko][Nav] dispatcher activate pending=%lu gecko=%@",
          (unsigned long)_pending.count, self.gecko ? @"yes" : @"no");
    GGGeckoStartupTrace("dispatcher.activate");
    self.active = YES;
    [self schedulePendingDrain];
}

- (BOOL)hasListener:(NSString *)type {
    return self.messageHandler != nil &&
        [GGSupportedSessionEvents() containsObject:type];
}

- (void)dispatchToSwift:(NSString *)type
                message:(id)message
               callback:(id<EventCallback>)callback {
    NSDictionary *dictionary = [message isKindOfClass:NSDictionary.class] ? message : nil;
    if ([type isEqualToString:@"GeckoView:Prompt"] &&
        GGPresentFilePrompt(dictionary ?: @{}, callback)) {
        return;
    }
    if ([type isEqualToString:@"GeminiGecko:NavTrace"]) {
        NSLog(@"[GeminiGecko][NavJS] stage=%@ uri=%@ remote=%@ remoteType=%@ error=%@",
              dictionary[@"stage"] ?: @"(none)",
              dictionary[@"uri"] ?: @"(none)",
              dictionary[@"remote"] ?: @"(none)",
              dictionary[@"remoteType"] ?: @"(none)",
              dictionary[@"error"] ?: @"(none)");
        if ([dictionary[@"stage"] hasPrefix:@"snapshot-"]) {
            NSLog(@"[GeminiGecko][NavJS] snapshot stage=%@ current=%@ href=%@ ready=%@ title=%@ bodyChildren=%@ bodyText=%@ html=%@x%@ browser=%@x%@ display=%@ visibility=%@ opacity=%@ background=%@ docShellActive=%@ hidden=%@ error=%@",
                  dictionary[@"stage"] ?: @"(none)",
                  dictionary[@"currentURI"] ?: @"(none)",
                  dictionary[@"href"] ?: @"(none)",
                  dictionary[@"readyState"] ?: @"(none)",
                  dictionary[@"title"] ?: @"(none)",
                  dictionary[@"bodyChildren"] ?: @"(none)",
                  dictionary[@"bodyTextLength"] ?: @"(none)",
                  dictionary[@"htmlWidth"] ?: @"(none)",
                  dictionary[@"htmlHeight"] ?: @"(none)",
                  dictionary[@"browserWidth"] ?: @"(none)",
                  dictionary[@"browserHeight"] ?: @"(none)",
                  dictionary[@"display"] ?: @"(none)",
                  dictionary[@"visibility"] ?: @"(none)",
                  dictionary[@"opacity"] ?: @"(none)",
                  dictionary[@"background"] ?: @"(none)",
                  dictionary[@"docShellActive"] ?: @"(none)",
                  dictionary[@"hidden"] ?: @"(none)",
                  dictionary[@"error"] ?: @"(none)");
        }
        if ([dictionary[@"stage"] hasPrefix:@"picker-"]) {
            NSLog(@"[GeminiGecko][PickerDiag] stage=%@ ready=%@ title=%@ bodyChildren=%@ bodyText=%@ html=%@x%@ display=%@ visibility=%@ opacity=%@ scripts=%@ styles=%@ resources=%@ urls=%@ error=%@",
                  dictionary[@"stage"] ?: @"(none)",
                  dictionary[@"readyState"] ?: @"(none)",
                  dictionary[@"title"] ?: @"(none)",
                  dictionary[@"bodyChildren"] ?: @"(none)",
                  dictionary[@"bodyTextLength"] ?: @"(none)",
                  dictionary[@"htmlWidth"] ?: @"(none)",
                  dictionary[@"htmlHeight"] ?: @"(none)",
                  dictionary[@"display"] ?: @"(none)",
                  dictionary[@"visibility"] ?: @"(none)",
                  dictionary[@"opacity"] ?: @"(none)",
                  dictionary[@"scriptCount"] ?: @"(none)",
                  dictionary[@"styleSheetCount"] ?: @"(none)",
                  dictionary[@"resourceCount"] ?: @"(none)",
                  dictionary[@"resources"] ?: @"(none)",
                  dictionary[@"error"] ?: @"(none)");
            NSLog(@"[GeminiGecko][PickerDiag] structure stage=%@ children=%@ frames=%@ scripts=%@ styles=%@ windowName=%@ parentIsSelf=%@ topIsSelf=%@ frameElement=%@ bodyHTML=%@",
                  dictionary[@"stage"] ?: @"(none)",
                  dictionary[@"childSummary"] ?: @"(none)",
                  dictionary[@"frameSummary"] ?: @"(none)",
                  dictionary[@"scriptSummary"] ?: @"(none)",
                  dictionary[@"styleSummary"] ?: @"(none)",
                  dictionary[@"windowName"] ?: @"(none)",
                  dictionary[@"parentIsSelf"] ?: @"(none)",
                  dictionary[@"topIsSelf"] ?: @"(none)",
                  dictionary[@"frameElementTag"] ?: @"(none)",
                  dictionary[@"bodyHTMLSample"] ?: @"(none)");
        }
    }
    id result = self.messageHandler ? self.messageHandler(type, dictionary, callback) : nil;
    if (callback) {
        [callback sendSuccess:result];
    }
}

- (void)sendToGecko:(NSString *)type message:(NSDictionary *)message {
    [self sendToGecko:type message:message callback:nil];
}

- (void)sendToGecko:(NSString *)type
             message:(NSDictionary *)message
            callback:(id<EventCallback>)callback {
    if (!type.length) { return; }
    BOOL hasListener = self.gecko ? [self.gecko hasListener:type] : NO;
    if ([type isEqualToString:@"GeckoView:LoadUri"] ||
        [type isEqualToString:@"GeckoView:Reload"]) {
        NSLog(@"[GeminiGecko][Nav] send %@ active=%d gecko=%@ listener=%d uri=%@",
              type, self.active, self.gecko ? @"yes" : @"no", hasListener,
              message[@"uri"] ?: @"(none)");
    }
    if (self.active && self.gecko && hasListener) {
        [self.gecko dispatchToGecko:type message:message callback:callback];
        return;
    }
    id callbackEntry = callback ? (id)callback : (id)NSNull.null;
    [_pending addObject:@{
        @"type": type,
        @"message": message ?: NSNull.null,
        @"callback": callbackEntry,
    }];
    if (self.active) {
        [self schedulePendingDrain];
    }
}

@end

@interface GGHostRuntimeAdapter : NSObject <SwiftGeckoViewRuntime>
@property(nonatomic, strong) GGHostEventDispatcher *runtimeDispatcherImpl;
@property(nonatomic, strong) NSMutableDictionary<NSString *, GGHostEventDispatcher *> *namedDispatchers;
@end

@implementation GGHostRuntimeAdapter

- (instancetype)init {
    self = [super init];
    if (self) {
        _runtimeDispatcherImpl = [[GGHostEventDispatcher alloc] init];
        _namedDispatchers = [NSMutableDictionary dictionary];
    }
    return self;
}

- (id<SwiftEventDispatcher>)runtimeDispatcher {
    return self.runtimeDispatcherImpl;
}

- (id<SwiftEventDispatcher>)dispatcherByName:(const char *)name {
    NSString *key = name ? [NSString stringWithUTF8String:name] : @"";
    @synchronized (self.namedDispatchers) {
        GGHostEventDispatcher *dispatcher = self.namedDispatchers[key];
        if (!dispatcher) {
            dispatcher = [[GGHostEventDispatcher alloc] init];
            self.namedDispatchers[key] = dispatcher;
        }
        return dispatcher;
    }
}

- (void)lockScreenOrientation:(NSUInteger)orientationMask
                   completion:(void (^)(GeckoOrientationLockResult))completion {
    (void)orientationMask;
    if (completion) {
        completion(GeckoOrientationLockResultNotSupported);
    }
}

- (void)unlockScreenOrientation {}

- (void)childProcessDidStartWithPID:(int32_t)pid processType:(NSString *)processType {
    // DualAI's production candidate opens Gemini without the `remote` chrome
    // flag, so this should not be reached for page content. Keep the callback
    // implemented because the Gecko protocol exposes it and diagnostics may
    // deliberately exercise the remote path.
    NSLog(@"[GeminiGecko] unexpected child process pid=%d type=%@", pid, processType);
}

@end

struct GGGeckoRuntime {
    __strong GGHostRuntimeAdapter *adapter;
    GGGeckoJITMode jitMode;
};

struct GGGeckoSession {
    GGGeckoRuntime *runtime;
    GGGeckoSessionCallbacks callbacks;
    __strong GGHostEventDispatcher *dispatcher;
    __strong id<GeckoViewWindow> window;
    bool canGoBack;
    bool canGoForward;
};

static GGHostRuntimeAdapter *gRuntimeAdapter;
static BOOL gBootstrapEntered = NO;

static NSString *GGStartupTracePath(void) {
    NSString *cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    [NSFileManager.defaultManager createDirectoryAtPath:cache
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return [cache stringByAppendingPathComponent:@"DualAI-GeckoStartup.log"];
}

void GGGeckoStartupTraceReset(void) {
    @autoreleasepool {
        [@"" writeToFile:GGStartupTracePath()
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    }
}

void GGGeckoStartupTrace(const char *stage_utf8) {
    @autoreleasepool {
        NSString *stage = stage_utf8 ? [NSString stringWithUTF8String:stage_utf8] : @"(null)";
        NSString *line = [NSString stringWithFormat:@"%@ pid=%d %@\n",
                          NSDate.date, getpid(), stage ?: @"(invalid-utf8)"];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSString *path = GGStartupTracePath();
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) { return; }
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle synchronizeFile];
        } @catch (__unused NSException *exception) {
        }
        [handle closeFile];
    }
}

static void GGSendUTF8(void (*callback)(void *, const char *),
                       void *context,
                       NSString *value) {
    if (!callback || !value.length) { return; }
    callback(context, value.UTF8String);
}

static void GGNotifyJITState(GGGeckoSession *session) {
    if (!session || !session->callbacks.did_change_jit_state) { return; }
    const bool enabled = GeckoViewIsJITEnabled();
    GGGeckoJITState state = enabled
        ? GGGeckoJITStateEnabled
        : (session->runtime->jitMode == GGGeckoJITModeRequired
            ? GGGeckoJITStateFailed
            : GGGeckoJITStateDegradedNoJIT);
    session->callbacks.did_change_jit_state(session->callbacks.context,
                                            state,
                                            enabled ? 0 : 1);
}

static BOOL GGHostMatchesDomain(NSString *host, NSString *domain) {
    if (!host.length || !domain.length) { return NO; }
    host = host.lowercaseString;
    domain = domain.lowercaseString;
    return [host isEqualToString:domain] ||
        [host hasSuffix:[@"." stringByAppendingString:domain]];
}

static BOOL GGIsTrustedMediaURI(NSString *uriString) {
    NSURL *url = uriString.length ? [NSURL URLWithString:uriString] : nil;
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"https"]) {
        return NO;
    }
    NSString *host = url.host.lowercaseString;
    return GGHostMatchesDomain(host, @"gemini.google.com") ||
        GGHostMatchesDomain(host, @"chatgpt.com") ||
        GGHostMatchesDomain(host, @"openai.com");
}

static NSString *GGFirstMediaSourceID(id sourcesValue) {
    if (![sourcesValue isKindOfClass:NSArray.class]) { return nil; }
    for (id source in (NSArray *)sourcesValue) {
        if (![source isKindOfClass:NSDictionary.class]) { continue; }
        id sourceID = ((NSDictionary *)source)[@"id"];
        if ([sourceID isKindOfClass:NSString.class] && [sourceID length]) {
            return sourceID;
        }
    }
    return nil;
}

static void GGUpdateNavigationStateFromMessage(GGGeckoSession *session,
                                                NSDictionary *message) {
    if (!session || !message) { return; }
    id canGoBack = message[@"canGoBack"];
    id canGoForward = message[@"canGoForward"];
    if ([canGoBack respondsToSelector:@selector(boolValue)]) {
        session->canGoBack = [canGoBack boolValue];
    }
    if ([canGoForward respondsToSelector:@selector(boolValue)]) {
        session->canGoForward = [canGoForward boolValue];
    }
}

static NSArray<NSString *> *GGArgumentsWithProfile(int argc,
                                                   char **argv,
                                                   NSString *profilePath) {
    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    BOOL hasProfile = NO;
    for (int i = 0; i < argc; ++i) {
        NSString *argument = argv && argv[i]
            ? [NSString stringWithUTF8String:argv[i]]
            : @"";
        [arguments addObject:argument ?: @""];
        if ([argument isEqualToString:@"--profile"] || [argument isEqualToString:@"-profile"]) {
            hasProfile = YES;
        }
    }
    if (!hasProfile && profilePath.length) {
        [arguments addObject:@"--profile"];
        [arguments addObject:profilePath];
    }
    return arguments;
}

int GGGeckoApplicationMain(int argc,
                           char **argv,
                           const char *profile_path_utf8) {
    @autoreleasepool {
        GGGeckoStartupTrace("application-main.enter");
        NSLog(@"[GeminiGecko] bootstrap enter");
        if (gBootstrapEntered) {
            GGGeckoStartupTrace("application-main.duplicate-bootstrap");
            return 2;
        }
        NSString *profilePath = profile_path_utf8
            ? [NSString stringWithUTF8String:profile_path_utf8]
            : nil;
        if (!profilePath.length) {
            GGGeckoStartupTrace("application-main.invalid-profile");
            return 3;
        }

        NSError *directoryError = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:profilePath
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&directoryError]) {
            NSLog(@"[GeminiGecko] profile creation failed: %@", directoryError);
            GGGeckoStartupTrace("application-main.profile-create-failed");
            return 4;
        }
        GGGeckoStartupTrace("application-main.profile-ready");

        // Firefox's XP_IOS defaults route HTTP/DNS/socket work through the
        // separate Socket Process. That process is supplied by the modern
        // iOS process/extension architecture, but this iOS 15 UIKit embedding
        // deliberately runs Gecko in-process and has no socket-process host.
        // nsIOService checks this environment override before both launching
        // and using the Socket Process, so keep networking in the main process
        // before MainProcessInit initializes Necko.
        const int disableSocketProcessResult =
            setenv("MOZ_DISABLE_SOCKET_PROCESS", "1", 1);
        NSLog(@"[GeminiGecko][Net] disable-socket-process result=%d value=%s",
              disableSocketProcessResult,
              getenv("MOZ_DISABLE_SOCKET_PROCESS") ?: "(null)");

        NSArray<NSString *> *arguments = GGArgumentsWithProfile(argc, argv, profilePath);
        std::vector<std::string> storage;
        std::vector<char *> pointers;
        storage.reserve(arguments.count);
        pointers.reserve(arguments.count + 1);
        for (NSString *argument in arguments) {
            storage.emplace_back(argument.UTF8String ?: "");
        }
        for (std::string &argument : storage) {
            pointers.push_back(argument.data());
        }
        pointers.push_back(nullptr);

        gRuntimeAdapter = [[GGHostRuntimeAdapter alloc] init];
        gBootstrapEntered = YES;
        GGGeckoStartupTrace("application-main.before-MainProcessInit");
        NSLog(@"[GeminiGecko] entering MainProcessInit profile=%@", profilePath);
        return MainProcessInit((int)storage.size(), pointers.data(), gRuntimeAdapter);
    }
}

bool GGGeckoRuntimeIsBootstrapped(void) {
    return gBootstrapEntered && gRuntimeAdapter != nil;
}

GGGeckoResult GGGeckoRuntimeCreate(const GGGeckoRuntimeOptions *options,
                                   GGGeckoRuntime **out_runtime) {
    GGGeckoStartupTrace("runtime-create.enter");
    if (!options || !out_runtime || !options->profile_path_utf8) {
        GGGeckoStartupTrace("runtime-create.invalid-argument");
        return GGGeckoResultInvalidArgument;
    }
    *out_runtime = nullptr;
    if (!GGGeckoRuntimeIsBootstrapped()) {
        GGGeckoStartupTrace("runtime-create.not-bootstrapped");
        return GGGeckoResultRuntimeFailure;
    }

    std::unique_ptr<GGGeckoRuntime> runtime(new GGGeckoRuntime());
    runtime->adapter = gRuntimeAdapter;
    runtime->jitMode = options->jit_mode;
    *out_runtime = runtime.release();
    GGGeckoStartupTrace("runtime-create.ok");
    return GGGeckoResultOK;
}

GGGeckoResult GGGeckoRuntimeClearBaseDomainData(GGGeckoRuntime *runtime,
                                                const char *base_domain_utf8,
                                                uint32_t flags) {
    if (!runtime || !runtime->adapter || !base_domain_utf8 || flags == 0) {
        return GGGeckoResultInvalidArgument;
    }
    NSString *baseDomain = [NSString stringWithUTF8String:base_domain_utf8];
    if (!baseDomain.length) {
        return GGGeckoResultInvalidArgument;
    }

    // GeckoViewStorageController currently expects a non-null callback even
    // though UIKit's async callback bridge is not yet reliable for these
    // Promise-backed clear-data operations. Keep a no-op callback attached so
    // the Gecko handler can safely call onSuccess after deletion finishes.
    GGBlockEventCallback *eventCallback = [[GGBlockEventCallback alloc] init];
    NSLog(@"[GeminiGecko][Storage] clear-base-domain base=%@ flags=0x%x",
          baseDomain, flags);
    [runtime->adapter.runtimeDispatcherImpl
        sendToGecko:@"GeckoView:ClearBaseDomainData"
             message:@{ @"baseDomain": baseDomain, @"flags": @(flags) }
            callback:eventCallback];
    return GGGeckoResultOK;
}

void GGGeckoRuntimeDestroy(GGGeckoRuntime *runtime) {
    delete runtime;
}

GGGeckoResult GGGeckoSessionCreate(GGGeckoRuntime *runtime,
                                   const GGGeckoSessionCallbacks *callbacks,
                                   GGGeckoSession **out_session) {
    GGGeckoStartupTrace("session-create.enter");
    if (!runtime || !callbacks || !out_session || !NSThread.isMainThread) {
        GGGeckoStartupTrace("session-create.invalid-argument");
        return GGGeckoResultInvalidArgument;
    }
    *out_session = nullptr;

    std::unique_ptr<GGGeckoSession> session(new GGGeckoSession());
    session->runtime = runtime;
    session->callbacks = *callbacks;
    session->dispatcher = [[GGHostEventDispatcher alloc] init];
    session->canGoBack = false;
    session->canGoForward = false;

    GGGeckoSession *rawSession = session.get();
    session->dispatcher.messageHandler = ^id(NSString *type,
                                             NSDictionary *message,
                                             id<EventCallback> callback) {
        if ([type isEqualToString:@"GeckoView:LocationChange"]) {
            NSLog(@"[GeminiGecko][Nav] location uri=%@ top=%@",
                  message[@"uri"], message[@"isTopLevel"]);
            GGUpdateNavigationStateFromMessage(rawSession, message);
            BOOL isTopLevel = !message[@"isTopLevel"] || [message[@"isTopLevel"] boolValue];
            if (isTopLevel) {
                GGSendUTF8(rawSession->callbacks.did_commit_url,
                           rawSession->callbacks.context,
                           message[@"uri"]);
            }
            return nil;
        }
        if ([type isEqualToString:@"GeckoView:OnLoadError"]) {
            NSLog(@"[GeminiGecko][Nav] load-error uri=%@ error=%@ module=%@ class=%@",
                  message[@"uri"], message[@"error"], message[@"errorModule"],
                  message[@"errorClass"]);
            return nil;
        }
        if ([type isEqualToString:@"GeckoView:PageStart"]) {
            GGUpdateNavigationStateFromMessage(rawSession, message);
            NSString *pageURI = [message[@"uri"] isKindOfClass:NSString.class]
                ? message[@"uri"] : nil;
            NSLog(@"[GeminiGecko][Nav] page-start uri=%@ back=%d forward=%d",
                  pageURI, rawSession->canGoBack, rawSession->canGoForward);
            if (pageURI.length && ![pageURI isEqualToString:@"about:blank"]) {
                GGSendUTF8(rawSession->callbacks.did_commit_url,
                           rawSession->callbacks.context,
                           pageURI);
            }
            if (rawSession->callbacks.did_change_progress) {
                rawSession->callbacks.did_change_progress(rawSession->callbacks.context, 0.0);
            }
            return nil;
        }
        if ([type isEqualToString:@"GeckoView:PageStop"]) {
            GGUpdateNavigationStateFromMessage(rawSession, message);
            NSString *pageURI = [message[@"uri"] isKindOfClass:NSString.class]
                ? message[@"uri"] : nil;
            NSLog(@"[GeminiGecko][Nav] page-stop uri=%@ success=%@ back=%d forward=%d",
                  pageURI, message[@"success"],
                  rawSession->canGoBack, rawSession->canGoForward);
            if (pageURI.length && ![pageURI isEqualToString:@"about:blank"]) {
                GGSendUTF8(rawSession->callbacks.did_commit_url,
                           rawSession->callbacks.context,
                           pageURI);
            }
            if (rawSession->callbacks.did_change_progress) {
                rawSession->callbacks.did_change_progress(rawSession->callbacks.context, 1.0);
            }
            return nil;
        }
        if ([type isEqualToString:@"GeckoView:PageTitleChanged"]) {
            GGSendUTF8(rawSession->callbacks.did_change_title,
                       rawSession->callbacks.context,
                       message[@"title"]);
            return nil;
        }
        if ([type isEqualToString:@"GeckoView:ProgressChanged"]) {
            id value = message[@"progress"];
            if (rawSession->callbacks.did_change_progress &&
                [value respondsToSelector:@selector(doubleValue)]) {
                rawSession->callbacks.did_change_progress(
                    rawSession->callbacks.context,
                    [value doubleValue] / 100.0);
            }
            return nil;
        }
        if ([type isEqualToString:@"GeckoView:ContentCrash"] ||
            [type isEqualToString:@"GeckoView:ContentKill"]) {
            if (rawSession->callbacks.did_terminate_content_process) {
                rawSession->callbacks.did_terminate_content_process(
                    rawSession->callbacks.context,
                    [type hasSuffix:@"Crash"] ? 1 : 2);
            }
            return nil;
        }
        if ([type isEqualToString:@"GeckoView:OnLoadRequest"]) {
            return @YES;
        }
        if ([type isEqualToString:@"GeckoView:OnNewSession"]) {
            return @NO;
        }
        if ([type isEqualToString:@"GeckoView:ContentPermission"]) {
            // Match the reference iOS GeckoView handler when no app-level
            // PermissionDelegate is installed: leave the decision at prompt.
            return @3;
        }
        if ([type isEqualToString:@"GeckoView:MediaPermission"]) {
            NSString *uri = [message[@"uri"] isKindOfClass:NSString.class]
                ? message[@"uri"] : @"";
            if (!GGIsTrustedMediaURI(uri)) {
                NSLog(@"[GeminiGecko][Permission] media denied untrusted uri=%@", uri);
                return @NO;
            }

            NSString *videoID = GGFirstMediaSourceID(message[@"video"]);
            NSString *audioID = GGFirstMediaSourceID(message[@"audio"]);
            NSUInteger videoCount = [message[@"video"] isKindOfClass:NSArray.class]
                ? [message[@"video"] count] : 0;
            NSUInteger audioCount = [message[@"audio"] isKindOfClass:NSArray.class]
                ? [message[@"audio"] count] : 0;
            NSLog(@"[GeminiGecko][Permission] media uri=%@ video=%lu audio=%lu selectVideo=%d selectAudio=%d",
                  uri, (unsigned long)videoCount, (unsigned long)audioCount,
                  videoID != nil, audioID != nil);

            if (!videoID && !audioID) {
                return @NO;
            }
            return @{
                @"video": videoID ?: NSNull.null,
                @"audio": audioID ?: NSNull.null,
            };
        }
        if ([type isEqualToString:@"GeckoView:MediaRecordingStatusChanged"]) {
            NSLog(@"[GeminiGecko][Permission] media-recording devices=%@",
                  message[@"devices"] ?: @"(none)");
            return nil;
        }
        (void)callback;
        return nil;
    };

    NSDictionary *settings = @{
        @"chromeUri": NSNull.null,
        @"screenId": @0,
        @"useTrackingProtection": @NO,
        @"userAgentMode": @0,
        @"userAgentOverride": NSNull.null,
        @"viewportMode": @0,
        @"displayMode": @0,
        @"suspendMediaWhenInactive": @YES,
        @"allowJavascript": @YES,
        @"fullAccessibilityTree": @NO,
        @"isPopup": @NO,
        @"sessionContextId": NSNull.null,
        @"unsafeSessionContextId": NSNull.null,
    };
    NSDictionary *modules = @{
        @"GeckoViewContent": @YES,
        @"GeckoViewNavigation": @YES,
        @"GeckoViewProgress": @YES,
        @"GeckoViewPermission": @YES,
    };
    NSDictionary *initData = @{
        @"settings": settings,
        @"modules": modules,
        @"useRemoteProcess": @NO,
    };

    NSString *windowID = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-"
                                                                           withString:@""];
    GGGeckoStartupTrace("session-create.before-GeckoViewOpenWindow.parent");
    NSLog(@"[GeminiGecko] opening GeckoView window parent-process mode");
    session->window = GeckoViewOpenWindow(windowID,
                                          session->dispatcher,
                                          initData,
                                          false);
    if (!session->window || ![session->window view]) {
        NSLog(@"[GeminiGecko] GeckoView window creation failed");
        GGGeckoStartupTrace("session-create.GeckoViewOpenWindow-failed");
        return GGGeckoResultSessionFailure;
    }
    GGGeckoStartupTrace("session-create.GeckoViewOpenWindow-ok");
    NSLog(@"[GeminiGecko] GeckoView window ready");

    *out_session = session.release();
    GGNotifyJITState(*out_session);
    GGGeckoStartupTrace(GeckoViewIsJITEnabled()
                            ? "session-create.ok.jit-enabled"
                            : "session-create.ok.no-jit");
    return GGGeckoResultOK;
}

void GGGeckoSessionDestroy(GGGeckoSession *session) {
    if (!session) { return; }
    [session->window close];
    session->dispatcher.messageHandler = nil;
    session->dispatcher = nil;
    session->window = nil;
    delete session;
}

void *GGGeckoSessionGetNativeView(GGGeckoSession *session) {
    if (!session || !session->window) { return nullptr; }
    return (__bridge void *)[session->window view];
}

GGGeckoResult GGGeckoSessionLoadURL(GGGeckoSession *session,
                                    const char *url_utf8) {
    GGGeckoStartupTrace("load-url.enter");
    if (!session || !url_utf8 || !NSThread.isMainThread) {
        GGGeckoStartupTrace("load-url.invalid-argument");
        return GGGeckoResultInvalidArgument;
    }
    NSString *url = [NSString stringWithUTF8String:url_utf8];
    if (!url.length) {
        GGGeckoStartupTrace("load-url.invalid-url");
        return GGGeckoResultInvalidArgument;
    }
    NSLog(@"[GeminiGecko][Nav] load-url request %@", url);
    [session->dispatcher sendToGecko:@"GeckoView:LoadUri"
                             message:@{
        @"uri": url,
        @"flags": @0,
        @"headerFilter": @1,
    }];
    GGGeckoStartupTrace("load-url.dispatched");
    return GGGeckoResultOK;
}

void GGGeckoSessionReload(GGGeckoSession *session) {
    [session->dispatcher sendToGecko:@"GeckoView:Reload" message:@{ @"flags": @0 }];
}

void GGGeckoSessionReloadIgnoringCache(GGGeckoSession *session) {
    if (!session) { return; }
    NSLog(@"[GeminiGecko][Nav] reload bypass-cache=1");
    [session->dispatcher sendToGecko:@"GeckoView:Reload" message:@{ @"flags": @1 }];
}

void GGGeckoSessionStop(GGGeckoSession *session) {
    [session->dispatcher sendToGecko:@"GeckoView:Stop" message:nil];
}

void GGGeckoSessionGoBack(GGGeckoSession *session) {
    [session->dispatcher sendToGecko:@"GeckoView:GoBack"
                             message:@{ @"userInteraction": @YES }];
}

void GGGeckoSessionGoForward(GGGeckoSession *session) {
    [session->dispatcher sendToGecko:@"GeckoView:GoForward"
                             message:@{ @"userInteraction": @YES }];
}

bool GGGeckoSessionCanGoBack(GGGeckoSession *session) {
    return session ? session->canGoBack : false;
}

bool GGGeckoSessionCanGoForward(GGGeckoSession *session) {
    return session ? session->canGoForward : false;
}

void GGGeckoSessionSetActive(GGGeckoSession *session, bool active) {
    if (!session) { return; }
    [session->dispatcher sendToGecko:@"GeckoView:SetActive"
                             message:@{ @"active": @(active) }];
}

void GGGeckoSessionSetFocused(GGGeckoSession *session, bool focused) {
    if (!session) { return; }
    [session->dispatcher sendToGecko:@"GeckoView:SetFocused"
                             message:@{ @"focused": @(focused) }];
}

void GGGeckoRuntimeSetLocales(GGGeckoRuntime *runtime,
                              const char *locales_csv_utf8) {
    if (!runtime || !runtime->adapter || !locales_csv_utf8) { return; }
    NSString *csv = [NSString stringWithUTF8String:locales_csv_utf8];
    if (!csv.length) { return; }

    NSMutableArray<NSString *> *locales = [NSMutableArray array];
    for (NSString *candidate in [csv componentsSeparatedByString:@","]) {
        NSString *locale = [candidate stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (locale.length && ![locales containsObject:locale]) {
            [locales addObject:locale];
        }
    }
    if (!locales.count) { return; }

    NSString *acceptLanguages = [locales componentsJoinedByString:@","];
    NSLog(@"[GeminiGecko][Locale] requested=%@ accept=%@", locales, acceptLanguages);
    [runtime->adapter.runtimeDispatcherImpl
        sendToGecko:@"GeckoView:SetLocale"
             message:@{
        @"requestedLocales": locales,
        @"acceptLanguages": acceptLanguages,
    }];
}

void GGGeckoRuntimeEnterBackground(GGGeckoRuntime *runtime) {
    (void)runtime;
    // Gecko's AppShellDelegate owns process-wide UIKit lifecycle forwarding.
}

void GGGeckoRuntimeEnterForeground(GGGeckoRuntime *runtime) {
    (void)runtime;
    // Gecko's AppShellDelegate owns process-wide UIKit lifecycle forwarding.
}

GGGeckoResult GGGeckoRuntimeClearData(GGGeckoRuntime *runtime,
                                      uint32_t flags,
                                      void *context,
                                      GGGeckoOperationCallback callback) {
    if (!runtime || !runtime->adapter || flags == 0) {
        return GGGeckoResultInvalidArgument;
    }

    GGBlockEventCallback *eventCallback = [[GGBlockEventCallback alloc] init];
    if (callback) {
        eventCallback.completion = ^(BOOL success) {
            callback(context, success);
        };
    }

    NSLog(@"[GeminiGecko][Storage] clear-data flags=0x%x", flags);
    [runtime->adapter.runtimeDispatcherImpl
        sendToGecko:@"GeckoView:ClearData"
             message:@{ @"flags": @(flags) }
            callback:eventCallback];
    return GGGeckoResultOK;
}
