#ifndef GEMINI_GECKO_CAPI_H
#define GEMINI_GECKO_CAPI_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GGGeckoRuntime GGGeckoRuntime;
typedef struct GGGeckoSession GGGeckoSession;

typedef enum GGGeckoResult {
    GGGeckoResultOK = 0,
    GGGeckoResultInvalidArgument = 1,
    GGGeckoResultRuntimeFailure = 2,
    GGGeckoResultSessionFailure = 3,
    GGGeckoResultNotLinked = 4,
} GGGeckoResult;

typedef enum GGGeckoJITMode {
    GGGeckoJITModeDisabled = 0,
    GGGeckoJITModeRequired = 1,
} GGGeckoJITMode;

typedef enum GGGeckoJITState {
    GGGeckoJITStateUnresolved = 0,
    GGGeckoJITStateEnabled = 1,
    GGGeckoJITStateDegradedNoJIT = 2,
    GGGeckoJITStateFailed = 3,
} GGGeckoJITState;

typedef struct GGGeckoRuntimeOptions {
    const char *profile_path_utf8;
    GGGeckoJITMode jit_mode;
} GGGeckoRuntimeOptions;

typedef struct GGGeckoSessionCallbacks {
    void *context;
    void (*did_commit_url)(void *context, const char *url_utf8);
    void (*did_change_title)(void *context, const char *title_utf8);
    void (*did_change_progress)(void *context, double progress);
    void (*did_terminate_content_process)(void *context, int32_t reason);
    void (*did_change_jit_state)(void *context,
                                 GGGeckoJITState state,
                                 int32_t reason);
} GGGeckoSessionCallbacks;

/// Appends a synchronous startup breadcrumb to
/// Library/Caches/DualAI-GeckoStartup.log so launch failures can be localized
/// even when the process dies before the UI appears.
void GGGeckoStartupTrace(const char *stage_utf8);
void GGGeckoStartupTraceReset(void);

/// Starts Gecko/XPCOM and enters Gecko's UIKit application loop. This must be
/// called from the process entry point instead of UIApplicationMain. With the
/// current iOS Gecko port it normally does not return until application exit.
int GGGeckoApplicationMain(int argc,
                           char **argv,
                           const char *profile_path_utf8);

/// True after GGGeckoApplicationMain has installed the project-owned runtime
/// adapter and Gecko has begun process-wide startup.
bool GGGeckoRuntimeIsBootstrapped(void);

/// Implemented by the project-owned adapter compiled against the pinned Gecko
/// tree. Gecko C++ types must not cross this boundary.
GGGeckoResult GGGeckoRuntimeCreate(const GGGeckoRuntimeOptions *options,
                                   GGGeckoRuntime **out_runtime);
void GGGeckoRuntimeDestroy(GGGeckoRuntime *runtime);

GGGeckoResult GGGeckoSessionCreate(GGGeckoRuntime *runtime,
                                   const GGGeckoSessionCallbacks *callbacks,
                                   GGGeckoSession **out_session);
void GGGeckoSessionDestroy(GGGeckoSession *session);

/// Returns an unretained UIView pointer as `void *`. The session owns it.
void *GGGeckoSessionGetNativeView(GGGeckoSession *session);

GGGeckoResult GGGeckoSessionLoadURL(GGGeckoSession *session,
                                    const char *url_utf8);
void GGGeckoSessionReload(GGGeckoSession *session);
void GGGeckoSessionStop(GGGeckoSession *session);
void GGGeckoSessionGoBack(GGGeckoSession *session);
void GGGeckoSessionGoForward(GGGeckoSession *session);
bool GGGeckoSessionCanGoBack(GGGeckoSession *session);
bool GGGeckoSessionCanGoForward(GGGeckoSession *session);
void GGGeckoSessionSetActive(GGGeckoSession *session, bool active);
void GGGeckoSessionSetFocused(GGGeckoSession *session, bool focused);
void GGGeckoRuntimeEnterBackground(GGGeckoRuntime *runtime);
void GGGeckoRuntimeEnterForeground(GGGeckoRuntime *runtime);

#ifdef __cplusplus
}
#endif

#endif
