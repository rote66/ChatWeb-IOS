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

static const void *GGSelectionActionContextKey = &GGSelectionActionContextKey;

@interface GGSelectionActionContext : NSObject
@property(nonatomic, strong) GGHostEventDispatcher *dispatcher;
@property(nonatomic, weak) UIView *view;
- (void)executeAction:(NSString *)action;
@end

@implementation GGSelectionActionContext

- (void)executeAction:(NSString *)action {
    if (!action.length || !self.dispatcher) { return; }
    NSLog(@"[GeminiGecko][Selection] execute action=%@", action);
    [self.dispatcher sendToGecko:@"GeckoView:ExecuteSelectionAction"
                         message:@{
        @"id": action,
    }];
    UIView *view = self.view;
    if (view) {
        UIMenuController *menu = [UIMenuController sharedMenuController];
        [menu hideMenuFromView:view];
        menu.menuItems = nil;
        objc_setAssociatedObject(view, GGSelectionActionContextKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@end


@interface UIView (GGSelectionActionMenu)
- (nullable GGSelectionActionContext *)gg_geckoSelectionContext;
- (void)gg_geckoSelectionCut:(id)sender;
- (void)gg_geckoSelectionCopy:(id)sender;
- (void)gg_geckoSelectionPaste:(id)sender;
- (void)gg_geckoSelectionPastePlainText:(id)sender;
- (void)gg_geckoSelectionDelete:(id)sender;
- (void)gg_geckoSelectionSelectAll:(id)sender;
@end

@implementation UIView (GGSelectionActionMenu)

- (GGSelectionActionContext *)gg_geckoSelectionContext {
    UIView *candidate = self;
    while (candidate) {
        GGSelectionActionContext *context =
            objc_getAssociatedObject(candidate, GGSelectionActionContextKey);
        if (context) { return context; }
        candidate = candidate.superview;
    }
    return nil;
}

- (void)gg_geckoSelectionCut:(id)sender {
    (void)sender;
    [[self gg_geckoSelectionContext] executeAction:@"org.mozilla.geckoview.CUT"];
}

- (void)gg_geckoSelectionCopy:(id)sender {
    (void)sender;
    [[self gg_geckoSelectionContext] executeAction:@"org.mozilla.geckoview.COPY"];
}

- (void)gg_geckoSelectionPaste:(id)sender {
    (void)sender;
    [[self gg_geckoSelectionContext] executeAction:@"org.mozilla.geckoview.PASTE"];
}

- (void)gg_geckoSelectionPastePlainText:(id)sender {
    (void)sender;
    [[self gg_geckoSelectionContext]
        executeAction:@"org.mozilla.geckoview.PASTE_AS_PLAIN_TEXT"];
}

- (void)gg_geckoSelectionDelete:(id)sender {
    (void)sender;
    [[self gg_geckoSelectionContext] executeAction:@"org.mozilla.geckoview.DELETE"];
}

- (void)gg_geckoSelectionSelectAll:(id)sender {
    (void)sender;
    [[self gg_geckoSelectionContext] executeAction:@"org.mozilla.geckoview.SELECT_ALL"];
}

@end


static UIMenuItem *GGSelectionMenuItemForAction(NSString *action) {
    if ([action isEqualToString:@"org.mozilla.geckoview.CUT"]) {
        return [[UIMenuItem alloc] initWithTitle:@"剪切"
                                          action:@selector(gg_geckoSelectionCut:)];
    }
    if ([action isEqualToString:@"org.mozilla.geckoview.COPY"]) {
        return [[UIMenuItem alloc] initWithTitle:@"复制"
                                          action:@selector(gg_geckoSelectionCopy:)];
    }
    if ([action isEqualToString:@"org.mozilla.geckoview.PASTE"]) {
        return [[UIMenuItem alloc] initWithTitle:@"粘贴"
                                          action:@selector(gg_geckoSelectionPaste:)];
    }
    if ([action isEqualToString:@"org.mozilla.geckoview.PASTE_AS_PLAIN_TEXT"]) {
        return [[UIMenuItem alloc] initWithTitle:@"粘贴为纯文本"
                                          action:@selector(gg_geckoSelectionPastePlainText:)];
    }
    if ([action isEqualToString:@"org.mozilla.geckoview.DELETE"]) {
        return [[UIMenuItem alloc] initWithTitle:@"删除"
                                          action:@selector(gg_geckoSelectionDelete:)];
    }
    if ([action isEqualToString:@"org.mozilla.geckoview.SELECT_ALL"]) {
        return [[UIMenuItem alloc] initWithTitle:@"全选"
                                          action:@selector(gg_geckoSelectionSelectAll:)];
    }
    return nil;
}

static CGRect GGSelectionMenuAnchorRect(UIView *view, NSDictionary *message) {
    NSDictionary *screenRect = [message[@"screenRect"] isKindOfClass:NSDictionary.class]
        ? message[@"screenRect"] : nil;
    if (screenRect) {
        CGFloat left = [screenRect[@"left"] doubleValue];
        CGFloat top = [screenRect[@"top"] doubleValue];
        CGFloat right = [screenRect[@"right"] doubleValue];
        CGFloat bottom = [screenRect[@"bottom"] doubleValue];
        CGRect rect = CGRectMake(left, top, MAX(1.0, right - left),
                                 MAX(1.0, bottom - top));
        UIWindow *window = view.window;
        if (window) {
            CGRect windowRect = [window convertRect:rect
                                 fromCoordinateSpace:window.screen.coordinateSpace];
            rect = [view convertRect:windowRect fromView:window];
        }
        if (!CGRectIsNull(rect) && !CGRectIsInfinite(rect) && !CGRectIsEmpty(rect)) {
            CGRect clipped = CGRectIntersection(rect, view.bounds);
            if (!CGRectIsNull(clipped) && !CGRectIsInfinite(clipped) &&
                !CGRectIsEmpty(clipped)) {
                return clipped;
            }
        }
    }
    return CGRectMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds), 1.0, 1.0);
}

static void GGShowSelectionActionMenu(GGHostEventDispatcher *dispatcher,
                                      UIView *view,
                                      NSDictionary *message) {
    if (!dispatcher || !view || !message) { return; }
    void (^show)(void) = ^{
        NSArray *actions = [message[@"actions"] isKindOfClass:NSArray.class]
            ? message[@"actions"] : @[];
        if (!actions.count) {
            [[UIMenuController sharedMenuController] hideMenuFromView:view];
            return;
        }

        NSMutableArray<UIMenuItem *> *items = [NSMutableArray array];
        for (id value in actions) {
            if (![value isKindOfClass:NSString.class]) { continue; }
            UIMenuItem *item = GGSelectionMenuItemForAction((NSString *)value);
            if (item) { [items addObject:item]; }
        }
        if (!items.count) {
            [[UIMenuController sharedMenuController] hideMenuFromView:view];
            return;
        }

        GGSelectionActionContext *context = [[GGSelectionActionContext alloc] init];
        context.dispatcher = dispatcher;
        context.view = view;
        objc_setAssociatedObject(view, GGSelectionActionContextKey, context,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        BOOL wasFirstResponder = view.isFirstResponder;
        BOOL responderReady = wasFirstResponder || [view becomeFirstResponder];
        CGRect anchorRect = GGSelectionMenuAnchorRect(view, message);
        UIMenuController *menu = [UIMenuController sharedMenuController];
        menu.menuItems = items;
        NSLog(@"[GeminiGecko][Selection] show actions=%@ responder=%d rect=%@",
              actions, responderReady ? 1 : 0,
              NSStringFromCGRect(anchorRect));
        if (responderReady && view.window) {
            [menu showMenuFromView:view rect:anchorRect];
        }
    };
    if (NSThread.isMainThread) {
        show();
    } else {
        dispatch_async(dispatch_get_main_queue(), show);
    }
}

static void GGHideSelectionActionMenu(UIView *view, NSDictionary *message) {
    if (!view) { return; }
    void (^hide)(void) = ^{
        NSString *reason = [message[@"reason"] isKindOfClass:NSString.class]
            ? message[@"reason"] : @"(none)";
        NSLog(@"[GeminiGecko][Selection] hide reason=%@", reason);
        UIMenuController *menu = [UIMenuController sharedMenuController];
        [menu hideMenuFromView:view];
        menu.menuItems = nil;
        objc_setAssociatedObject(view, GGSelectionActionContextKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    if (NSThread.isMainThread) {
        hide();
    } else {
        dispatch_async(dispatch_get_main_queue(), hide);
    }
}

@interface GGBlockEventCallback : NSObject <EventCallback>
@property(nonatomic, copy, nullable) void (^completion)(BOOL success);
@end

@implementation GGBlockEventCallback
- (void)sendSuccess:(id)response {
    if (self.completion) {
        NSLog(@"[GeminiGecko][Storage] clear-data callback success response=%@",
              response ?: @"(none)");
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

@interface GGJSONEventCallback : NSObject <EventCallback>
@property(nonatomic, copy, nullable) void (^completion)(BOOL success,
                                                        NSString * _Nullable json);
@end

@implementation GGJSONEventCallback
- (void)sendSuccess:(id)response {
    if (!self.completion) { return; }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:response ?: @{}
                                                   options:0
                                                     error:&error];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!json.length || error) {
        NSLog(@"[GeminiGecko][Storage] JSON callback encode error=%@", error);
        self.completion(NO, nil);
    } else {
        self.completion(YES, json);
    }
    self.completion = nil;
}
- (void)sendError:(id)response {
    if (!self.completion) { return; }
    NSLog(@"[GeminiGecko][Storage] JSON callback error=%@", response ?: @"(none)");
    self.completion(NO, nil);
    self.completion = nil;
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
            @"GeminiGecko:StorageTrace",
            @"GeminiGecko:SafeLogoutRequested",
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
            @"GeckoView:ShowSelectionAction",
            @"GeckoView:HideSelectionAction",
            @"GeckoView:ExternalResponse",
            @"GeckoView:ExternalResponseProgress",
            @"GeckoView:ExternalResponseComplete",
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
    if ([type isEqualToString:@"GeminiGecko:StorageTrace"]) {
        NSLog(@"[GeminiGecko][StorageJS] stage=%@ flags=%@ base=%@ context=%@ origin=%@ code=%@ smart=%@ capacityKB=%@ error=%@",
              dictionary[@"stage"] ?: @"(none)",
              dictionary[@"flags"] ?: @"(none)",
              dictionary[@"baseDomain"] ?: @"(none)",
              dictionary[@"sessionContextId"] ?: @"(shared)",
              dictionary[@"origin"] ?: @"(none)",
              dictionary[@"resultCode"] ?: @"(none)",
              dictionary[@"smartSizeEnabled"] ?: @"(none)",
              dictionary[@"capacityKB"] ?: @"(none)",
              dictionary[@"error"] ?: @"(none)");
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
        [type isEqualToString:@"GeckoView:Reload"] ||
        [type isEqualToString:@"GeckoView:ClearData"]) {
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
    // ChatWeb's production candidate opens Gemini without the `remote` chrome
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
    bool hasNonBlankPageLoadInProgress;
};

static NSDictionary *GGUserAgentSettingsDictionary(
    const GGGeckoUserAgentSettings *settings) {
    if (!settings || !settings->user_agent_utf8 || !settings->platform_utf8 ||
        !settings->app_version_utf8 || !settings->oscpu_utf8) {
        return nil;
    }

    NSString *userAgent = [NSString stringWithUTF8String:settings->user_agent_utf8];
    NSString *platform = [NSString stringWithUTF8String:settings->platform_utf8];
    NSString *appVersion = [NSString stringWithUTF8String:settings->app_version_utf8];
    NSString *oscpu = [NSString stringWithUTF8String:settings->oscpu_utf8];
    if (!userAgent.length || !platform.length || !appVersion.length || !oscpu.length) {
        return nil;
    }

    return @{
        @"userAgentMode": @0,
        @"userAgentOverride": userAgent,
        @"platformOverride": platform,
        @"appVersionOverride": appVersion,
        @"oscpuOverride": oscpu,
        @"viewportMode": settings->use_desktop_viewport ? @1 : @0,
    };
}

static BOOL GGContentSettingsAreValid(const GGGeckoContentSettings *settings) {
    if (!settings || !(settings->text_zoom >= 0.5 && settings->text_zoom <= 3.0)) {
        return NO;
    }
    if (settings->autoplay_default != 0 && settings->autoplay_default != 1 &&
        settings->autoplay_default != 5) {
        return NO;
    }
    return settings->cookie_behavior == 0 || settings->cookie_behavior == 1 ||
        settings->cookie_behavior == 5;
}

static NSDictionary *GGContentSessionSettingsDictionary(
    const GGGeckoContentSettings *settings) {
    if (!GGContentSettingsAreValid(settings)) { return nil; }
    return @{
        @"textZoom": @(settings->text_zoom),
        @"suspendMediaWhenInactive": @(settings->suspend_media_when_inactive),
        @"useTrackingProtection": @(settings->use_tracking_protection),
    };
}

static NSDictionary *GGContentRuntimePrefsDictionary(
    const GGGeckoContentSettings *settings) {
    if (!GGContentSettingsAreValid(settings)) { return nil; }
    return @{
        @"autoplayDefault": @(settings->autoplay_default),
        @"cookieBehavior": @(settings->cookie_behavior),
        @"trackingProtectionEnabled": @(settings->use_tracking_protection),
        @"strictTrackingListEnabled": @(settings->use_strict_tracking_list),
    };
}

static GGHostRuntimeAdapter *gRuntimeAdapter;
static BOOL gBootstrapEntered = NO;
static NSString *gProcessProfilePath;
static NSString * const GGDiskCacheSmartSizeDefaultsKey = @"geckoDiskCacheSmartSizeEnabled";
static NSString * const GGDiskCacheCapacityDefaultsKey = @"geckoDiskCacheCapacityKB";
static NSString * const GGAutoplayDefaultsKey = @"webAutoplayPolicy";
static NSString * const GGPrivacyProtectionDefaultsKey = @"webPrivacyProtectionLevel";

static unsigned long long GGDirectorySizeAtPath(NSString *path) {
    if (!path.length) { return 0; }
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDirectory]) { return 0; }
    if (!isDirectory) {
        return [[fm attributesOfItemAtPath:path error:nil] fileSize];
    }

    unsigned long long total = 0;
    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:path];
    for (NSString *relativePath in enumerator) {
        NSString *itemPath = [path stringByAppendingPathComponent:relativePath];
        NSDictionary<NSFileAttributeKey, id> *attributes =
            [fm attributesOfItemAtPath:itemPath error:nil];
        if ([attributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
            total += [attributes fileSize];
        }
    }
    return total;
}

static void GGLogProfileDiskUsage(NSString *stage) {
    NSString *profile = gProcessProfilePath;
    if (!profile.length) { return; }
    unsigned long long profileBytes = GGDirectorySizeAtPath(profile);
    unsigned long long cache2Bytes =
        GGDirectorySizeAtPath([profile stringByAppendingPathComponent:@"cache2"]);
    unsigned long long storageBytes =
        GGDirectorySizeAtPath([profile stringByAppendingPathComponent:@"storage"]);
    unsigned long long startupCacheBytes =
        GGDirectorySizeAtPath([profile stringByAppendingPathComponent:@"startupCache"]);
    NSLog(@"[GeminiGecko][StorageDisk] stage=%@ profile=%llu cache2=%llu storage=%llu startupCache=%llu path=%@",
          stage ?: @"(none)", profileBytes, cache2Bytes, storageBytes,
          startupCacheBytes, profile);
}

static void GGInstallUIKitCachePolicy(NSString *profilePath) {
    // This dedicated iOS profile must not inherit desktop Firefox's roughly
    // 250 MiB smart-sized HTTP cache. The app exposes both values as live
    // settings; mirror the persisted app preference into user.js before Gecko
    // starts so the chosen policy survives relaunches.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL smartSizeEnabled = [defaults objectForKey:GGDiskCacheSmartSizeDefaultsKey]
        ? [defaults boolForKey:GGDiskCacheSmartSizeDefaultsKey]
        : NO;
    NSInteger capacityKB = [defaults objectForKey:GGDiskCacheCapacityDefaultsKey]
        ? [defaults integerForKey:GGDiskCacheCapacityDefaultsKey]
        : 32 * 1024;
    capacityKB = MAX(0, capacityKB);
    NSInteger autoplayDefault = [defaults objectForKey:GGAutoplayDefaultsKey]
        ? [defaults integerForKey:GGAutoplayDefaultsKey]
        : 1;
    if (autoplayDefault != 0 && autoplayDefault != 1 && autoplayDefault != 5) {
        autoplayDefault = 1;
    }
    NSInteger privacyLevel = [defaults objectForKey:GGPrivacyProtectionDefaultsKey]
        ? [defaults integerForKey:GGPrivacyProtectionDefaultsKey]
        : 1;
    if (privacyLevel != 0 && privacyLevel != 1 && privacyLevel != 2) {
        privacyLevel = 1;
    }
    NSInteger cookieBehavior = privacyLevel == 0 ? 0 : (privacyLevel == 2 ? 1 : 5);
    BOOL trackingProtectionEnabled = privacyLevel != 0;
    BOOL strictTrackingListEnabled = privacyLevel == 2;
    NSString *contentBlockingCategory = strictTrackingListEnabled ? @"strict" : @"standard";
    NSString *userJS = [NSString stringWithFormat:
        @"// Generated by ChatWeb. Apply persisted Gecko runtime policy.\n"
         "user_pref(\"browser.cache.disk.smart_size.enabled\", %@);\n"
         "user_pref(\"browser.cache.disk.capacity\", %ld);\n"
         "user_pref(\"media.autoplay.default\", %ld);\n"
         "user_pref(\"network.cookie.cookieBehavior\", %ld);\n"
         "user_pref(\"network.cookie.cookieBehavior.pbmode\", %ld);\n"
         "user_pref(\"privacy.trackingprotection.annotate_channels\", %@);\n"
         "user_pref(\"privacy.annotate_channels.strict_list.enabled\", %@);\n"
         "user_pref(\"browser.contentblocking.category\", \"%@\");\n",
        smartSizeEnabled ? @"true" : @"false", (long)capacityKB,
        (long)autoplayDefault, (long)cookieBehavior, (long)cookieBehavior,
        trackingProtectionEnabled ? @"true" : @"false",
        strictTrackingListEnabled ? @"true" : @"false",
        contentBlockingCategory];
    NSString *userJSPath = [profilePath stringByAppendingPathComponent:@"user.js"];
    NSError *error = nil;
    if (![userJS writeToFile:userJSPath
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:&error]) {
        NSLog(@"[GeminiGecko][StorageDisk] cache-policy write failed path=%@ error=%@",
              userJSPath, error);
    } else {
        NSLog(@"[GeminiGecko][StorageDisk] runtime-policy smart=%d capacityKB=%ld autoplay=%ld privacy=%ld path=%@",
              smartSizeEnabled ? 1 : 0, (long)capacityKB, (long)autoplayDefault,
              (long)privacyLevel, userJSPath);
    }
}

static NSString *GGStartupTracePath(void) {
    NSString *cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    [NSFileManager.defaultManager createDirectoryAtPath:cache
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return [cache stringByAppendingPathComponent:@"ChatWeb-GeckoStartup.log"];
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
        gProcessProfilePath = [profilePath copy];
        GGInstallUIKitCachePolicy(profilePath);
        GGLogProfileDiskUsage(@"startup-before-gecko");
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

static GGGeckoResult GGGeckoRuntimeSetDiskCachePrefs(
    GGGeckoRuntime *runtime,
    NSDictionary *message,
    void *context,
    GGGeckoOperationCallback callback) {
    if (!runtime || !runtime->adapter || !message.count) {
        return GGGeckoResultInvalidArgument;
    }

    GGBlockEventCallback *eventCallback = [[GGBlockEventCallback alloc] init];
    if (callback) {
        eventCallback.completion = ^(BOOL success) {
            callback(context, success);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (eventCallback.completion) {
                NSLog(@"[GeminiGecko][Storage] cache-prefs callback timeout message=%@",
                      message);
                eventCallback.completion(NO);
                eventCallback.completion = nil;
            }
        });
    }

    NSLog(@"[GeminiGecko][Storage] cache-prefs dispatch message=%@", message);
    [runtime->adapter.runtimeDispatcherImpl
        sendToGecko:@"GeminiGecko:SetCachePrefs"
             message:message
            callback:eventCallback];
    return GGGeckoResultOK;
}

GGGeckoResult GGGeckoRuntimeSetDiskCacheSmartSizeEnabled(
    GGGeckoRuntime *runtime,
    bool enabled,
    void *context,
    GGGeckoOperationCallback callback) {
    return GGGeckoRuntimeSetDiskCachePrefs(
        runtime,
        @{ @"smartSizeEnabled": @(enabled) },
        context,
        callback);
}

GGGeckoResult GGGeckoRuntimeSetDiskCacheCapacityKB(
    GGGeckoRuntime *runtime,
    uint32_t capacity_kb,
    void *context,
    GGGeckoOperationCallback callback) {
    if (capacity_kb > INT32_MAX) {
        return GGGeckoResultInvalidArgument;
    }
    return GGGeckoRuntimeSetDiskCachePrefs(
        runtime,
        @{ @"capacityKB": @(capacity_kb) },
        context,
        callback);
}

static GGGeckoResult GGGeckoRuntimeSetContentPrefs(
    GGGeckoRuntime *runtime,
    NSDictionary *message,
    void *context,
    GGGeckoOperationCallback callback) {
    if (!runtime || !runtime->adapter || !message.count) {
        return GGGeckoResultInvalidArgument;
    }

    GGBlockEventCallback *eventCallback = [[GGBlockEventCallback alloc] init];
    if (callback) {
        eventCallback.completion = ^(BOOL success) {
            callback(context, success);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (eventCallback.completion) {
                NSLog(@"[GeminiGecko][Settings] content-prefs callback timeout message=%@",
                      message);
                eventCallback.completion(NO);
                eventCallback.completion = nil;
            }
        });
    }

    NSLog(@"[GeminiGecko][Settings] content-prefs dispatch message=%@", message);
    [runtime->adapter.runtimeDispatcherImpl
        sendToGecko:@"GeminiGecko:SetContentPrefs"
             message:message
            callback:eventCallback];
    return GGGeckoResultOK;
}

GGGeckoResult GGGeckoRuntimeClearBaseDomainData(GGGeckoRuntime *runtime,
                                                const char *base_domain_utf8,
                                                uint32_t flags,
                                                const char *session_context_id_utf8,
                                                void *context,
                                                GGGeckoOperationCallback callback) {
    if (!runtime || !runtime->adapter || !base_domain_utf8 ||
        flags != GGGeckoClearDataCookies) {
        return GGGeckoResultInvalidArgument;
    }
    NSString *baseDomain = [NSString stringWithUTF8String:base_domain_utf8];
    if (!baseDomain.length) {
        return GGGeckoResultInvalidArgument;
    }

    GGBlockEventCallback *eventCallback = [[GGBlockEventCallback alloc] init];
    if (callback) {
        eventCallback.completion = ^(BOOL success) {
            callback(context, success);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (eventCallback.completion) {
                NSLog(@"[GeminiGecko][Storage] cookie-clear callback timeout base=%@",
                      baseDomain);
                eventCallback.completion(NO);
                eventCallback.completion = nil;
            }
        });
    }

    NSString *sessionContextId = session_context_id_utf8
        ? [NSString stringWithUTF8String:session_context_id_utf8]
        : nil;
    NSLog(@"[GeminiGecko][Storage] clear-cookies dispatch base=%@ flags=0x%x context=%@",
          baseDomain, flags, sessionContextId ?: @"(shared)");
    [runtime->adapter.runtimeDispatcherImpl
        sendToGecko:@"GeminiGecko:ClearCookies"
             message:@{
                 @"baseDomain": baseDomain,
                 @"sessionContextId": sessionContextId ?: NSNull.null,
             }
            callback:eventCallback];
    return GGGeckoResultOK;
}

GGGeckoResult GGGeckoRuntimeMigrateCookies(
    GGGeckoRuntime *runtime,
    const char *first_context_id_utf8,
    const char *second_context_id_utf8,
    bool to_shared,
    void *context,
    GGGeckoOperationCallback callback) {
    if (!runtime || !runtime->adapter || !first_context_id_utf8 ||
        !second_context_id_utf8) {
        return GGGeckoResultInvalidArgument;
    }

    NSString *firstContextId = [NSString stringWithUTF8String:first_context_id_utf8];
    NSString *secondContextId = [NSString stringWithUTF8String:second_context_id_utf8];
    if (!firstContextId.length || !secondContextId.length) {
        return GGGeckoResultInvalidArgument;
    }

    GGBlockEventCallback *eventCallback = [[GGBlockEventCallback alloc] init];
    if (callback) {
        eventCallback.completion = ^(BOOL success) {
            callback(context, success);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (eventCallback.completion) {
                NSLog(@"[GeminiGecko][Storage] cookie-migrate callback timeout");
                eventCallback.completion(NO);
                eventCallback.completion = nil;
            }
        });
    }

    NSString *mode = to_shared ? @"isolatedToShared" : @"sharedToIsolated";
    NSLog(@"[GeminiGecko][Storage] cookie-migrate dispatch mode=%@ contexts=%@,%@",
          mode, firstContextId, secondContextId);
    [runtime->adapter.runtimeDispatcherImpl
        sendToGecko:@"GeminiGecko:CloneSharedCookies"
             message:@{
                 @"contextIds": @[ firstContextId, secondContextId ],
                 @"mode": mode,
             }
            callback:eventCallback];
    return GGGeckoResultOK;
}

GGGeckoResult GGGeckoRuntimeExportCookies(
    GGGeckoRuntime *runtime,
    void *context,
    GGGeckoJSONCallback callback) {
    if (!runtime || !runtime->adapter || !callback) {
        return GGGeckoResultInvalidArgument;
    }

    GGJSONEventCallback *eventCallback = [[GGJSONEventCallback alloc] init];
    eventCallback.completion = ^(BOOL success, NSString *json) {
        callback(context, success, json.length ? json.UTF8String : nullptr);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (eventCallback.completion) {
            NSLog(@"[GeminiGecko][Storage] cookie-export callback timeout");
            eventCallback.completion(NO, nil);
            eventCallback.completion = nil;
        }
    });

    NSLog(@"[GeminiGecko][Storage] cookie-export dispatch");
    [runtime->adapter.runtimeDispatcherImpl
        sendToGecko:@"GeminiGecko:ExportCookies"
             message:@{}
            callback:eventCallback];
    return GGGeckoResultOK;
}

