/* Host services shared by the Linux and macOS runtimes. */
#ifndef DS_PLATFORM_H
#define DS_PLATFORM_H
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#ifdef __APPLE__
#include <mach/mach_time.h>
#endif
static inline uint64_t ds_clock_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
/* Sleep to a monotonic deadline without a multi-millisecond busy spin. Recheck
 * after interrupts/early wakes; CLOCK_MONOTONIC and Mach need not share an epoch. */
static inline void ds_sleep_until_ns(uint64_t deadline) {
    for (;;) {
        uint64_t now = ds_clock_ns(); if (now >= deadline) return;
        uint64_t left = deadline - now;
#ifdef __APPLE__
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        uint64_t ticks = (uint64_t)((__uint128_t)left * tb.denom / tb.numer);
        mach_wait_until(mach_absolute_time() + ticks);
#else
        struct timespec ts = {(time_t)(left / 1000000000ull), (long)(left % 1000000000ull)};
        if (nanosleep(&ts, NULL) && errno != EINTR) return;
#endif
    }
}
static inline uint32_t ds_page_size(void) { return (uint32_t)sysconf(_SC_PAGESIZE); }
static inline uint32_t ds_cpu_count(void) {
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    return n < 1 ? 1 : n > 32 ? 32 : (uint32_t)n;
}
#endif
