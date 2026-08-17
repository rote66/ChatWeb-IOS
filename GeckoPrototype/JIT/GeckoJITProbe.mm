#import "GeckoJITProbe.h"

#include <sys/mman.h>
#include <unistd.h>

GeckoJITPreflightResult GeckoJITPreflight(void) {
    long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize <= 0) {
        return GeckoJITPreflightResultUnavailable;
    }

    void *page = mmap(NULL,
                      (size_t)pageSize,
                      PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANON,
                      -1,
                      0);
    if (page == MAP_FAILED) {
        return GeckoJITPreflightResultUnavailable;
    }

    int result = mprotect(page, (size_t)pageSize, PROT_READ | PROT_EXEC);
    munmap(page, (size_t)pageSize);
    return result == 0
        ? GeckoJITPreflightResultExecutablePageTransitionAvailable
        : GeckoJITPreflightResultUnavailable;
}
