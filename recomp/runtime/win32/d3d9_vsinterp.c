/* A Direct3D 9 vertex shader interpreter (vs_1_1 to vs_3_0, arithmetic only) for IDirect3DDevice9::ProcessVertices,
 * Direct3D's software vertex processing: the game runs a vertex shader on the CPU and keeps what it writes. The Sims 2
 * poses its Sims this way for the family and Sim thumbnails (a skinning shader: mov, mul, mad, dp3, dp4, mova with
 * relative constants); it first checks with one vertex that ProcessVertices works, and draws unposed red figures if not.
 * Control flow (rep, loop, if, call, predication) and texture reads are not interpreted: d9_vs_parse fails and the call
 * returns an error, as before. */
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "d3d9_vsinterp.h"

enum { R_TEMP = 0, R_INPUT = 1, R_CONST = 2, R_ADDR = 3, R_RASTOUT = 4, R_ATTROUT = 5, R_OUTPUT = 6, R_CONSTINT = 7,
       R_CONST2 = 11, R_CONST3 = 12, R_CONST4 = 13, R_CONSTBOOL = 14 };
static int rtype(uint32_t t) { return (int)(((t >> 28) & 7) | ((t >> 8) & 0x18)); }

int d9_vs_parse(const uint32_t *code, size_t n, D9VsIO *io)
{
    if (n < 2 || (code[0] & 0xffff0000u) != 0xfffe0000u) return -1;
    memset(io, 0, sizeof *io); io->major = (int)((code[0] >> 8) & 0xff);
    for (int k = 0; k < 16; k++) io->in_usage[k] = io->out_usage[k] = 0xff;
    size_t i = 1;
    while (i < n) {
        uint32_t t = code[i], op = t & 0xffff;
        if (op == 0xffff) return 0;
        if (op == 0xfffe) { i += 1 + ((t >> 16) & 0x7fff); continue; }
        size_t len = io->major >= 2 ? (t >> 24) & 0xf : 0;
        if (io->major < 2) {                                   /* vs_1_x: no length field; count parameter tokens */
            len = 0; while (i + 1 + len < n && (code[i + 1 + len] & 0x80000000u)) len++;
        }
        if (i + 1 + len > n) return -1;
        if (t & 0x10000000u) return -1;                        /* predicated */
        switch (op) {
        case 31: {                                             /* dcl usage, register */
            uint32_t u = code[i + 1], r = code[i + 2], num = r & 0x7ff; int ty = rtype(r);
            if (ty == R_INPUT && num < 16) { io->in_usage[num] = u & 0x1f; io->in_index[num] = (u >> 16) & 0xf; }
            if (ty == R_OUTPUT && num < 16) { io->out_usage[num] = u & 0x1f; io->out_index[num] = (u >> 16) & 0xf; }
            break; }
        case 81:                                               /* def c#, x, y, z, w */
            if (rtype(code[i + 1]) == R_CONST && io->ndef < 64) { io->defs[io->ndef].reg = code[i + 1] & 0x7ff; memcpy(io->defs[io->ndef].v, &code[i + 2], 16); io->ndef++; }
            break;
        case 0: case 1: case 2: case 3: case 4: case 5: case 6: case 7: case 8: case 9: case 10: case 11: case 12: case 13:
        case 14: case 15: case 16: case 17: case 18: case 19: case 20: case 21: case 22: case 23: case 24: case 32: case 33:
        case 34: case 35: case 36: case 37: case 46: case 47: case 48: case 78: case 79:
            break;
        default: return -1;                                    /* control flow, textures: not interpreted */
        }
        i += 1 + len;
    }
    return -1;
}