GGGeckoResult GGGeckoRuntimeImportCookies(
    GGGeckoRuntime *runtime,
    const char *json_utf8,
    void *context,
    GGGeckoOperationCallback callback) {
    if (!runtime || !runtime->adapter || !json_utf8) {
        return GGGeckoResultInvalidArgument;
    }
    NSString *json = [NSString stringWithUTF8String:json_utf8];
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id snapshot = jsonData
        ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error]
        : nil;
    if (!snapshot || error) {
        NSLog(@"[GeminiGecko][Storage] cookie-import invalid JSON error=%@", error);
        return GGGeckoResultInvalidArgument;
    }

    GGBlockEventCallback *eventCallback = [[GGBlockEventCallback alloc] init];
    if (callback) {
        eventCallback.completion = ^(BOOL success) {
            callback(context, success);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (eventCallback.completion) {
                NSLog(@"[GeminiGecko][Storage] cookie-import callback timeout");
                eventCallback.completion(NO);
                eventCallback.completion = nil;
            }
        });
    }

    NSLog(@"[GeminiGecko][Storage] cookie-import dispatch");
    [runtime->adapter.runtimeDispatcherImpl
        sendToGecko:@"GeminiGecko:ImportCookies"
             message:@{ @"snapshot": snapshot }
            callback:eventCallback];
    return GGGeckoResultOK;
}

