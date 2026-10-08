/* Windows functions The Sims 2 Legacy Collection imports beyond what Dungeon Siege II and Fallout NV needed. The 2025
 * rebuild links a current MSVC runtime (wide-character file and locale calls, SRW locks, condition variables), Steam,
 * crashpad (named pipes, a child process, security descriptors) and WinINet telemetry. The game's own code needs the
 * Steam interfaces, files, cursors, monitors and rectangles; the rest gets "not available" answers. */
#include "w32.h"
#include <sys/stat.h>
#ifdef __linux__
#include <sys/random.h>
#endif
#include <ctype.h>
#include <time.h>
#include <unistd.h>

extern int w32_screen_w, w32_screen_h;
static uint32_t scratch(uint32_t n) { return heap_alloc(w32_process_heap, 8, n); }
static void unscratch(uint32_t p) { if (p) heap_free(w32_process_heap, p); }
static uint32_t ansi_of(uint32_t w)                    /* guest UTF-16 string -> new guest ANSI copy (0 for 0) */
{
    if (!w) return 0;
    int n = 0; while (rt_r16(G_MEM, w + 2 * (uint32_t)n)) n++;
    uint32_t a = scratch((uint32_t)n * 2 + 1);
    w32_wide_to_mb(0, GW(w), n, (uint8_t *)GP(a), n * 2); return a;
}
static uint32_t widen_n(uint32_t dst, const char *s, uint32_t cap)    /* ANSI -> guest UTF-16 in cap chars, terminated */
{
    if (!cap) return 0;
    int n = w32_mb_to_wide(0, (const uint8_t *)s, (int)strlen(s), (uint16_t *)GP(dst), (int)cap - 1);
    if (n < 0) n = 0;
    rt_w16(G_MEM, dst + 2 * (uint32_t)n, 0); return (uint32_t)n;
}
/* call an A-function with the wide string arguments in `mask` (bits = argument numbers) made ANSI */
#define VIA_ANSI(fn, mask) do { uint32_t tmp[8] = {0}; void fn(Ctx *); for (int k = 0; k < 8; k++) if ((mask) >> k & 1) { tmp[k] = ansi_of(ARG(k)); rt_w32(G_MEM, c->esp + 4 + 4 * k, tmp[k]); } \
    fn(c); for (int k = 0; k < 8; k++) unscratch(tmp[k]); } while (0)
/* an A-function that writes a string of up to `cap` chars into its buffer: run it on a scratch buffer, then widen.
 * buf_arg / cap_arg: the argument numbers of the buffer and its size */
static void via_ansi_out(Ctx *c, void (*fn)(Ctx *), int buf_arg, int cap_arg)
{
    uint32_t wbuf = ARG(buf_arg), cap = ARG(cap_arg), a = scratch(1024);
    rt_w32(G_MEM, c->esp + 4 + 4 * (uint32_t)buf_arg, a); rt_w32(G_MEM, c->esp + 4 + 4 * (uint32_t)cap_arg, 1023);
    fn(c);
    uint32_t n = c->eax;
    if (n && n < 1023) { if (n < cap) c->eax = widen_n(wbuf, GS(a), cap); else c->eax = n + 1; }   /* too small: the size needed */
    unscratch(a);
}