typedef struct { float r[32][4], o[16][4], rast[3][4], attr[2][4]; int32_t a[4]; } VM;
static const float *src_reg(const VM *m, const D9VsEnv *e, uint32_t t, uint32_t rel, float *scratch)
{
    uint32_t num = t & 0x7ff; int ty = rtype(t);
    if (t & 0x2000) {                                         /* relative: c[n + a0.comp] */
        int comp = (int)((rel >> 16) & 3); num += (uint32_t)m->a[comp];
    }
    switch (ty) {
    case R_TEMP: return num < 32 ? m->r[num] : 0;
    case R_INPUT: return num < 16 ? e->in[num] : 0;
    case R_CONST: case R_CONST2: case R_CONST3: case R_CONST4: {
        uint32_t c = num + (ty == R_CONST2 ? 2048 : ty == R_CONST3 ? 4096 : ty == R_CONST4 ? 6144 : 0);
        for (int k = 0; k < e->io->ndef; k++) if (e->io->defs[k].reg == c) return e->io->defs[k].v;
        if (c < e->nconst) return e->consts[c];
        scratch[0] = scratch[1] = scratch[2] = scratch[3] = 0; return scratch; }   /* out of range: 0, as hardware reads */
    case R_ADDR: for (int k = 0; k < 4; k++) scratch[k] = (float)m->a[k]; return scratch;
    case R_CONSTINT: if (num < 16) { for (int k = 0; k < 4; k++) scratch[k] = (float)e->iconsts[num][k]; return scratch; } return 0;
    default: return 0;
    }
}
static int fetch(const VM *m, const D9VsEnv *e, const uint32_t *code, size_t *i, float out[4])
{
    uint32_t t = code[*i], rel = 0; (*i)++;
    if (t & 0x2000) { rel = code[*i]; (*i)++; }
    float scratch[4]; const float *v = src_reg(m, e, t, rel, scratch); if (!v) return -1;
    uint32_t sw = (t >> 16) & 0xff, mod = (t >> 24) & 0xf;
    for (int k = 0; k < 4; k++) {
        float x = v[(sw >> (2 * k)) & 3];
        switch (mod) {
        case 0: break; case 1: x = -x; break; case 2: x = x - 0.5f; break; case 3: x = 0.5f - x; break;
        case 4: x = 2 * (x - 0.5f); break; case 5: x = -2 * (x - 0.5f); break; case 6: x = 1 - x; break;
        case 7: x = 2 * x; break; case 8: x = -2 * x; break; case 11: x = fabsf(x); break; case 12: x = -fabsf(x); break;
        default: return -1;
        }
        out[k] = x;
    }
    return 0;
}
static float *dst_reg(VM *m, uint32_t t)
{
    uint32_t num = t & 0x7ff;
    switch (rtype(t)) {
    case R_TEMP: return num < 32 ? m->r[num] : 0;
    case R_OUTPUT: return num < 16 ? m->o[num] : 0;
    case R_RASTOUT: return num < 3 ? m->rast[num] : 0;
    case R_ATTROUT: return num < 2 ? m->attr[num] : 0;
    default: return 0;
    }
}
static float dp(const float *a, const float *b, int n) { float s = 0; for (int k = 0; k < n; k++) s += a[k] * b[k]; return s; }

