/* d3d9_vsinterp.c: a vertex shader run on the CPU (ProcessVertices) */
#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct { uint32_t reg; float v[4]; } D9VsDef;
typedef struct {
    int major;                                         /* shader model */
    uint8_t in_usage[16], in_index[16];                /* dcl of v0-v15 (0xff: not declared) */
    uint8_t out_usage[16], out_index[16];              /* vs_3_0: dcl of o0-o15 */
    D9VsDef defs[64]; int ndef;                        /* def c#: constants the shader sets itself */
} D9VsIO;
typedef struct {
    const D9VsIO *io;
    const float (*consts)[4]; uint32_t nconst;         /* the float constants (software vertex processing: up to 8192) */
    const int32_t (*iconsts)[4];
    const float (*in)[4];                              /* the inputs v0-v15 */
} D9VsEnv;
int d9_vs_parse(const uint32_t *code, size_t ntok, D9VsIO *io);   /* 0: can be interpreted */
/* runs the shader for one vertex: out = o0-o15 (vs_3_0), or (vs_1/2) oPos, oD0, oD1, oT0-oT7; 0 on success */
int d9_vs_run(const uint32_t *code, size_t ntok, const D9VsIO *io, const D9VsEnv *e, float out[16][4]);