/* ---- kernel32: wide-character variants ---- */
IMPL(kernel32, CreateEventW) { VIA_ANSI(imp_kernel32_CreateEventA, 1 << 3); }
IMPL(kernel32, LoadLibraryW) { VIA_ANSI(imp_kernel32_LoadLibraryA, 1); }
IMPL(kernel32, LoadLibraryExW) { VIA_ANSI(imp_kernel32_LoadLibraryExA, 1); }
IMPL(kernel32, GetFileAttributesW) { VIA_ANSI(imp_kernel32_GetFileAttributesA, 1); }
IMPL(kernel32, SetEnvironmentVariableW) { VIA_ANSI(imp_kernel32_SetEnvironmentVariableA, 3); }
IMPL(kernel32, GetDriveTypeW) { RET(3, 1); }                                          /* DRIVE_FIXED */
/* found with GetProcAddress (by the game and its C runtime) */
IMPL(kernel32, CopyFileW) { VIA_ANSI(imp_kernel32_CopyFileA, 3); }
IMPL(kernel32, SetFileAttributesW) { VIA_ANSI(imp_kernel32_SetFileAttributesA, 1); }
IMPL(kernel32, GetDiskFreeSpaceExW) { VIA_ANSI(imp_kernel32_GetDiskFreeSpaceExA, 1); }
void imp_kernel32_GetWindowsDirectoryA(Ctx *), imp_kernel32_GetLongPathNameA(Ctx *);
IMPL(kernel32, GetWindowsDirectoryW) { via_ansi_out(c, imp_kernel32_GetWindowsDirectoryA, 0, 1); }
IMPL(kernel32, GetLongPathNameW)                       /* (short, long buffer, chars): the name as given */
{
    uint32_t src = ARG(0), dst = ARG(1), cap = ARG(2), n = 0;
    while (rt_r16(G_MEM, src + 2 * n)) n++;
    if (n + 1 > cap) RET(n + 1, 3);
    if (dst != src) memmove(GP(dst), GP(src), 2 * (size_t)(n + 1));
    RET(n, 3);
}
void imp_kernel32_GetCurrentDirectoryA(Ctx *), imp_kernel32_GetTempPathA(Ctx *), imp_kernel32_GetModuleFileNameA(Ctx *);
IMPL(kernel32, GetCurrentDirectoryW) { via_ansi_out(c, imp_kernel32_GetCurrentDirectoryA, 1, 0); }
IMPL(kernel32, GetTempPathW) { via_ansi_out(c, imp_kernel32_GetTempPathA, 1, 0); }
IMPL(kernel32, GetModuleFileNameW) { via_ansi_out(c, imp_kernel32_GetModuleFileNameA, 1, 2); }
IMPL(kernel32, GetFullPathNameW)                       /* (name, chars, buffer, *file part) */
{
    uint32_t name = ansi_of(ARG(0)), cap = ARG(1), wbuf = ARG(2), part = ARG(3), a = scratch(1024);
    void imp_kernel32_GetFullPathNameA(Ctx *);
    rt_w32(G_MEM, c->esp + 4, name); rt_w32(G_MEM, c->esp + 8, 1023); rt_w32(G_MEM, c->esp + 12, a); rt_w32(G_MEM, c->esp + 16, 0);
    imp_kernel32_GetFullPathNameA(c);
    uint32_t n = c->eax;
    if (n && n < 1023 && n < cap) {
        c->eax = widen_n(wbuf, GS(a), cap);
        if (part) { const char *s = GS(a), *b = strrchr(s, '\\'); uint32_t at = b ? (uint32_t)(b - s + 1) : 0;
                    rt_w32(G_MEM, part, s[at] ? wbuf + 2 * at : 0); }
    } else if (n) c->eax = n + 1;
    unscratch(name); unscratch(a);
}
static void file_time(uint32_t at, struct timespec ts)
{
    uint64_t t = ((uint64_t)ts.tv_sec + 11644473600ull) * 10000000ull + (uint64_t)ts.tv_nsec / 100;
    rt_w32(G_MEM, at, (uint32_t)t); rt_w32(G_MEM, at + 4, (uint32_t)(t >> 32));
}
#ifdef __linux__
#define st_birthtimespec st_ctim
#define st_atimespec st_atim
#define st_mtimespec st_mtim
#endif
IMPL(kernel32, GetFileAttributesExA)                   /* (name, level 0, WIN32_FILE_ATTRIBUTE_DATA *) */
{
    char host[2048]; struct stat st; uint32_t d = ARG(2);
    if (w32_host_path(GS(ARG(0)), host, sizeof host, 0) || stat(host, &st)) { w32_set_last_error(c, 2); RET(0, 3); }
    rt_w32(G_MEM, d, S_ISDIR(st.st_mode) ? 0x10 : 0x20);
    file_time(d + 4, st.st_birthtimespec); file_time(d + 12, st.st_atimespec); file_time(d + 20, st.st_mtimespec);
    rt_w32(G_MEM, d + 28, (uint32_t)((uint64_t)st.st_size >> 32)); rt_w32(G_MEM, d + 32, (uint32_t)st.st_size);
    RET(1, 3);
}
IMPL(kernel32, GetFileAttributesExW) { VIA_ANSI(imp_kernel32_GetFileAttributesExA, 1); }
IMPL(kernel32, FindFirstFileExW)                       /* (name, info level, data, search op, filter, flags): a plain search */
{
    void imp_kernel32_FindFirstFileW(Ctx *);
    rt_w32(G_MEM, c->esp + 8, ARG(2));
    imp_kernel32_FindFirstFileW(c); c->esp += 16;
}
IMPL(kernel32, MoveFileExA)                            /* (from, to, flags): rename replaces an existing file */
{
    void imp_kernel32_MoveFileA(Ctx *);
    imp_kernel32_MoveFileA(c); c->esp += 4;
}
IMPL(kernel32, MoveFileExW) { VIA_ANSI(imp_kernel32_MoveFileExA, 3); }
void imp_kernel32_GetDateFormatA(Ctx *), imp_kernel32_GetTimeFormatA(Ctx *);
static void date_time_w(Ctx *c, void (*fn)(Ctx *))    /* (lcid, flags, SYSTEMTIME *, format, buffer, chars) */
{
    uint32_t fmt = ansi_of(ARG(3)), wbuf = ARG(4), cap = ARG(5), a = scratch(256);
    rt_w32(G_MEM, c->esp + 16, fmt); rt_w32(G_MEM, c->esp + 20, cap ? a : 0); rt_w32(G_MEM, c->esp + 24, cap ? 255 : 0);
    fn(c);
    if (c->eax && cap) c->eax = widen_n(wbuf, GS(a), cap) + 1;
    unscratch(fmt); unscratch(a);
}
IMPL(kernel32, GetDateFormatW) { date_time_w(c, imp_kernel32_GetDateFormatA); }
IMPL(kernel32, GetTimeFormatW) { date_time_w(c, imp_kernel32_GetTimeFormatA); }
IMPL(kernel32, GetModuleHandleExW)                     /* (flags, name or address, *module) */
{
    uint32_t flags = ARG(0), what = ARG(1), out = ARG(2), m = 0;
    if (flags & 4) {                                   /* FROM_ADDRESS: the image that holds it */
        extern const struct rt_image { const char *name; uint32_t base, imp_first, imp_count; } rt_images[]; extern const unsigned rt_images_n;
        for (unsigned k = 0; k < rt_images_n; k++) if (rt_images[k].base <= what && rt_images[k].base > m) m = rt_images[k].base;
        if (!m) m = w32_image_base;
    } else {
        void imp_kernel32_GetModuleHandleW(Ctx *);
        uint32_t esp = c->esp; c->esp += 4;            /* the frame seen as GetModuleHandleW(name) */
        imp_kernel32_GetModuleHandleW(c); m = c->eax; c->esp = esp;
    }
    if (out) rt_w32(G_MEM, out, m);
    if (!m) w32_set_last_error(c, 126);
    RET(m != 0, 3);
}
IMPL(kernel32, LCMapStringEx)                          /* (locale name, flags, src, n, dst, n, version, reserved, param) */
{
    void imp_kernel32_LCMapStringW(Ctx *);
    rt_w32(G_MEM, c->esp + 4, 0x409);                   /* the LCID for the name; the rest are LCMapStringW's */
    imp_kernel32_LCMapStringW(c); c->esp += 12;
}
IMPL(kernel32, EnumSystemLocalesW) { RET(1, 2); }
IMPL(kernel32, FormatMessageW) { RET(0, 7); }

