/* EA's RefPack (QFS) compression, natively: The Sims 2 compresses resources while it plays (its own compressor,
 * 0xa09cc611 in Sims2EP9.exe, runs as recompiled code for up to 3 s on a large one: hooks.c replaces it). Any valid
 * RefPack stream reads back with the game's decompressor; this one is a greedy LZ77 with hash chains.
 * The stream after the 5-byte header (10 FB, size big-endian 24-bit) that the game writes itself:
 *   0x00-0x7F  2 bytes: plain 0-3, copy 3-10 bytes from 1-1024 back
 *   0x80-0xBF  3 bytes: plain 0-3, copy 4-67 from 1-16384 back
 *   0xC0-0xDF  4 bytes: plain 0-3, copy 5-1028 from 1-131072 back
 *   0xE0-0xFB  plain 4-112 (a multiple of 4)
 *   0xFC-0xFF  end, plain 0-3
 * "plain" bytes follow the control bytes and come before the copy. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { MAXOFF = 131072, MAXLEN = 1028, HBITS = 16, CHAIN = 48 };

static uint8_t *literals(uint8_t *o, const uint8_t *src, uint32_t *from, uint32_t to)
{
    while (to - *from >= 4) {                                 /* whole blocks of 4, at most 112 */
        uint32_t n = (to - *from) & ~3u; if (n > 112) n = 112;
        *o++ = (uint8_t)(0xE0 + (n >> 2) - 1); memcpy(o, src + *from, n); o += n; *from += n;
    }
    return o;                                                 /* (0-3 left: they go with the next control) */
}
static inline uint32_t hash3(const uint8_t *p) { return ((uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2]) * 2654435761u >> (32 - HBITS); }

/* compresses len bytes; returns the stream's length (dst needs len + len / 112 + 8 bytes at most), 0 if out of memory */
uint32_t refpack_compress(const uint8_t *src, uint32_t len, uint8_t *dst, uint32_t window)
{
    if (!window || window > MAXOFF) window = MAXOFF;
    int32_t *head = malloc(sizeof(int32_t) << HBITS), *prev = len ? malloc(sizeof(int32_t) * (size_t)len) : NULL;
    if (!head || (len && !prev)) { free(head); free(prev); return 0; }
    memset(head, 0xff, sizeof(int32_t) << HBITS);
    uint8_t *o = dst; uint32_t i = 0, lit = 0;
    #define INSERT(k) do { if ((k) + 2 < len) { uint32_t h_ = hash3(src + (k)); prev[k] = head[h_]; head[h_] = (int32_t)(k); } } while (0)
    while (i + 2 < len) {
        uint32_t best = 0, boff = 0, h = hash3(src + i), lim = len - i < MAXLEN ? len - i : MAXLEN;
        int32_t cand = head[h];
        for (int n = 0; cand >= 0 && n < CHAIN; n++, cand = prev[cand]) {
            uint32_t off = i - (uint32_t)cand; if (off > window) break;
            if (src[cand + best] != src[i + best]) continue;
            uint32_t l = 0; while (l < lim && src[cand + l] == src[i + l]) l++;
            /* what each length can reach: 3 within 1024, 4 within 16384, 5 and more within 131072 */
            if ((l == 3 && off > 1024) || (l == 4 && off > 16384) || l < 3) continue;
            if (l > best) { best = l; boff = off; if (l == lim) break; }
        }
        if (!best) { INSERT(i); i++; continue; }
        o = literals(o, src, &lit, i);
        uint32_t plain = i - lit, d = boff - 1;
        if (best <= 10 && boff <= 1024) { *o++ = (uint8_t)(((d >> 3) & 0x60) | ((best - 3) << 2) | plain); *o++ = (uint8_t)d; }
        else if (best <= 67 && boff <= 16384) { *o++ = (uint8_t)(0x80 | (best - 4)); *o++ = (uint8_t)((plain << 6) | (d >> 8)); *o++ = (uint8_t)d; }
        else { *o++ = (uint8_t)(0xC0 | ((d >> 12) & 0x10) | (((best - 5) >> 6) & 0x0C) | plain); *o++ = (uint8_t)(d >> 8); *o++ = (uint8_t)d; *o++ = (uint8_t)(best - 5); }
        memcpy(o, src + lit, plain); o += plain;
        for (uint32_t k = 0; k < best; k++) INSERT(i + k);
        i += best; lit = i;
    }
    o = literals(o, src, &lit, len);
    *o++ = (uint8_t)(0xFC | (len - lit)); memcpy(o, src + lit, len - lit); o += len - lit;
    #undef INSERT
    free(head); free(prev);
    return (uint32_t)(o - dst);
}

/* reads a stream (after the header) into out (cap bytes); returns the length produced, or -1 if malformed */
long refpack_decompress(const uint8_t *in, size_t inlen, uint8_t *out, size_t cap)
{
    const uint8_t *e = in + inlen; size_t n = 0;
    while (in < e) {
        uint32_t b0 = *in++, plain, len, off = 0;
        if (b0 < 0x80) { if (in + 1 > e) return -1; uint32_t b1 = *in++; plain = b0 & 3; len = ((b0 >> 2) & 7) + 3; off = ((b0 & 0x60) << 3) + b1 + 1; }
        else if (b0 < 0xC0) { if (in + 2 > e) return -1; uint32_t b1 = in[0], b2 = in[1]; in += 2; plain = b1 >> 6; len = (b0 & 0x3F) + 4; off = ((b1 & 0x3F) << 8) + b2 + 1; }
        else if (b0 < 0xE0) { if (in + 3 > e) return -1; uint32_t b1 = in[0], b2 = in[1], b3 = in[2]; in += 3; plain = b0 & 3; len = ((b0 & 0x0C) << 6) + b3 + 5; off = ((b0 & 0x10) << 12) + (b1 << 8) + b2 + 1; }
        else if (b0 < 0xFC) { plain = ((b0 & 0x1F) + 1) * 4; len = 0; }
        else { plain = b0 & 3; if (in + plain > e || n + plain > cap) return -1; memcpy(out + n, in, plain); return (long)(n + plain); }
        if (in + plain > e || n + plain > cap) return -1;
        memcpy(out + n, in, plain); in += plain; n += plain;
        if (len) { if (off > n || n + len > cap) return -1; for (uint32_t k = 0; k < len; k++, n++) out[n] = out[n - off]; }
    }
    return (long)n;
}