int d9_vs_run(const uint32_t *code, size_t n, const D9VsIO *io, const D9VsEnv *e, float out[16][4])
{
    VM m; memset(&m, 0, sizeof m);
    size_t i = 1;
    while (i < n) {
        uint32_t t = code[i], op = t & 0xffff;
        if (op == 0xffff) break;
        if (op == 0xfffe) { i += 1 + ((t >> 16) & 0x7fff); continue; }
        size_t len = io->major >= 2 ? (t >> 24) & 0xf : 0, start = i + 1;
        if (io->major < 2) { len = 0; while (i + 1 + len < n && (code[i + 1 + len] & 0x80000000u)) len++; }
        size_t next = start + len;
        if (op == 31 || op == 81 || op == 47 || op == 48 || op == 0) { i = next; continue; }   /* dcl, def (in env), nop */
        uint32_t d = code[start]; size_t p = start + 1;
        if (d & 0x2000) p++;                                   /* relative destination: not used by these shaders */
        float a[4] = {0}, b[4] = {0}, c[4] = {0}, r[4] = {0};
        int nsrc = op == 1 || op == 6 || op == 7 || op == 14 || op == 15 || op == 16 || op == 19 || op == 34 || op == 35 || op == 36 || op == 37 || op == 46 ? 1
                 : op == 4 || op == 18 ? 3 : 2;
        if (op == 37 && io->major < 3) nsrc = 3;               /* sincos (vs_2_x): two constant operands */
        if (fetch(&m, e, code, &p, a)) return -1;
        if (nsrc >= 2 && fetch(&m, e, code, &p, b)) return -1;
        if (nsrc >= 3 && op != 37 && fetch(&m, e, code, &p, c)) return -1;
        float mtx[4][4];
        if (op >= 20 && op <= 24) {                            /* m4x4 etc.: the matrix is consecutive registers from b */
            uint32_t bt = code[start + 2]; size_t q = start + 2;
            for (int row = 0; row < 4; row++) {
                size_t qq = q; uint32_t base = code[qq]; uint32_t tok = (base & ~0x7ffu) | ((base & 0x7ff) + (uint32_t)row);
                uint32_t tmp[2] = {tok, (bt & 0x2000) ? code[qq + 1] : 0}; size_t z = 0;
                if (fetch(&m, e, tmp, &z, mtx[row])) return -1;
            }
        }
        switch (op) {
        case 1: memcpy(r, a, 16); break;
        case 2: for (int k = 0; k < 4; k++) r[k] = a[k] + b[k]; break;
        case 3: for (int k = 0; k < 4; k++) r[k] = a[k] - b[k]; break;
        case 4: for (int k = 0; k < 4; k++) r[k] = a[k] * b[k] + c[k]; break;
        case 5: for (int k = 0; k < 4; k++) r[k] = a[k] * b[k]; break;
        case 6: r[0] = r[1] = r[2] = r[3] = a[3] == 0 ? INFINITY : 1.0f / a[3]; break;   /* rcp/rsq: the replicated (last-swizzled) component */
        case 7: { float x = fabsf(a[3]); r[0] = r[1] = r[2] = r[3] = x == 0 ? INFINITY : 1.0f / sqrtf(x); break; }
        case 8: r[0] = r[1] = r[2] = r[3] = dp(a, b, 3); break;
        case 9: r[0] = r[1] = r[2] = r[3] = dp(a, b, 4); break;
        case 10: for (int k = 0; k < 4; k++) r[k] = a[k] < b[k] ? a[k] : b[k]; break;
        case 11: for (int k = 0; k < 4; k++) r[k] = a[k] > b[k] ? a[k] : b[k]; break;
        case 12: for (int k = 0; k < 4; k++) r[k] = a[k] < b[k] ? 1.0f : 0.0f; break;
        case 13: for (int k = 0; k < 4; k++) r[k] = a[k] >= b[k] ? 1.0f : 0.0f; break;
        case 14: r[0] = r[1] = r[2] = r[3] = exp2f(a[3]); break;
        case 15: { float x = fabsf(a[3]); r[0] = r[1] = r[2] = r[3] = x == 0 ? -INFINITY : log2f(x); break; }
        case 16: { float y = a[1] > 0 ? a[1] : 0, w = a[3] < -127.9961f ? -127.9961f : a[3] > 127.9961f ? 127.9961f : a[3];
            r[0] = 1; r[1] = a[0] > 0 ? a[0] : 0; r[2] = a[0] > 0 && y > 0 ? powf(y, w) : 0; r[3] = 1; break; }
        case 17: r[0] = 1; r[1] = a[1] * b[1]; r[2] = a[2]; r[3] = b[3]; break;
        case 18: for (int k = 0; k < 4; k++) r[k] = a[k] * (b[k] - c[k]) + c[k]; break;
        case 19: for (int k = 0; k < 4; k++) r[k] = a[k] - floorf(a[k]); break;
        case 20: for (int k = 0; k < 4; k++) r[k] = dp(a, mtx[k], 4); break;
        case 21: for (int k = 0; k < 3; k++) r[k] = dp(a, mtx[k], 4); break;
        case 22: for (int k = 0; k < 4; k++) r[k] = dp(a, mtx[k], 3); break;
        case 23: for (int k = 0; k < 3; k++) r[k] = dp(a, mtx[k], 3); break;
        case 24: for (int k = 0; k < 2; k++) r[k] = dp(a, mtx[k], 3); break;
        case 32: r[0] = r[1] = r[2] = r[3] = powf(fabsf(a[3]), b[3]); break;
        case 33: r[0] = a[1] * b[2] - a[2] * b[1]; r[1] = a[2] * b[0] - a[0] * b[2]; r[2] = a[0] * b[1] - a[1] * b[0]; break;
        case 34: for (int k = 0; k < 4; k++) r[k] = a[k] > 0 ? 1.0f : a[k] < 0 ? -1.0f : 0.0f; break;
        case 35: for (int k = 0; k < 4; k++) r[k] = fabsf(a[k]); break;
        case 36: { float l = sqrtf(dp(a, a, 3)); float s = l == 0 ? INFINITY : 1.0f / l; for (int k = 0; k < 4; k++) r[k] = a[k] * s; break; }
        case 37: r[0] = cosf(a[3]); r[1] = sinf(a[3]); break;
        case 46: {                                             /* mova: a0 = round to nearest (vs_1_1: floor) */
            uint32_t mask = (d >> 16) & 0xf;
            for (int k = 0; k < 4; k++) if (mask & (1u << k)) m.a[k] = io->major >= 2 ? (int32_t)lrintf(a[k]) : (int32_t)floorf(a[k]);
            i = next; continue; }
        default: return -1;
        }
        float *dr = dst_reg(&m, d); if (!dr) return -1;
        uint32_t mask = (d >> 16) & 0xf; int sat = (d >> 20) & 1;
        for (int k = 0; k < 4; k++) if (mask & (1u << k)) { float x = r[k]; if (sat) x = x < 0 ? 0 : x > 1 ? 1 : x; dr[k] = x; }
        i = next;
    }
    if (io->major >= 3) memcpy(out, m.o, sizeof m.o);
    else {   /* vs_1/2: position in rast[0], colours in attr, texture coordinates in o (TEXCRDOUT): by D3D's fixed order */
        memset(out, 0, 16 * 4 * sizeof(float));
        memcpy(out[0], m.rast[0], 16); memcpy(out[1], m.attr[0], 16); memcpy(out[2], m.attr[1], 16);
        for (int k = 0; k < 8; k++) memcpy(out[3 + k], m.o[k], 16);
    }
    return 0;
}