/* ---- kernel32: start-up of the newer C runtime ---- */
IMPL(kernel32, EncodePointer) { RET(ARG(0), 1); }
IMPL(kernel32, DecodePointer) { RET(ARG(0), 1); }
IMPL(kernel32, InitializeSListHead) { rt_w32(G_MEM, ARG(0), 0); rt_w32(G_MEM, ARG(0) + 4, 0); RET(0, 1); }
IMPL(kernel32, InitializeCriticalSectionEx)            /* (cs, spin count, flags) */
{
    void imp_kernel32_InitializeCriticalSection(Ctx *);
    imp_kernel32_InitializeCriticalSection(c); c->esp += 8; c->eax = 1;
}
IMPL(kernel32, GetStartupInfoW) { void imp_kernel32_GetStartupInfoA(Ctx *); imp_kernel32_GetStartupInfoA(c); }
IMPL(kernel32, GlobalSize) { RET(heap_size(w32_process_heap, ARG(0)), 1); }
IMPL(kernel32, SleepEx) { void imp_kernel32_Sleep(Ctx *); imp_kernel32_Sleep(c); c->esp += 4; c->eax = 0; }
IMPL(kernel32, SetThreadExecutionState) { RET(0x80000000u, 1); }
IMPL(kernel32, GetDiskFreeSpaceA)                      /* (root, sectors/cluster, bytes/sector, free clusters, clusters) */
{
    uint32_t v[4] = {8, 512, 0x00ffffffu, 0x00ffffffu};                              /* 64 GB free */
    for (int k = 0; k < 4; k++) if (ARG(k + 1)) rt_w32(G_MEM, ARG(k + 1), v[k]);
    RET(1, 5);
}
IMPL(kernel32, GetProcessTimes)                        /* (process, creation, exit, kernel, user) */
{
    for (int k = 1; k < 5; k++) if (ARG(k)) { rt_w32(G_MEM, ARG(k), 0); rt_w32(G_MEM, ARG(k) + 4, 0); }
    RET(1, 5);
}
IMPL(kernel32, TzSpecificLocalTimeToSystemTime)        /* (time zone (0: the current one), local SYSTEMTIME, UTC out) */
{
    uint32_t in = ARG(1), out = ARG(2);
    struct tm t = {0};
    t.tm_year = rt_r16(G_MEM, in) - 1900; t.tm_mon = rt_r16(G_MEM, in + 2) - 1; t.tm_mday = rt_r16(G_MEM, in + 6);
    t.tm_hour = rt_r16(G_MEM, in + 8); t.tm_min = rt_r16(G_MEM, in + 10); t.tm_sec = rt_r16(G_MEM, in + 12); t.tm_isdst = -1;
    time_t u = mktime(&t); struct tm g; gmtime_r(&u, &g);
    uint16_t v[8] = {(uint16_t)(g.tm_year + 1900), (uint16_t)(g.tm_mon + 1), (uint16_t)g.tm_wday, (uint16_t)g.tm_mday,
                     (uint16_t)g.tm_hour, (uint16_t)g.tm_min, (uint16_t)g.tm_sec, rt_r16(G_MEM, in + 14)};
    memcpy(GP(out), v, 16); RET(1, 3);
}
IMPL(kernel32, VerSetConditionMask)                    /* (ULONGLONG mask, type bits, condition) -> ULONGLONG */
{
    uint64_t m = (uint64_t)ARG(0) | (uint64_t)ARG(1) << 32; uint32_t type = ARG(2), cond = ARG(3) & 7;
    for (int k = 0; k < 8; k++) if (type >> k & 1) { m &= ~(7ull << (3 * k)); m |= (uint64_t)cond << (3 * k); }
    c->edx = (uint32_t)(m >> 32); RET((uint32_t)m, 4);
}
IMPL(kernel32, VerifyVersionInfoW) { RET(1, 4); }                                    /* Windows 10 satisfies every check */
IMPL(kernel32, FreeLibraryAndExitThread)               /* (module, exit code) */
{
    void imp_kernel32_ExitThread(Ctx *);
    rt_w32(G_MEM, c->esp + 4, ARG(1)); imp_kernel32_ExitThread(c);
}
IMPL(kernel32, QueueUserAPC) { RET(0, 3); }
IMPL(kernel32, LockFileEx) { RET(1, 6); }
IMPL(kernel32, UnlockFileEx) { RET(1, 5); }

