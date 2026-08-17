#import <Foundation/Foundation.h>

#include <execinfo.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <syslog.h>
#include <unistd.h>

#import "../GeckoPrototype/Bridge/GeminiGeckoCAPI.h"

static volatile sig_atomic_t gGGHandlingFatalSignal = 0;

extern "C" void *__mmap(void *addr,
                         size_t len,
                         int prot,
                         int flags,
                         int fd,
                         off_t offset);

static bool GGProbeJITExecutableMemory(int *outErrno) {
    static constexpr size_t kProbeBytes = 140ull * 1024ull * 1024ull;
    const int flags = MAP_NORESERVE | MAP_PRIVATE | MAP_ANON;

    errno = 0;
    void *mapping = __mmap(nullptr,
                           kProbeBytes,
                           PROT_READ | PROT_EXEC,
                           flags,
                           -1,
                           0);
    if (mapping == MAP_FAILED) {
        if (outErrno) { *outErrno = errno; }
        return false;
    }

    errno = 0;
    const int writableResult = mprotect(mapping,
                                        kProbeBytes,
                                        PROT_READ | PROT_WRITE);
    const int writableErrno = errno;

    errno = 0;
    const int executableResult = writableResult == 0
        ? mprotect(mapping, kProbeBytes, PROT_READ | PROT_EXEC)
        : -1;
    const int executableErrno = errno;

    munmap(mapping, kProbeBytes);

    if (writableResult != 0 || executableResult != 0) {
        if (outErrno) {
            *outErrno = writableResult != 0 ? writableErrno : executableErrno;
        }
        return false;
    }

    if (outErrno) { *outErrno = 0; }
    return true;
}

static bool GGWaitForJITExecutableMemory(void) {
    static constexpr int kAttempts = 60;
    static constexpr useconds_t kDelayMicros = 50 * 1000;

    int lastErrno = 0;
    for (int attempt = 1; attempt <= kAttempts; ++attempt) {
        if (GGProbeJITExecutableMemory(&lastErrno)) {
            syslog(LOG_NOTICE,
                   "[GeminiGecko][JITGate] ready attempt=%d elapsed_ms=%d",
                   attempt,
                   (attempt - 1) * 50);
            return true;
        }

        if (attempt == 1) {
            syslog(LOG_NOTICE,
                   "[GeminiGecko][JITGate] waiting errno=%d",
                   lastErrno);
        }

        if (attempt != kAttempts) {
            usleep(kDelayMicros);
        }
    }

    syslog(LOG_NOTICE,
           "[GeminiGecko][JITGate] timeout errno=%d elapsed_ms=%d",
           lastErrno,
           (kAttempts - 1) * 50);
    return false;
}

static void GGFatalSignalHandler(int signalNumber, siginfo_t *info, void *context) {
    (void)context;

    if (gGGHandlingFatalSignal) {
        _exit(128 + signalNumber);
    }
    gGGHandlingFatalSignal = 1;

    void *frames[64] = {};
    const int frameCount = backtrace(frames, 64);
    syslog(LOG_ERR,
           "[GeminiGecko][Crash] signal=%d fault=%p frames=%d",
           signalNumber,
           info ? info->si_addr : nullptr,
           frameCount);

    char **symbols = backtrace_symbols(frames, frameCount);
    if (symbols) {
        for (int index = 0; index < frameCount; ++index) {
            syslog(LOG_ERR,
                   "[GeminiGecko][Crash] #%02d %s",
                   index,
                   symbols[index]);
        }
    }

    // SA_RESETHAND restored the default disposition before this handler ran.
    // Re-raise the original signal so iOS still writes its normal .ips report.
    kill(getpid(), signalNumber);
    _exit(128 + signalNumber);
}

static void GGInstallFatalSignalDiagnostics(void) {
    openlog("DualAI", LOG_PID | LOG_NDELAY, LOG_USER);

    struct sigaction action = {};
    action.sa_sigaction = GGFatalSignalHandler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;

    const int fatalSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT};
    for (int fatalSignal : fatalSignals) {
        sigaction(fatalSignal, &action, nullptr);
    }
}

int main(int argc, char *argv[]) {
    GGInstallFatalSignalDiagnostics();
    @autoreleasepool {
        GGGeckoStartupTraceReset();
        GGGeckoStartupTrace("main.enter");

        const bool jitReady = GGWaitForJITExecutableMemory();
        GGGeckoStartupTrace(jitReady
                                ? "main.jit-gate.ready"
                                : "main.jit-gate.timeout");

        NSArray<NSURL *> *applicationSupportURLs =
            [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                   inDomains:NSUserDomainMask];
        NSURL *applicationSupportURL = applicationSupportURLs.firstObject;
        if (!applicationSupportURL) {
            GGGeckoStartupTrace("main.no-application-support");
            return 70;
        }

        NSURL *profileURL = [applicationSupportURL
            URLByAppendingPathComponent:@"GeminiGeckoProfile"
                             isDirectory:YES];
        GGGeckoStartupTrace("main.profile-path-ready");
        GGGeckoStartupTrace("main.call-GGGeckoApplicationMain");
        return GGGeckoApplicationMain(argc, argv, profileURL.path.UTF8String);
    }
}