void GGGeckoRuntimeDestroy(GGGeckoRuntime *runtime) {
    delete runtime;
}

GGGeckoResult GGGeckoSessionCreate(GGGeckoRuntime *runtime,
                                   const GGGeckoSessionCallbacks *callbacks,
                                   const char *session_context_id_utf8,
                                   const GGGeckoUserAgentSettings *user_agent_settings,
                                   const GGGeckoContentSettings *content_settings,
                                   GGGeckoSession **out_session) {
    GGGeckoStartupTrace("session-create.enter");
    NSDictionary *userAgentSettings =
        GGUserAgentSettingsDictionary(user_agent_settings);
    NSDictionary *contentSessionSettings =
        GGContentSessionSettingsDictionary(content_settings);
    NSDictionary *contentRuntimePrefs =
        GGContentRuntimePrefsDictionary(content_settings);
    if (!runtime || !callbacks || !out_session || !userAgentSettings ||
        !contentSessionSettings || !contentRuntimePrefs ||
        !NSThread.isMainThread) {
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
    session->hasNonBlankPageLoadInProgress = false;

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
                rawSession->hasNonBlankPageLoadInProgress = true;
                GGSendUTF8(rawSession->callbacks.did_commit_url,
                           rawSession->callbacks.context,
                           pageURI);
            }
            if (rawSession->hasNonBlankPageLoadInProgress &&
                rawSession->callbacks.did_change_progress) {
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
            if (rawSession->hasNonBlankPageLoadInProgress &&
                rawSession->callbacks.did_change_progress) {
                rawSession->callbacks.did_change_progress(rawSession->callbacks.context, 1.0);
            }
            rawSession->hasNonBlankPageLoadInProgress = false;
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
        if ([type isEqualToString:@"GeminiGecko:SafeLogoutRequested"]) {
            NSLog(@"[GeminiGecko][Auth] safe-logout request intercepted uri=%@",
                  message[@"uri"] ?: @"(none)");
            if (rawSession->callbacks.did_request_safe_logout) {
                rawSession->callbacks.did_request_safe_logout(
                    rawSession->callbacks.context);
            }
            return @YES;
        }
        if ([type isEqualToString:@"GeckoView:OnLoadRequest"]) {
            NSString *uri = [message[@"uri"] isKindOfClass:NSString.class]
                ? message[@"uri"] : @"";
            BOOL userInitiated = [message[@"hasUserGesture"] boolValue] ||
                [message[@"isUserInitiatedNavigation"] boolValue];
            BOOL openExternally = NO;
            if (uri.length && rawSession->callbacks.should_open_external_url) {
                openExternally = rawSession->callbacks.should_open_external_url(
                    rawSession->callbacks.context,
                    uri.UTF8String,
                    false,
                    userInitiated);
            }
            NSLog(@"[GeminiGecko][Nav] load-request uri=%@ user=%d external=%d",
                  uri ?: @"(none)", userInitiated ? 1 : 0,
                  openExternally ? 1 : 0);
            if (openExternally) {
                // LoadURIDelegate's result means "the embedder handled it".
                // YES aborts Gecko's own navigation after we hand the URL to
                // the temporary browser/system browser; NO lets Gecko load it.
                return @YES;
            }
            return @NO;
        }
        if ([type isEqualToString:@"GeckoView:OnNewSession"]) {
            NSString *uri = [message[@"uri"] isKindOfClass:NSString.class]
                ? message[@"uri"] : @"";
            BOOL userInitiated = [message[@"hasUserGesture"] boolValue] ||
                [message[@"isUserInitiatedNavigation"] boolValue];
            BOOL handedOff = NO;
            if (uri.length && rawSession->callbacks.should_open_external_url) {
                handedOff = rawSession->callbacks.should_open_external_url(
                    rawSession->callbacks.context,
                    uri.UTF8String,
                    true,
                    userInitiated);
            }
            NSLog(@"[GeminiGecko][Nav] new-session uri=%@ user=%d handedOff=%d",
                  uri ?: @"(none)", userInitiated ? 1 : 0,
                  handedOff ? 1 : 0);
            return @NO;
        }
        if ([type isEqualToString:@"GeckoView:ShowSelectionAction"]) {
            NSLog(@"[GeminiGecko][Selection] event actions=%@ collapsed=%@ editable=%@ rect=%@",
                  message[@"actions"] ?: @[], message[@"collapsed"] ?: @"(none)",
                  message[@"editable"] ?: @"(none)", message[@"screenRect"] ?: @"(none)");
            UIView *view = rawSession->window ? [rawSession->window view] : nil;
            GGShowSelectionActionMenu(rawSession->dispatcher, view, message ?: @{});
            return nil;
        }
        if ([type isEqualToString:@"GeckoView:HideSelectionAction"]) {
            UIView *view = rawSession->window ? [rawSession->window view] : nil;
            GGHideSelectionActionMenu(view, message ?: @{});
            return nil;
        }
        if ([type isEqualToString:@"GeckoView:ExternalResponse"]) {
            NSString *url = [message[@"url"] isKindOfClass:NSString.class]
                ? message[@"url"] : @"";
            NSString *path = [message[@"localFilePath"] isKindOfClass:NSString.class]
                ? message[@"localFilePath"] : @"";
            NSString *filename = [message[@"filename"] isKindOfClass:NSString.class]
                ? message[@"filename"] : @"";
            NSString *mimeType = [message[@"mimeType"] isKindOfClass:NSString.class]
                ? message[@"mimeType"] : @"";
            int64_t contentLength = [message[@"contentLength"] respondsToSelector:@selector(longLongValue)]
                ? [message[@"contentLength"] longLongValue] : -1;
            BOOL downloadInApp = YES;
            if (url.length && path.length && rawSession->callbacks.should_download_in_app) {
                downloadInApp = rawSession->callbacks.should_download_in_app(
                    rawSession->callbacks.context,
                    url.UTF8String,
                    path.UTF8String,
                    filename.length ? filename.UTF8String : nullptr,
                    mimeType.length ? mimeType.UTF8String : nullptr,
                    contentLength);
            }
            NSLog(@"[GeminiGecko][Download] begin url=%@ file=%@ mime=%@ bytes=%lld path=%@ inApp=%d",
                  url.length ? url : @"(none)",
                  filename.length ? filename : @"(none)",
                  mimeType.length ? mimeType : @"(none)",
                  contentLength,
                  path.length ? path : @"(none)",
                  downloadInApp ? 1 : 0);
            if (!downloadInApp) {
                // ExternalResponseService interprets false as cancel. The
                // Swift layer has already handed the original URL to the
                // system browser, so discard the temporary capture here.
                return @NO;
            }
            if (path.length && rawSession->callbacks.did_begin_download) {
                rawSession->callbacks.did_begin_download(
                    rawSession->callbacks.context,
                    path.UTF8String,
                    filename.length ? filename.UTF8String : nullptr,
                    mimeType.length ? mimeType.UTF8String : nullptr,
                    contentLength);
            }
            // ExternalResponseService suspends the channel until this boolean
            // decision arrives. Returning nil cancels every attachment.
            return @YES;
        }
        if ([type isEqualToString:@"GeckoView:ExternalResponseProgress"]) {
            return @YES;
        }
        if ([type isEqualToString:@"GeckoView:ExternalResponseComplete"]) {
            NSString *path = [message[@"localFilePath"] isKindOfClass:NSString.class]
                ? message[@"localFilePath"] : @"";
            BOOL success = [message[@"succeeded"] boolValue];
            NSLog(@"[GeminiGecko][Download] complete success=%d path=%@",
                  success ? 1 : 0, path.length ? path : @"(none)");
            if (path.length && rawSession->callbacks.did_complete_download) {
                rawSession->callbacks.did_complete_download(
                    rawSession->callbacks.context,
                    path.UTF8String,
                    success);
            }
            return nil;
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

    NSString *sessionContextId = session_context_id_utf8
        ? [NSString stringWithUTF8String:session_context_id_utf8]
        : nil;
    if (session_context_id_utf8 && !sessionContextId.length) {
        GGGeckoStartupTrace("session-create.invalid-context-id");
        return GGGeckoResultInvalidArgument;
    }

    NSMutableDictionary *settings = [@{
        @"chromeUri": NSNull.null,
        @"screenId": @0,
        @"displayMode": @0,
        @"allowJavascript": @YES,
        @"fullAccessibilityTree": @NO,
        @"isPopup": @NO,
        @"sessionContextId": sessionContextId ?: NSNull.null,
        @"unsafeSessionContextId": NSNull.null,
    } mutableCopy];
    [settings addEntriesFromDictionary:userAgentSettings];
    [settings addEntriesFromDictionary:contentSessionSettings];
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
    // Selection UI is owned by Gecko's UITextInteraction implementation now.
    // Do not install the old bridge-level long-press fallback here: it adds a
    // second UILongPressGestureRecognizer and posts delayed UIMenuController
    // presentations, which can race a native selection ending/collapsing.
    GGGeckoStartupTrace("session-create.GeckoViewOpenWindow-ok");
    NSLog(@"[GeminiGecko] GeckoView window ready");

    GGGeckoRuntimeSetContentPrefs(runtime, contentRuntimePrefs, nullptr, nullptr);

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

GGGeckoResult GGGeckoSessionExportConversationMarkdown(
    GGGeckoSession *session,
    void *context,
    GGGeckoJSONCallback callback) {
    if (!session || !callback || !NSThread.isMainThread) {
        return GGGeckoResultInvalidArgument;
    }

    GGJSONEventCallback *eventCallback = [[GGJSONEventCallback alloc] init];
    eventCallback.completion = ^(BOOL success, NSString *json) {
        callback(context, success, json.length ? json.UTF8String : nullptr);
    };
    NSLog(@"[GeminiGecko][Export] conversation-markdown dispatch");
    [session->dispatcher sendToGecko:@"ChatWeb:ExportConversationMarkdown"
                             message:@{}
                            callback:eventCallback];
    return GGGeckoResultOK;
}

GGGeckoResult GGGeckoSessionSetUserAgentSettings(
    GGGeckoSession *session,
    const GGGeckoUserAgentSettings *settings) {
    NSDictionary *message = GGUserAgentSettingsDictionary(settings);
    if (!session || !message || !NSThread.isMainThread) {
        return GGGeckoResultInvalidArgument;
    }
    NSLog(@"[GeminiGecko][UA] update platform=%@ desktop=%@",
          message[@"platformOverride"],
          [message[@"viewportMode"] boolValue] ? @"yes" : @"no");
    [session->dispatcher sendToGecko:@"GeckoView:UpdateSettings"
                             message:message];
    return GGGeckoResultOK;
}

GGGeckoResult GGGeckoSessionSetContentSettings(
    GGGeckoSession *session,
    const GGGeckoContentSettings *settings,
    void *context,
    GGGeckoOperationCallback callback) {
    NSDictionary *sessionMessage = GGContentSessionSettingsDictionary(settings);
    NSDictionary *runtimeMessage = GGContentRuntimePrefsDictionary(settings);
    if (!session || !sessionMessage || !runtimeMessage || !NSThread.isMainThread) {
        return GGGeckoResultInvalidArgument;
    }
    NSLog(@"[GeminiGecko][Settings] content update textZoom=%@ autoplay=%@ suspend=%@ cookie=%@ tracking=%@ strict=%@",
          sessionMessage[@"textZoom"], runtimeMessage[@"autoplayDefault"],
          sessionMessage[@"suspendMediaWhenInactive"], runtimeMessage[@"cookieBehavior"],
          sessionMessage[@"useTrackingProtection"],
          runtimeMessage[@"strictTrackingListEnabled"]);
    [session->dispatcher sendToGecko:@"GeckoView:UpdateSettings"
                             message:sessionMessage];
    return GGGeckoRuntimeSetContentPrefs(
        session->runtime, runtimeMessage, context, callback);
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
                                      const char *base_domain_utf8,
                                      const char *session_context_id_utf8,
                                      void *context,
                                      GGGeckoOperationCallback callback) {
    if (!runtime || !runtime->adapter || flags == 0 || !base_domain_utf8) {
        return GGGeckoResultInvalidArgument;
    }
    NSString *baseDomain = [NSString stringWithUTF8String:base_domain_utf8];
    if (!baseDomain.length) {
        return GGGeckoResultInvalidArgument;
    }

    GGBlockEventCallback *eventCallback = [[GGBlockEventCallback alloc] init];
    if (callback) {
        eventCallback.completion = ^(BOOL success) {
            GGLogProfileDiskUsage(success ? @"clear-callback-success"
                                               : @"clear-callback-failure");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                GGLogProfileDiskUsage(@"clear-settled-2s");
            });
            callback(context, success);
        };
        // A Gecko listener is allowed to complete asynchronously, but the UI
        // must never remain in an indeterminate state forever if an internal
        // cleaner wedges. The callback object is retained by the Gecko bridge
        // while the dispatch is outstanding, so this timeout can safely clear
        // the one-shot completion without risking a double callback if Gecko
        // eventually responds later.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(60 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (eventCallback.completion) {
                NSLog(@"[GeminiGecko][Storage] direct-clear callback timeout");
                eventCallback.completion(NO);
                eventCallback.completion = nil;
            }
        });
    }

    NSString *sessionContextId = session_context_id_utf8
        ? [NSString stringWithUTF8String:session_context_id_utf8]
        : nil;
    NSLog(@"[GeminiGecko][Storage] direct-clear dispatch flags=0x%x base=%@ context=%@",
          flags, baseDomain, sessionContextId ?: @"(shared)");
    GGLogProfileDiskUsage(@"clear-before-dispatch");
    [runtime->adapter.runtimeDispatcherImpl
        sendToGecko:@"GeminiGecko:ClearData"
             message:@{
                 @"flags": @(flags),
                 @"baseDomain": baseDomain,
                 @"sessionContextId": sessionContextId ?: NSNull.null,
             }
            callback:eventCallback];
    return GGGeckoResultOK;
}