/* ---- kernel32: slim reader/writer locks and condition variables (one guest word each). The lock word is 1 while
 * held; a condition variable's word counts wake-ups, and waiters sleep on one host condition until it moves. ---- */
static pthread_mutex_t cv_lock = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t cv_cond = PTHREAD_COND_INITIALIZER;
static void srw_lock(uint32_t a)
{
    uint32_t *w = (uint32_t *)GP(a);
    for (int spin = 0; ; spin++) {
        uint32_t z = 0;
        if (__atomic_compare_exchange_n(w, &z, 1, 0, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) return;
        if (spin < 64) sched_yield(); else usleep(50);
    }
}
static void srw_unlock(uint32_t a) { __atomic_store_n((uint32_t *)GP(a), 0, __ATOMIC_RELEASE); }
IMPL(kernel32, AcquireSRWLockExclusive) { srw_lock(ARG(0)); RET(0, 1); }
IMPL(kernel32, ReleaseSRWLockExclusive) { srw_unlock(ARG(0)); RET(0, 1); }
IMPL(kernel32, SleepConditionVariableSRW)              /* (cv, lock, ms, flags) */
{
    uint32_t cv = ARG(0), lock = ARG(1), ms = ARG(2); uint32_t *w = (uint32_t *)GP(cv);
    pthread_mutex_lock(&cv_lock);
    uint32_t gen = __atomic_load_n(w, __ATOMIC_ACQUIRE);
    srw_unlock(lock);
    int timed_out = 0;
    struct timespec dl; clock_gettime(CLOCK_REALTIME, &dl);
    if (ms != 0xffffffffu) { dl.tv_sec += ms / 1000; dl.tv_nsec += (long)(ms % 1000) * 1000000L; if (dl.tv_nsec >= 1000000000L) { dl.tv_sec++; dl.tv_nsec -= 1000000000L; } }
    while (__atomic_load_n(w, __ATOMIC_ACQUIRE) == gen && !timed_out)
        timed_out = ms == 0xffffffffu ? pthread_cond_wait(&cv_cond, &cv_lock) != 0 : pthread_cond_timedwait(&cv_cond, &cv_lock, &dl) != 0;
    pthread_mutex_unlock(&cv_lock);
    srw_lock(lock);
    if (timed_out && __atomic_load_n(w, __ATOMIC_ACQUIRE) == gen) { w32_set_last_error(c, 1460); RET(0, 4); }   /* ERROR_TIMEOUT */
    RET(1, 4);
}
IMPL(kernel32, WakeAllConditionVariable)
{
    pthread_mutex_lock(&cv_lock); __atomic_add_fetch((uint32_t *)GP(ARG(0)), 1, __ATOMIC_RELEASE);
    pthread_cond_broadcast(&cv_cond); pthread_mutex_unlock(&cv_lock); RET(0, 1);
}

/* ---- kernel32: events, change notifications ---- */
IMPL(kernel32, OpenEventA) { w32_set_last_error(c, 2); RET(0, 3); }
IMPL(kernel32, PulseEvent) { w32_event_signal(ARG(0), 1); w32_event_signal(ARG(0), 0); RET(1, 1); }
/* the Downloads folder watch: an event that never fires (new content is picked up at the next start) */
IMPL(kernel32, FindFirstChangeNotificationA) { RET(w32_event_new(1, 0), 3); }
IMPL(kernel32, FindNextChangeNotification) { RET(1, 1); }
IMPL(kernel32, FindCloseChangeNotification) { h_close(ARG(0)); RET(1, 1); }

/* ---- kernel32: crash reporter and console (crashpad's pipe and child process, the C runtime's console input) ---- */
IMPL(kernel32, CreateProcessW) { w32_set_last_error(c, 2); RET(0, 10); }
IMPL(kernel32, GetExitCodeProcess) { RET(0, 2); }
IMPL(kernel32, CreateNamedPipeW) { w32_set_last_error(c, 5); RET(0xffffffffu, 8); }
IMPL(kernel32, SetNamedPipeHandleState) { RET(0, 4); }
IMPL(kernel32, TransactNamedPipe) { RET(0, 7); }
IMPL(kernel32, WaitNamedPipeW) { w32_set_last_error(c, 2); RET(0, 2); }
IMPL(kernel32, FlushConsoleInputBuffer) { RET(0, 1); }
IMPL(kernel32, ReadConsoleInputW) { RET(0, 4); }
IMPL(kernel32, ReadConsoleW) { RET(0, 5); }
IMPL(kernel32, SetConsoleMode) { RET(0, 2); }

/* ---- advapi32: tokens and security descriptors (crashpad), random numbers ---- */
static uint32_t fake_sd(void) { return scratch(64); }
IMPL(advapi32, OpenProcessToken) { rt_w32(G_MEM, ARG(2), w32_event_new(1, 0)); RET(1, 3); }
IMPL(advapi32, OpenThreadToken) { w32_set_last_error(c, 1008); RET(0, 4); }           /* ERROR_NO_TOKEN */
IMPL(advapi32, DuplicateToken) { rt_w32(G_MEM, ARG(2), w32_event_new(1, 0)); RET(1, 3); }
IMPL(advapi32, AccessCheck)                            /* (sd, token, desired, mapping, privileges, length*, granted*, status*) */
{
    rt_w32(G_MEM, ARG(6), ARG(2)); rt_w32(G_MEM, ARG(7), 1); RET(1, 8);
}
IMPL(advapi32, AllocateAndInitializeSid) { rt_w32(G_MEM, ARG(10), scratch(16)); RET(1, 11); }
IMPL(advapi32, FreeSid) { unscratch(ARG(0)); RET(0, 1); }
IMPL(advapi32, GetLengthSid) { RET(12, 1); }
IMPL(advapi32, InitializeAcl) { RET(1, 3); }
IMPL(advapi32, AddAccessAllowedAce) { RET(1, 4); }
IMPL(advapi32, InitializeSecurityDescriptor) { memset(GP(ARG(0)), 0, 20); rt_w8(G_MEM, ARG(0), 1); RET(1, 2); }
IMPL(advapi32, IsValidSecurityDescriptor) { RET(1, 1); }
IMPL(advapi32, SetSecurityDescriptorDacl) { RET(1, 4); }
IMPL(advapi32, SetSecurityDescriptorGroup) { RET(1, 3); }
IMPL(advapi32, SetSecurityDescriptorOwner) { RET(1, 3); }
IMPL(advapi32, BuildExplicitAccessWithNameW) { memset(GP(ARG(0)), 0, 32); RET(0, 5); }
IMPL(advapi32, BuildSecurityDescriptorW)               /* (owner, group, n access, access, n audit, audit, old, *size, *new) */
{
    rt_w32(G_MEM, ARG(7), 64); rt_w32(G_MEM, ARG(8), fake_sd()); RET(0, 9);
}
IMPL(advapi32, ConvertStringSecurityDescriptorToSecurityDescriptorW)   /* (string, revision, *sd, *size) */
{
    rt_w32(G_MEM, ARG(2), fake_sd()); if (ARG(3)) rt_w32(G_MEM, ARG(3), 64); RET(1, 4);
}
IMPL(advapi32, SystemFunction036)                      /* RtlGenRandom(buffer, length) */
{
    uint8_t *p = GP(ARG(0)); size_t n = ARG(1);
#ifdef __APPLE__
    arc4random_buf(p, n); RET(1, 2);
#else
    size_t got = 0; while (got < n) { ssize_t r = getrandom(p + got, n - got, 0); if (r <= 0) break; got += (size_t)r; }
    RET(got == n, 2);
#endif
}

/* ---- user32 ---- */
IMPL(user32, IntersectRect)                            /* (dst, a, b) */
{
    int32_t a[4], b[4], r[4]; memcpy(a, GP(ARG(1)), 16); memcpy(b, GP(ARG(2)), 16);
    r[0] = a[0] > b[0] ? a[0] : b[0]; r[1] = a[1] > b[1] ? a[1] : b[1]; r[2] = a[2] < b[2] ? a[2] : b[2]; r[3] = a[3] < b[3] ? a[3] : b[3];
    int ok = r[0] < r[2] && r[1] < r[3]; if (!ok) memset(r, 0, 16);
    memcpy(GP(ARG(0)), r, 16); RET(ok, 3);
}
IMPL(user32, OffsetRect)
{
    int32_t r[4]; memcpy(r, GP(ARG(0)), 16); r[0] += (int32_t)ARG(1); r[2] += (int32_t)ARG(1); r[1] += (int32_t)ARG(2); r[3] += (int32_t)ARG(2);
    memcpy(GP(ARG(0)), r, 16); RET(1, 3);
}
IMPL(user32, CharLowerBuffA) { uint8_t *s = GP(ARG(0)); for (uint32_t k = 0; k < ARG(1); k++) s[k] = (uint8_t)tolower(s[k]); RET(ARG(1), 2); }
IMPL(user32, CharUpperBuffA) { uint8_t *s = GP(ARG(0)); for (uint32_t k = 0; k < ARG(1); k++) s[k] = (uint8_t)toupper(s[k]); RET(ARG(1), 2); }
IMPL(user32, GetAncestor) { RET(ARG(0), 2); }                                         /* the game's windows are top-level */
IMPL(user32, IsZoomed) { RET(0, 1); }
IMPL(user32, ValidateRect) { RET(1, 2); }
IMPL(user32, WaitMessage) { usleep(1000); RET(1, 0); }
IMPL(user32, SetCapture) { RET(0, 1); }
IMPL(user32, ReleaseCapture) { RET(1, 0); }
IMPL(user32, GetClassInfoA) { w32_set_last_error(c, 1411); RET(0, 3); }             /* not registered yet */
IMPL(user32, GetSysColorBrush) { RET(0x40000 + (ARG(0) & 0xff), 1); }
IMPL(user32, MonitorFromPoint) { RET(0x50001, 3); }                                   /* (POINT by value, flags): the one display */
IMPL(user32, MonitorFromWindow) { RET(0x50001, 2); }                                  /* (window, flags); the game finds these with GetProcAddress */
IMPL(user32, MonitorFromRect) { RET(0x50001, 2); }
IMPL(user32, EnumDisplayMonitors)                     /* (dc, clip rect, callback(monitor, dc, rect *, data), data): one display */
{
    uint32_t r = scratch(16); int32_t v[4] = {0, 0, w32_screen_w, w32_screen_h}; memcpy(GP(r), v, 16);
    uint32_t a[4] = {0x50001, ARG(0), r, ARG(3)}; w32_callback(c, ARG(2), 4, a);
    unscratch(r); RET(1, 4);
}
IMPL(user32, TrackMouseEvent) { RET(1, 1); }                                         /* WM_MOUSELEAVE is not sent */
IMPL(user32, GetMonitorInfoA)                          /* (monitor, MONITORINFO(EX)A *) */
{
    uint32_t mi = ARG(1), cb = rt_r32(G_MEM, mi);
    int32_t r[4] = {0, 0, w32_screen_w, w32_screen_h};
    memcpy(GP(mi + 4), r, 16); memcpy(GP(mi + 20), r, 16); rt_w32(G_MEM, mi + 36, 1);   /* MONITORINFOF_PRIMARY */
    if (cb >= 72) { memset(GP(mi + 40), 0, 32); strcpy((char *)GP(mi + 40), "\\\\.\\DISPLAY1"); }
    RET(1, 2);
}
IMPL(user32, GetWindowPlacement)                       /* (window, WINDOWPLACEMENT *) */
{
    uint32_t p = ARG(1); memset(GP(p), 0, 44);
    rt_w32(G_MEM, p, 44); rt_w32(G_MEM, p + 8, 1);                                    /* SW_SHOWNORMAL */
    rt_w32(G_MEM, p + 36, (uint32_t)w32_screen_w); rt_w32(G_MEM, p + 40, (uint32_t)w32_screen_h);
    RET(1, 2);
}
/* cursors: the game's animated .cur files are not drawn yet; it gets the arrow (LoadCursorA's handles) */
IMPL(user32, LoadCursorFromFileA) { RET(0x30000 + 32512, 1); }
IMPL(user32, LoadImageA)                               /* (instance, name, type, cx, cy, flags) */
{
    if (ARG(2) == 2) RET(0x30000 + 32512, 6);          /* IMAGE_CURSOR */
    w32_set_last_error(c, 2); RET(0, 6);
}
IMPL(user32, CreateCursor) { RET(0x30000 + 32512, 7); }
IMPL(user32, CreateIconIndirect) { RET(0x30000 + 32512, 1); }
IMPL(user32, DestroyCursor) { RET(1, 1); }
IMPL(user32, GetIconInfo) { RET(0, 2); }
IMPL(user32, GetCursorInfo)                            /* CURSORINFO: size, flags, cursor, position */
{
    uint32_t p = ARG(0); void imp_user32_GetCursorPos(Ctx *);
    rt_w32(G_MEM, p + 4, 1); rt_w32(G_MEM, p + 8, 0x30000 + 32512);
    uint32_t esp = c->esp; rt_w32(G_MEM, esp + 4, p + 12); imp_user32_GetCursorPos(c); c->esp = esp; rt_w32(G_MEM, esp + 4, p);
    RET(1, 1);
}
IMPL(user32, SetClipboardViewer) { RET(0, 1); }
IMPL(user32, ChangeClipboardChain) { RET(1, 2); }
IMPL(user32, IsClipboardFormatAvailable) { RET(0, 1); }

/* ---- gdi32 ---- */
IMPL(gdi32, CreateDCA) { RET(0x20004, 4); }                                           /* the screen DC GetDC gives */
IMPL(gdi32, CreateSolidBrush) { RET(0x40100, 1); }
IMPL(gdi32, GetClipBox)
{
    int32_t r[4] = {0, 0, w32_screen_w, w32_screen_h}; memcpy(GP(ARG(1)), r, 16); RET(2, 2);   /* SIMPLEREGION */
}
IMPL(gdi32, GetDCOrgEx) { rt_w32(G_MEM, ARG(1), 0); rt_w32(G_MEM, ARG(1) + 4, 0); RET(1, 2); }
IMPL(gdi32, SetDIBits) { RET(0, 7); }

/* ---- shell32: special folders ---- */
IMPL(shell32, SHGetSpecialFolderLocation)              /* (window, CSIDL, *PIDL): the PIDL is the folder's path */
{
    uint32_t csidl = ARG(1) & 0xff, out = ARG(2); const char *p;
    switch (csidl) {
    case 0x05: p = "C:\\Users\\player\\Documents"; break;                            /* CSIDL_PERSONAL */
    case 0x1a: p = "C:\\Users\\player\\AppData\\Roaming"; break;                     /* CSIDL_APPDATA */
    case 0x1c: p = "C:\\Users\\player\\AppData\\Local"; break;                       /* CSIDL_LOCAL_APPDATA */
    case 0x23: p = "C:\\ProgramData"; break;                                           /* CSIDL_COMMON_APPDATA */
    case 0x10: p = "C:\\Users\\player\\Desktop"; break;
    default: p = "C:\\Users\\player"; break;
    }
    char host[2048]; if (!w32_host_path(p, host, sizeof host, 1)) mkdir(host, 0755);   /* it exists, as on Windows */
    uint32_t a = heap_alloc(w32_process_heap, 8, 264); strcpy((char *)GP(a), p);
    rt_w32(G_MEM, out, a); RET(0, 3);
}
IMPL(shell32, SHGetPathFromIDListA) { strcpy((char *)GP(ARG(1)), GS(ARG(0))); RET(1, 2); }
/* SHGetMalloc: an IMalloc whose Free releases what SHGetSpecialFolderLocation gave */
static void malloc_qi(Ctx *c) { RET(0x80004002u, 3); }
static void malloc_addref(Ctx *c) { RET(1, 1); }
static void malloc_alloc(Ctx *c) { RET(heap_alloc(w32_process_heap, 8, ARG(1)), 2); }
static void malloc_realloc(Ctx *c) { RET(heap_realloc(w32_process_heap, 0, ARG(1), ARG(2)), 3); }
static void malloc_free(Ctx *c) { if (ARG(1)) heap_free(w32_process_heap, ARG(1)); RET(0, 2); }
static void malloc_size(Ctx *c) { RET(heap_size(w32_process_heap, ARG(1)), 2); }
static void malloc_didalloc(Ctx *c) { RET(0xffffffffu, 2); }
static void malloc_minimize(Ctx *c) { RET(0, 1); }
IMPL(shell32, SHGetMalloc)
{
    static uint32_t obj;
    if (!obj) {
        void (*fns[])(Ctx *) = {malloc_qi, malloc_addref, malloc_addref, malloc_alloc, malloc_realloc, malloc_free, malloc_size, malloc_didalloc, malloc_minimize};
        uint32_t vt = heap_alloc(w32_process_heap, 8, 4 * 9); obj = heap_alloc(w32_process_heap, 8, 8);
        for (int k = 0; k < 9; k++) { char nm[48]; snprintf(nm, sizeof nm, "shell32!IMalloc.%d", k); rt_w32(G_MEM, vt + 4u * (uint32_t)k, w32_thunk_register(nm, fns[k])); }
        rt_w32(G_MEM, obj, vt);
    }
    rt_w32(G_MEM, ARG(0), obj); RET(0, 1);
}

/* ---- ole32 / oleaut32 ---- */
IMPL(ole32, CoInitializeSecurity) { RET(0, 9); }
IMPL(ole32, CoSetProxyBlanket) { RET(0, 8); }
IMPL(oleaut32, ord9) { if (ARG(0)) memset(GP(ARG(0)), 0, 16); RET(0, 1); }            /* VariantClear */

/* ---- imm32 ---- */
IMPL(imm32, ImmSetCompositionStringW) { RET(0, 6); }

/* ---- winmm: the rest of multimedia I/O (fnv_imports.c has the reader) ---- */
IMPL(winmm, mmioSetInfo) { void imp_winmm_mmioAdvance(Ctx *); imp_winmm_mmioAdvance(c); }   /* takes back MMIOINFO.pchNext */

/* ---- WinINet: the launch telemetry ("boot_start") is not sent ---- */
IMPL(wininet, InternetOpenA) { w32_set_last_error(c, 12007); RET(0, 5); }
IMPL(wininet, InternetConnectA) { RET(0, 8); }
IMPL(wininet, HttpOpenRequestA) { RET(0, 8); }
IMPL(wininet, HttpAddRequestHeadersA) { RET(0, 4); }
IMPL(wininet, HttpSendRequestExA) { RET(0, 5); }
IMPL(wininet, HttpEndRequestA) { RET(0, 4); }
IMPL(wininet, HttpQueryInfoA) { RET(0, 5); }
IMPL(wininet, InternetReadFile) { RET(0, 4); }
IMPL(wininet, InternetWriteFile) { RET(0, 4); }
IMPL(wininet, InternetCloseHandle) { RET(1, 1); }

/* ---- video capture (Video for Windows compressor, AVI files): no compressors, so the game's capture is off ---- */
IMPL(msvfw32, ICOpen) { RET(0, 3); }
IMPL(msvfw32, ICClose) { RET(0, 1); }
IMPL(msvfw32, ICGetInfo) { RET(0, 3); }
IMPL(msvfw32, ICSendMessage) { RET(0xffffffffu, 4); }                                 /* ICERR_UNSUPPORTED */
IMPL(msvfw32, ICCompressorFree) { RET(0, 2); }
IMPL(msvfw32, ICSeqCompressFrameStart) { RET(0, 2); }
IMPL(msvfw32, ICSeqCompressFrameEnd) { RET(0, 1); }
IMPL(msvfw32, ICSeqCompressFrame) { RET(0, 5); }
IMPL(avifil32, AVIFileInit) { RET(0, 0); }
IMPL(avifil32, AVIFileExit) { RET(0, 0); }
IMPL(avifil32, AVIFileOpenA) { RET(0x80044067u, 4); }                                 /* AVIERR_FILEOPEN */
IMPL(avifil32, AVIFileCreateStreamA) { RET(0x80044067u, 3); }
IMPL(avifil32, AVIStreamSetFormat) { RET(0x80044067u, 4); }
IMPL(avifil32, AVIStreamWrite) { RET(0x80044067u, 8); }
IMPL(avifil32, AVIFileRelease) { RET(0, 1); }
IMPL(avifil32, AVIStreamRelease) { RET(0, 1); }

/* ---- DirectSound: ordinal 1 is DirectSoundCreate ---- */
IMPL(dsound, ord1) { void imp_dsound_DirectSoundCreate(Ctx *); imp_dsound_DirectSoundCreate(c); }

/* ---- Steam, offline. The game needs SteamAPI_Init to succeed, then asks two interfaces for two things: ISteamApps
 * GetCurrentGameLanguage (slot 4) and ISteamUser GetSteamID (slot 2). Every other slot is a named thunk with no
 * implementation, so a call to one stops with its name. All steam_api exports are cdecl; the interface methods are
 * thiscall (this in ecx, arguments popped by the callee). ---- */
#define STEAM_ID 0x0110000100000001ull                                                /* an individual account, public universe */
static uint32_t steam_lang;
static void apps_language(Ctx *c)
{
    if (!steam_lang) { const char *l = getenv("W32_LANGUAGE"); if (!l) l = "english"; steam_lang = heap_alloc(w32_process_heap, 8, 32); snprintf((char *)GP(steam_lang), 32, "%s", l); }
    RET(steam_lang, 0);
}
static void user_steam_id(Ctx *c) { uint32_t out = ARG(0); rt_w32(G_MEM, out, (uint32_t)STEAM_ID); rt_w32(G_MEM, out + 4, (uint32_t)(STEAM_ID >> 32)); RET(out, 1); }
static void user_logged_on(Ctx *c) { RET(0, 0); }
static void user_hsteamuser(Ctx *c) { RET(1, 0); }
static uint32_t steam_iface(const char *name, int nslots, int nimpl, const int *slots, void (**fns)(Ctx *))
{
    uint32_t vt = heap_alloc(w32_process_heap, 8, 4u * (uint32_t)nslots), obj = heap_alloc(w32_process_heap, 8, 16);
    for (int k = 0; k < nslots; k++) {
        void (*fn)(Ctx *) = 0; for (int j = 0; j < nimpl; j++) if (slots[j] == k) fn = fns[j];
        char nm[64]; snprintf(nm, sizeof nm, "steam_api!%s.%d", name, k); rt_w32(G_MEM, vt + 4u * (uint32_t)k, w32_thunk_register(nm, fn));
    }
    rt_w32(G_MEM, obj, vt); return obj;
}
static uint32_t steam_apps, steam_user;
static pthread_once_t steam_once = PTHREAD_ONCE_INIT;
static void steam_make(void)
{
    static const int as[] = {4}; static void (*af[])(Ctx *) = {apps_language};
    static const int us[] = {0, 1, 2}; static void (*uf[])(Ctx *) = {user_hsteamuser, user_logged_on, user_steam_id};
    steam_apps = steam_iface("ISteamApps008", 32, 1, as, af);
    steam_user = steam_iface("ISteamUser023", 40, 3, us, uf);
}
IMPL(steam_api, SteamInternal_SteamAPI_Init) { pthread_once(&steam_once, steam_make); RETC(0); }   /* k_ESteamAPIInitResult_OK */
IMPL(steam_api, SteamAPI_Shutdown) { RETC(0); }
IMPL(steam_api, SteamAPI_RunCallbacks) { RETC(0); }
IMPL(steam_api, SteamAPI_RegisterCallback) { RETC(0); }
IMPL(steam_api, SteamAPI_UnregisterCallback) { RETC(0); }
IMPL(steam_api, SteamAPI_GetHSteamUser) { RETC(1); }
IMPL(steam_api, SteamInternal_FindOrCreateUserInterface)   /* (HSteamUser, version) */
{
    pthread_once(&steam_once, steam_make);
    const char *v = GS(ARG(1));
    if (!strncmp(v, "STEAMAPPS_INTERFACE_VERSION", 27)) RETC(steam_apps);
    if (!strncmp(v, "SteamUser", 9)) RETC(steam_user);
    fprintf(stderr, "steam: no %s offline\n", v); RETC(0);
}
/* (context init data: { void (*init)(void *slot), counter, slot }): the game's init fills the slot through
 * FindOrCreateUserInterface; returns the slot */
IMPL(steam_api, SteamInternal_ContextInit)
{
    uint32_t d = ARG(0);
    if (rt_r32(G_MEM, d + 4) != 1) { uint32_t a = d + 8; w32_callback(c, rt_r32(G_MEM, d), 1, &a); rt_w32(G_MEM, d + 4, 1); }
    RETC(d + 8);
}

/* ---- Winsock 2 ordinal 112 (the others are WSOCK32's, winsock.c) ---- */
IMPL(wsock32, ord112) { w32_set_last_error(c, ARG(0)); RET(0, 1); }                  /* WSASetLastError */

/* ---- d3d9!Direct3DShaderValidatorCreate9 (by GetProcAddress): the statically linked D3DX shader assembler checks
 * each instruction with it, and uses it even when it isn't found (a null object). This one accepts everything. ---- */
static void sv_qi(Ctx *c) { RET(0x80004002u, 3); }
static void sv_addref(Ctx *c) { RET(1, 1); }
static void sv_begin(Ctx *c) { RET(0, 4); }                                           /* (callback, context, flags) */
static void sv_instruction(Ctx *c) { RET(0, 5); }                                     /* (file, line, tokens, count) */
static void sv_end(Ctx *c) { RET(0, 1); }
IMPL(d3d9, Direct3DShaderValidatorCreate9)
{
    static uint32_t obj;
    if (!obj) {
        void (*fns[])(Ctx *) = {sv_qi, sv_addref, sv_addref, sv_begin, sv_instruction, sv_end};
        uint32_t vt = heap_alloc(w32_process_heap, 8, 4 * 6); obj = heap_alloc(w32_process_heap, 8, 8);
        for (int k = 0; k < 6; k++) { char nm[48]; snprintf(nm, sizeof nm, "d3d9!IDirect3DShaderValidator9.%d", k); rt_w32(G_MEM, vt + 4u * (uint32_t)k, w32_thunk_register(nm, fns[k])); }
        rt_w32(G_MEM, obj, vt);
    }
    RET(obj, 0);
}
