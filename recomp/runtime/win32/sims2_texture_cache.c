/* Cache the game's exact BC1 compressor results, rather than substituting a
 * different lossy encoder. The known Steam edition uses this stdcall leaf for
 * 4x4 float RGBA blocks: (8-byte output, 256-byte input, conversion flags).
 * Hash collisions are checked against the entire input. No guest pointers are
 * retained. Unknown/failed conversions continue through the original code. */
#include "w32.h"
#include <sys/stat.h>
#include <unistd.h>
#define BLOCK_SLOTS 32768u
#define BLOCK_BYTES 256u
#define COMPRESS_BC1 0xa0084dcbu
/* On-disk version is tied to this compressor/edition and the entry layout. */
typedef struct { uint64_t hash, check; uint32_t flags, fcw, used; uint8_t input[BLOCK_BYTES], output[8]; } BlockEntry;
static BlockEntry *blocks;
static pthread_once_t block_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t block_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread int inside_compressor;
static uint64_t hits, misses;
static int dirty, verify;
static uint64_t verified, mismatches;
static char block_path[2048];
static uint64_t block_hash(const void *p, size_t n, uint64_t hash)
{
    const uint8_t *b = p; while (n--) hash = (hash ^ *b++) * 1099511628211ull; return hash;
}
static uint64_t block_key(const uint8_t *input, uint32_t flags, uint32_t fcw)
{
    uint64_t h = block_hash(input, BLOCK_BYTES, 14695981039346656037ull);
    h = block_hash(&flags, sizeof flags, h); return block_hash(&fcw, sizeof fcw, h);
}
static void block_save(void)
{
    pthread_mutex_lock(&block_lock);
    if (getenv("SIMS2_TEXTURE_CACHE_LOG")) fprintf(stderr, "sims2: texture block cache %llu hits, %llu misses\n", (unsigned long long)hits, (unsigned long long)misses);
    if (verify) fprintf(stderr, "sims2: texture cache verified %llu blocks, %llu mismatches\n", (unsigned long long)verified, (unsigned long long)mismatches);
    if (blocks && dirty && block_path[0]) {
        char tmp[2080]; snprintf(tmp, sizeof tmp, "%s.%d.tmp", block_path, getpid());
        FILE *f = fopen(tmp, "wb");
        if (f) {
            uint32_t header[4] = {0x53424331, 2, BLOCK_SLOTS, sizeof(BlockEntry)};
            int ok = fwrite(header, sizeof header, 1, f) == 1 && fwrite(blocks, sizeof *blocks, BLOCK_SLOTS, f) == BLOCK_SLOTS;
            if (fclose(f)) ok = 0;
            if (ok) rename(tmp, block_path); else unlink(tmp);
        }
    }
    pthread_mutex_unlock(&block_lock);
}
static void block_init(void)
{
    const char *enabled = getenv("SIMS2_TEXTURE_CACHE"); if (enabled && !strcmp(enabled, "0")) return;
    verify = getenv("SIMS2_TEXTURE_CACHE_VERIFY") != NULL;
    blocks = calloc(BLOCK_SLOTS, sizeof *blocks); if (!blocks) return;
    const char *dir = getenv("DSR_TEXTURE_CACHE_DIR");
    if (dir && *dir && strlen(dir) + 40 < sizeof block_path) {
        snprintf(block_path, sizeof block_path, "%s/sims2-7aaf7336-bc1-v2.bin", dir);
        FILE *f = fopen(block_path, "rb");
        if (f) {
            uint32_t header[4] = {0}; struct stat st;
            if (!fstat(fileno(f), &st) && (size_t)st.st_size == 16 + BLOCK_SLOTS * sizeof *blocks &&
                fread(header, sizeof header, 1, f) == 1 && header[0] == 0x53424331 && header[1] == 2 && header[2] == BLOCK_SLOTS && header[3] == sizeof *blocks &&
                fread(blocks, sizeof *blocks, BLOCK_SLOTS, f) == BLOCK_SLOTS) {
                for (unsigned k = 0; k < BLOCK_SLOTS; k++) {
                    BlockEntry *e = blocks + k;
                    if (e->used && (e->hash != block_key(e->input, e->flags, e->fcw) || e->check != block_hash(e->output, 8, e->hash))) e->used = 0;
                }
            } else memset(blocks, 0, BLOCK_SLOTS * sizeof *blocks);
            fclose(f);
        }
    }
    atexit(block_save);
}
int sims2_texture_compress(Ctx *c)
{
    if (inside_compressor || w32_deterministic) return 0;
    pthread_once(&block_once, block_init); if (!blocks) return 0;
    uint32_t dst = ARG(0), src = ARG(1), flags = ARG(2);
    if (!vm_committed(src, BLOCK_BYTES) || !vm_committed(dst, 8) ||
        ((uint64_t)dst < (uint64_t)src + BLOCK_BYTES && (uint64_t)src < (uint64_t)dst + 8)) return 0;
    uint8_t input[BLOCK_BYTES]; memcpy(input, G_MEM + src, sizeof input);
    uint64_t hash = block_key(input, flags, c->fcw); unsigned slot = (unsigned)(hash ^ (hash >> 32)) & (BLOCK_SLOTS - 1);
    pthread_mutex_lock(&block_lock);
    BlockEntry *e = blocks + slot;
    if (e->used && e->hash == hash && e->flags == flags && e->fcw == c->fcw && !memcmp(e->input, input, sizeof input)) {
        uint8_t expected[8]; memcpy(expected, e->output, 8); hits++; pthread_mutex_unlock(&block_lock);
        if (verify) {
            inside_compressor = 1; rt_call(c, COMPRESS_BC1); inside_compressor = 0;
            pthread_mutex_lock(&block_lock); verified++;
            if (c->eax || memcmp(G_MEM + dst, expected, 8)) { mismatches++; blocks[slot].used = 0; dirty = 1; }
            pthread_mutex_unlock(&block_lock); return 1;
        }
        memcpy(G_MEM + dst, expected, 8);
        c->eax = 0; c->esp += 16; return 1;
    }
    misses++; pthread_mutex_unlock(&block_lock);
    inside_compressor = 1; rt_call(c, COMPRESS_BC1); inside_compressor = 0;
    if (!c->eax && !memcmp(input, G_MEM + src, sizeof input)) {
        pthread_mutex_lock(&block_lock);
        e = blocks + slot; e->hash = hash; e->flags = flags; e->fcw = c->fcw; e->used = 1;
        memcpy(e->input, input, sizeof input); memcpy(e->output, G_MEM + dst, 8);
        e->check = block_hash(e->output, 8, hash); dirty = 1;
        pthread_mutex_unlock(&block_lock);
    }
    return 1;
}
