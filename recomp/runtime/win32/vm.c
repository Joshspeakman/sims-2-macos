/* Guest virtual memory: VirtualAlloc-style regions inside the 4 GB guest space. Host pages are always readable and
 * writable (G_MEM is one anonymous mapping); this tracks reservation and commit state for VirtualQuery and returns
 * zeroed memory for new commits. */
#include "w32.h"
#include <sys/mman.h>
#include "platform.h"

typedef struct Region { uint32_t base, size, type, prot; uint8_t *commit; } Region;   /* commit: per 4 KB page */
static Region *R; static int nR, capR;
static pthread_mutex_t vm_lock = PTHREAD_MUTEX_INITIALIZER;

extern int w32_protect_memory;
#define HP (ds_page_size())                                   /* host page (arm64 macOS); guest pages are 4 KB */
static void zero_range(uint32_t a, uint32_t n)
{
    if (!n) return;
    uint32_t lo = (a + HP - 1) & ~(HP - 1), hi = (a + n) & ~(HP - 1);
    if (lo < hi) mmap(G_MEM + lo, hi - lo, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (a < lo) memset(G_MEM + a, 0, (lo < a + n ? lo : a + n) - a);
    if (hi >= lo && hi < a + n && hi >= a) memset(G_MEM + hi, 0, a + n - hi);
}
/* host protection follows guest commit state (host-page granularity: a host page is accessible if any guest page in it
 * is committed) */
static int find(uint32_t a);
static void protect(uint32_t a, uint32_t n, int rw)
{
    if (!w32_protect_memory || !n) return;
    uint32_t lo = a & ~(HP - 1), hi = (a + n + HP - 1) & ~(HP - 1);
    mprotect(G_MEM + lo, hi - lo, rw ? PROT_READ | PROT_WRITE : PROT_NONE);
    if (rw && getenv("W32_VMLOG") && ((a & (HP - 1)) || ((a + n) & (HP - 1)))) fprintf(stderr, "w32: commit %08x+%x is not host-page aligned\n", a, n);
}
static int find(uint32_t a)
{
    int lo = 0, hi = nR - 1;
    while (lo <= hi) {
        int m = (lo + hi) / 2;
        if (a < R[m].base) hi = m - 1;
        else if (a >= R[m].base + R[m].size) lo = m + 1;
        else return m;
    }
    return -1;
}
static int insert(uint32_t base, uint32_t size, uint32_t type, uint32_t prot)
{
    if (nR == capR) { capR = capR ? capR * 2 : 256; R = realloc(R, capR * sizeof *R); }
    int k = 0; while (k < nR && R[k].base < base) k++;
    memmove(R + k + 1, R + k, (nR - k) * sizeof *R); nR++;
    R[k].base = base; R[k].size = size; R[k].type = type; R[k].prot = prot; R[k].commit = calloc(size >> 12, 1);
    return k;
}
static int range_free(uint32_t a, uint32_t n)
{
    for (int k = 0; k < nR; k++) {
        uint32_t e = (R[k].base + R[k].size + 0xffff) & ~0xffffu;          /* a region owns its whole last 64 KB granule */
        if (a < e && R[k].base < a + n) return 0;
    }
    return 1;
}
void vm_register(uint32_t base, uint32_t size, uint32_t type)
{
    pthread_mutex_lock(&vm_lock);
    int k = insert(base, size, type, 4); memset(R[k].commit, 1, size >> 12);
    protect(base, size, 1);
    pthread_mutex_unlock(&vm_lock);
}
uint32_t vm_alloc(uint32_t addr, uint32_t size, uint32_t type, uint32_t prot)
{
    enum { MEM_COMMIT = 0x1000, MEM_RESERVE = 0x2000, MEM_TOP_DOWN = 0x100000 };
    uint32_t r = 0;
    if (!size) return 0;
    pthread_mutex_lock(&vm_lock);
    if (!addr || (type & MEM_RESERVE)) {
        /* Windows: the base is 64 KB aligned, the region is page (4 KB) granular; the rest of the 64 KB is unusable */
        uint32_t base = addr & ~0xffffu, end = (addr ? addr + size : 0) , span;
        uint32_t psz = addr ? ((end + 0xfff) & ~0xfffu) - base : (size + 0xfff) & ~0xfffu;
        span = (psz + 0xffff) & ~0xffffu;
        if (!addr) {   /* the first (or, top-down, last) gap of span bytes between the regions, which are sorted by base */
            uint64_t found = 0; int ok = 0;
            if (type & MEM_TOP_DOWN) {
                uint64_t hi = VM_HI;
                for (int k = nR; k >= 0; k--) {
                    uint64_t lo = k ? ((uint64_t)R[k - 1].base + R[k - 1].size + 0xffff) & ~0xffffull : VM_LO;
                    if (lo < VM_LO) lo = VM_LO;
                    if (hi >= lo + span) { found = (hi - span) & ~0xffffull; if (found >= lo) { ok = 1; break; } }
                    if (k) { uint64_t b = R[k - 1].base & ~0xffffull; if (b < hi) hi = b; }
                }
            } else {
                uint64_t lo = VM_LO;
                for (int k = 0; k <= nR; k++) {
                    uint64_t hi = k < nR ? (R[k].base & ~0xffffull) : VM_HI;
                    if (hi > lo && hi - lo >= span) { found = lo; ok = 1; break; }
                    if (k < nR) { uint64_t e = ((uint64_t)R[k].base + R[k].size + 0xffff) & ~0xffffull; if (e > lo) lo = e; }
                }
            }
            if (!ok || found < VM_LO || found + span > VM_HI) goto out;
            base = (uint32_t)found;
        } else if (!range_free(base, psz)) goto out;
        int k = insert(base, psz, 0x20000 /* MEM_PRIVATE */, prot);
        if (type & MEM_COMMIT) {
            uint32_t a = addr ? addr & ~0xfffu : base, e = addr ? (addr + size + 0xfff) & ~0xfffu : base + psz;
            for (uint32_t p = a; p < e; p += 0x1000) R[k].commit[(p - base) >> 12] = 1;
            protect(a, e - a, 1);
        }
        r = addr ? addr & ~0xfffu : base;
    } else if (type & MEM_COMMIT) {
        int k = find(addr);
        uint32_t a = addr & ~0xfffu, e = (addr + size + 0xfff) & ~0xfffu;
        if (k < 0 || e > R[k].base + R[k].size) goto out;
        for (uint32_t p = a; p < e; p += 0x1000) R[k].commit[(p - R[k].base) >> 12] = 1;
        protect(a, e - a, 1);
        r = a;
    }
out:
    pthread_mutex_unlock(&vm_lock);
    static int vmlog = -1; if (vmlog < 0) vmlog = getenv("W32_VMLOG") != 0;
    if (vmlog) fprintf(stderr, "w32: VirtualAlloc(%08x, %x, %x, %x) -> %08x\n", addr, size, type, prot, r);
    return r;
}
int vm_free(uint32_t addr, uint32_t size, uint32_t type)
{
    enum { MEM_DECOMMIT = 0x4000, MEM_RELEASE = 0x8000 };
    int ok = 0;
    pthread_mutex_lock(&vm_lock);
    int k = find(addr);
    if (k < 0) goto out;
    if (type & MEM_RELEASE) {
        if (addr != R[k].base) goto out;
        {   uint32_t b = R[k].base, n = R[k].size;
            mmap(G_MEM + (b & ~(HP - 1)), ((b + n + HP - 1) & ~(HP - 1)) - (b & ~(HP - 1)), PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
            if (w32_protect_memory) mprotect(G_MEM + (b & ~(HP - 1)), ((b + n + HP - 1) & ~(HP - 1)) - (b & ~(HP - 1)), PROT_NONE);
        }
        free(R[k].commit);
        memmove(R + k, R + k + 1, (nR - k - 1) * sizeof *R); nR--; ok = 1;
    } else if (type & MEM_DECOMMIT) {
        uint32_t a = addr & ~0xfffu, e = size ? (addr + size + 0xfff) & ~0xfffu : R[k].base + R[k].size;
        if (e > R[k].base + R[k].size) goto out;
        for (uint32_t p = a; p < e; p += 0x1000) R[k].commit[(p - R[k].base) >> 12] = 0;
        /* zero the decommitted pages: host pages with no committed guest page left get fresh pages (and are closed);
         * pages still partly committed are accessible and are cleared in place */
        for (uint32_t hp = a & ~(HP - 1); hp < e; hp += HP) {
            int any = 0;
            for (uint32_t p = hp; p < hp + HP; p += 0x1000) { int j = find(p); if (j >= 0 && R[j].commit[(p - R[j].base) >> 12]) any = 1; }
            uint32_t lo = hp > a ? hp : a, hi = hp + HP < e ? hp + HP : e;
            if (!any) {
                mmap(G_MEM + hp, HP, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
                if (w32_protect_memory) mprotect(G_MEM + hp, HP, PROT_NONE);
            } else if (w32_protect_memory || 1) memset(G_MEM + lo, 0, hi - lo);
        }
        ok = 1;
    }
out:
    pthread_mutex_unlock(&vm_lock);
    if (getenv("W32_VMLOG")) fprintf(stderr, "w32: VirtualFree(%08x, %x, %x) -> %d\n", addr, size, type, ok);
    return ok;
}
int vm_query(uint32_t addr, uint32_t out)
{
    uint32_t mbi[7] = {0};
    pthread_mutex_lock(&vm_lock);
    int k = find(addr); uint32_t page = addr & ~0xfffu;
    if (k < 0) {   /* free: up to the next region */
        uint32_t next = 0x7fff0000u;
        for (int j = 0; j < nR; j++) if (R[j].base > page) { next = R[j].base; break; }
        mbi[0] = page; mbi[3] = next > page ? next - page : 0x1000; mbi[4] = 0x10000 /* MEM_FREE */; mbi[5] = 1 /* NOACCESS */;
    } else {
        Region *g = &R[k]; uint8_t st = g->commit[(page - g->base) >> 12]; uint32_t e = page;
        while (e < g->base + g->size && g->commit[(e - g->base) >> 12] == st) e += 0x1000;
        mbi[0] = page; mbi[1] = g->base; mbi[2] = g->prot; mbi[3] = e - page;
        mbi[4] = st ? 0x1000 /* MEM_COMMIT */ : 0x2000 /* MEM_RESERVE */; mbi[5] = st ? g->prot : 0; mbi[6] = g->type;
    }
    pthread_mutex_unlock(&vm_lock);
    memcpy(G_MEM + out, mbi, sizeof mbi);
    return 28;
}
int vm_committed(uint32_t addr, uint32_t size)
{
    int ok = 1;
    pthread_mutex_lock(&vm_lock);
    for (uint32_t p = addr & ~0xfffu; p < addr + size; p += 0x1000) {
        int k = find(p);
        if (k < 0 || !R[k].commit[(p - R[k].base) >> 12]) { ok = 0; break; }
    }
    pthread_mutex_unlock(&vm_lock);
    return ok;
}
uint64_t vm_hash(void)       /* FNV-1a over all committed pages (harness state comparison) */
{
    uint64_t h = 1469598103934665603ull;
    pthread_mutex_lock(&vm_lock);
    for (int k = 0; k < nR; k++)
        for (uint32_t p = 0; p < R[k].size; p += 0x1000) {
            if (!R[k].commit[p >> 12]) continue;
            const uint64_t *w = (const uint64_t *)(G_MEM + R[k].base + p);
            for (int j = 0; j < 512; j++) { h ^= w[j]; h *= 1099511628211ull; }
        }
    pthread_mutex_unlock(&vm_lock);
    return h;
}
/* 0 = free, 1 = reserved (not committed), 2 = committed */
int vm_page_state(uint32_t a)
{
    pthread_mutex_lock(&vm_lock);
    int k = find(a), st = k < 0 ? 0 : R[k].commit[((a & ~0xfffu) - R[k].base) >> 12] ? 2 : 1;
    pthread_mutex_unlock(&vm_lock);
    return st;
}
/* crash reports: what the guest address space holds at a, and the regions on either side (a wild pointer, a stale
 * pointer into a released region, or a reserved page nobody committed). trylock: the report must not wait. */
void vm_describe(uint32_t a, char *out, size_t cap)
{
    if (pthread_mutex_trylock(&vm_lock)) { snprintf(out, cap, "(the memory map was busy)"); return; }
    int k = find(a), below = -1;
    for (int j = 0; j < nR && R[j].base <= a; j++) below = j;
    #define RTYPE(t) ((t) == 0x1000000 ? "image" : "private")
    if (k >= 0) {
        uint32_t pg = ((a & ~0xfffu) - R[k].base) >> 12, n = R[k].size >> 12, run = 0;
        for (uint32_t p = 0; p < n; p++) run += R[k].commit[p] ? 1 : 0;
        snprintf(out, cap, "%s, in %s region %08x-%08x (%u of %u pages committed)", R[k].commit[pg] ? "committed" : "reserved, not committed",
                 RTYPE(R[k].type), R[k].base, R[k].base + R[k].size, run, n);
    } else {
        int n = snprintf(out, cap, "free (in no region); nearest below: ");
        if (below >= 0 && n > 0 && (size_t)n < cap) n += snprintf(out + n, cap - n, "%s %08x-%08x (%#x bytes before it)", RTYPE(R[below].type), R[below].base,
                                                               R[below].base + R[below].size, a - (R[below].base + R[below].size));
        else if (n > 0 && (size_t)n < cap) n += snprintf(out + n, cap - n, "none");
        int above = below + 1;
        if (above < nR && n > 0 && (size_t)n < cap) snprintf(out + n, cap - n, "; above: %s %08x-%08x", RTYPE(R[above].type), R[above].base, R[above].base + R[above].size);
    }
    #undef RTYPE
    pthread_mutex_unlock(&vm_lock);
}
