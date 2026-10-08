/* The game's own Direct3D 9 shaders (vs/ps 1.1-3.0 bytecode, as Fallout NV draws everything): each vertex/pixel
 * shader pair becomes one renderer program, translated once by MojoShader (third_party/mojoshader) to GLSL.
 *
 * DSR_GLSL_CREATE carries the program's vertex attributes (name -> attribute slot, the slots d3d9.c's programmable
 * draws use) and both sources. MojoShader packs the constant registers a shader reads into one uniform array per type
 * (vec4, ivec4, bool), in the order of its uniform list; DSR_SHADER_CONST sends exactly those, before each draw. The
 * pixel shader is wrapped so that D3D9's alpha test, which runs after it, still applies.
 *
 * On the Mac the same pair is translated to Metal (MojoShader's Metal profile; DSR_MSL_CREATE): the vertex shader reads
 * its inputs by register, so the command carries register -> attribute slot pairs; the same wrapping (pixel centres,
 * alpha test) is done on the MSL text, and outputs the pixel shader reads but the vertex shader never writes are added
 * as zero (Metal refuses such a pair, OpenGL reads undefined values). */
#include "d3d9_priv.h"
#include "mojoshader.h"
#include <pthread.h>
#include <ctype.h>

#define MAXPROG 4096
typedef struct Pack { int16_t index, count; } Pack;      /* registers [index, index + count) */
typedef struct Prog {
    Shader9 *vs, *ps; uint32_t id; int bad;
    Pack f[2][64], i[2][16], b[2][16]; int nf[2], ni[2], nb[2], tf[2], ti[2], tb[2];   /* per stage (0 vs, 1 ps): runs, totals */
} Prog;
static Prog progs[MAXPROG]; static int nprogs; static pthread_mutex_t plock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t next_id = 0x10000;                      /* above d3d9.c's effect program ids */

static int shlog(void) { static int on = -1; if (on < 0) on = getenv("D3D9_SHADERLOG") != 0; return on; }
static const MOJOSHADER_parseData *parse(Shader9 *s)
{
#ifdef __APPLE__
    const MOJOSHADER_parseData *pd = MOJOSHADER_parse(MOJOSHADER_PROFILE_METAL, s->ps ? "psmain" : "vsmain", G_MEM + s->mem, s->len, 0, 0, 0, 0, 0, 0, 0);
#else
    const MOJOSHADER_parseData *pd = MOJOSHADER_parse(MOJOSHADER_PROFILE_GLSL120, "main", G_MEM + s->mem, s->len, 0, 0, 0, 0, 0, 0, 0);
#endif
    if (pd->error_count) {
        static int n; if (n++ < 20) fprintf(stderr, "d3d9: %s shader %08x not translated: %s\n", s->ps ? "pixel" : "vertex", s->g, pd->errors[0].error);
        MOJOSHADER_freeParseData(pd); return 0;
    }
    return pd;
}
static void packs(Prog *p, int st, const MOJOSHADER_parseData *pd)
{
    for (int k = 0; k < pd->uniform_count; k++) {
        const MOJOSHADER_uniform *u = &pd->uniforms[k]; if (u->constant) continue;
        int n = u->array_count ? u->array_count : 1;
        Pack *runs = u->type == MOJOSHADER_UNIFORM_FLOAT ? p->f[st] : u->type == MOJOSHADER_UNIFORM_INT ? p->i[st] : p->b[st];
        int *nr = u->type == MOJOSHADER_UNIFORM_FLOAT ? &p->nf[st] : u->type == MOJOSHADER_UNIFORM_INT ? &p->ni[st] : &p->nb[st];
        int *tot = u->type == MOJOSHADER_UNIFORM_FLOAT ? &p->tf[st] : u->type == MOJOSHADER_UNIFORM_INT ? &p->ti[st] : &p->tb[st];
        int cap = u->type == MOJOSHADER_UNIFORM_FLOAT ? 64 : 16;
        if (*nr < cap) { runs[*nr].index = (int16_t)u->index; runs[*nr].count = (int16_t)n; (*nr)++; *tot += n; }
    }
}
static char *append(char *b, size_t *len, size_t *cap, const char *s, size_t n)
{
    if (*len + n + 1 > *cap) { *cap = (*len + n + 1) * 2; b = realloc(b, *cap); }
    memcpy(b + *len, s, n); *len += n; b[*len] = 0; return b;
}
/* the pixel shader with D3D9's alpha test after it (d3d_alphatest: reference, D3DCMP function, enabled) */
static char *wrap_ps(const char *src, size_t n, size_t *outlen)
{
    size_t len = 0, cap = n + 1024; char *o = malloc(cap); o[0] = 0;
    const char *m = strstr(src, "void main()"); if (!m) { o = append(o, &len, &cap, src, n); *outlen = len; return o; }
    o = append(o, &len, &cap, src, (size_t)(m - src));
    o = append(o, &len, &cap, "void d3d_main()", 15);
    const char *rest = m + 11; o = append(o, &len, &cap, rest, n - (size_t)(rest - src));
    const char *out = strstr(src, "gl_FragData[0]") ? "gl_FragData[0]" : "gl_FragColor";
    char tail[1024], nanpaint[256] = "";   /* D3D9_NANPAINT=nan|inf: such outputs painted magenta (debugging) */
    { const char *np = getenv("D3D9_NANPAINT");
      if (np) snprintf(nanpaint, sizeof nanpaint, strcmp(np, "inf") ? "\tif (any(notEqual(%s, %s))) %s = vec4(1.0, 0.0, 1.0, 1.0);\n"   /* GLSL 1.20: no isnan/isinf */
                                                                     : "\tif (any(greaterThan(abs(%s), vec4(3.0e38))) && %s == %s) %s = vec4(1.0, 0.0, 1.0, 1.0);\n", out, out, out, out); }
    int k = snprintf(tail, sizeof tail,
        "\nuniform vec4 d3d_alphatest;\n"
        "void main()\n{\n\td3d_main();\n"
        "\tif (d3d_alphatest.z != 0.0) {\n\t\tfloat a = floor(clamp(%s.a, 0.0, 1.0) * 255.0 + 0.5), r = d3d_alphatest.x; int f = int(d3d_alphatest.y); bool pass = true;\n"
        "\t\tif (f == 1) pass = false; else if (f == 2) pass = a < r; else if (f == 3) pass = a == r; else if (f == 4) pass = a <= r;\n"
        "\t\telse if (f == 5) pass = a > r; else if (f == 6) pass = a != r; else if (f == 7) pass = a >= r;\n"
        "\t\tif (!pass) discard;\n\t}\n%s}\n", out, nanpaint);
    o = append(o, &len, &cap, tail, (size_t)k); *outlen = len; return o;
}
/* the vertex shader with D3D9's pixel centres: D3D9 puts them on integer coordinates, GL half a pixel further, so
 * positions move by half a pixel (d3d_pixfix = 1/viewport width, -1/viewport height, before the render-target flip).
 * Games correct for D3D9 themselves (a 1x1 target's quad is shifted by half the target: without this, no pixel centre
 * is inside it at all, as FNV's eye-adaptation pass found) */
static char *wrap_vs(const char *src, size_t n, size_t *outlen)
{
    size_t len = 0, cap = n + 256; char *o = malloc(cap); o[0] = 0;
    const char *ver = strstr(src, "\n"), *flip = strstr(src, "\tgl_Position.y = gl_Position.y * vpFlip;");
    if (!ver || !flip) { o = append(o, &len, &cap, src, n); *outlen = len; return o; }
    o = append(o, &len, &cap, src, (size_t)(ver + 1 - src));
    /* invariant: the same position math gives the same bits in every program, as D3D drivers guarantee. FNV lights
     * characters in several passes that redraw them with depth test EQUAL; without it NVIDIA's compiler optimises each
     * program differently, a pass misses on scattered pixels, and they flicker (bright specks on Doc Mitchell, the player) */
    if (!getenv("D3D9_NO_INVARIANT")) o = append(o, &len, &cap, "invariant gl_Position;\n", 23);
    o = append(o, &len, &cap, "uniform vec4 d3d_pixfix;\n", 25);
    o = append(o, &len, &cap, ver + 1, (size_t)(flip - ver - 1));
    o = append(o, &len, &cap, "\tgl_Position.xy += d3d_pixfix.xy * gl_Position.w;\n", 50);
    o = append(o, &len, &cap, flip, n - (size_t)(flip - src));
    *outlen = len; return o;
}
/* A vertex shader without a pixel shader: Direct3D's fixed-function texture stages after it (The Sims 2 draws its UI
 * and much of its world this way). Stage s reads texture unit s with the shader's texture coordinates s (with a vertex
 * shader, D3DTSS_TEXCOORDINDEX must be the stage's own). The stage states arrive as the pixel constants (ff_consts):
 * per stage (colour op, colour arg 1, colour arg 2, alpha op), (alpha arg 1, alpha arg 2, texture bound, texture has no
 * alpha), then the texture factor and (specular enable, 0, 0, 0). Arguments are D3DTA source + 8 complement + 16
 * alpha replicate (GLSL 1.20 has no bit operations). */
#define FF_STAGES 4
#define FF_CONSTS (2 * FF_STAGES + 2)
static const char *FF_PS =
    "#version 120\n"
    "uniform vec4 ps_uniforms_vec4[10];\n"
    "uniform sampler2D ps_s0, ps_s1, ps_s2, ps_s3;\n"
    "vec4 ff_arg(float a, vec4 diffuse, vec4 current, vec4 texel, vec4 spec, vec4 temp)\n{\n"
    "\tfloat src = mod(a, 8.0); vec4 v = diffuse;\n"
    "\tif (src == 1.0) v = current; else if (src == 2.0) v = texel; else if (src == 3.0) v = ps_uniforms_vec4[8];\n"
    "\telse if (src == 4.0) v = spec; else if (src == 5.0) v = temp;\n"
    "\tif (mod(floor(a / 8.0), 2.0) == 1.0) v = 1.0 - v;\n"
    "\tif (a >= 16.0) v = vec4(v.a);\n"
    "\treturn v;\n}\n"
    "vec4 ff_op(float o, vec4 x, vec4 y, vec4 diffuse, vec4 texel, vec4 current)\n{\n"
    "\tif (o == 2.0) return x; if (o == 3.0) return y; if (o == 4.0) return x * y;\n"
    "\tif (o == 5.0) return clamp(x * y * 2.0, 0.0, 1.0); if (o == 6.0) return clamp(x * y * 4.0, 0.0, 1.0);\n"
    "\tif (o == 7.0) return clamp(x + y, 0.0, 1.0); if (o == 8.0) return clamp(x + y - 0.5, 0.0, 1.0);\n"
    "\tif (o == 9.0) return clamp((x + y - 0.5) * 2.0, 0.0, 1.0); if (o == 10.0) return clamp(x - y, 0.0, 1.0);\n"
    "\tif (o == 11.0) return clamp(x + y - x * y, 0.0, 1.0); if (o == 12.0) return mix(y, x, diffuse.a);\n"
    "\tif (o == 13.0) return mix(y, x, texel.a); if (o == 14.0) return mix(y, x, ps_uniforms_vec4[8].a);\n"
    "\tif (o == 15.0) return clamp(x + y * (1.0 - texel.a), 0.0, 1.0); if (o == 16.0) return mix(y, x, current.a);\n"
    "\tif (o == 18.0) return clamp(vec4(x.rgb + x.a * y.rgb, x.a), 0.0, 1.0); if (o == 19.0) return clamp(vec4(x.rgb * y.rgb + x.a, x.a), 0.0, 1.0);\n"
    "\tif (o == 20.0) return clamp(vec4(x.rgb + (1.0 - x.a) * y.rgb, x.a), 0.0, 1.0); if (o == 21.0) return clamp(vec4((1.0 - x.rgb) * y.rgb + x.a, x.a), 0.0, 1.0);\n"
    "\tif (o == 24.0) return vec4(clamp(4.0 * dot(x.rgb - 0.5, y.rgb - 0.5), 0.0, 1.0));\n"
    "\treturn x;\n}\n"
    "void main()\n{\n"
    "\tvec4 diffuse = gl_Color, spec = gl_SecondaryColor, current = diffuse, temp = vec4(0.0);\n"
    "\tfor (int s = 0; s < 4; s++) {\n"
    "\t\tvec4 c = ps_uniforms_vec4[2 * s], a = ps_uniforms_vec4[2 * s + 1];\n"
    "\t\tif (c.x == 1.0) break;\n"
    "\t\tvec4 texel = vec4(1.0);\n"
    "\t\tif (a.z != 0.0) {\n"
    "\t\t\tif (s == 0) texel = texture2D(ps_s0, gl_TexCoord[0].xy); else if (s == 1) texel = texture2D(ps_s1, gl_TexCoord[1].xy);\n"
    "\t\t\telse if (s == 2) texel = texture2D(ps_s2, gl_TexCoord[2].xy); else texel = texture2D(ps_s3, gl_TexCoord[3].xy);\n"
    "\t\t\tif (a.w != 0.0) texel.a = 1.0;\n"
    "\t\t}\n"
    "\t\tvec4 rc = ff_op(c.x, ff_arg(c.y, diffuse, current, texel, spec, temp), ff_arg(c.z, diffuse, current, texel, spec, temp), diffuse, texel, current);\n"
    "\t\tvec4 ra = c.w == 1.0 ? current : ff_op(c.w, ff_arg(a.x, diffuse, current, texel, spec, temp), ff_arg(a.y, diffuse, current, texel, spec, temp), diffuse, texel, current);\n"
    "\t\tcurrent = vec4(rc.rgb, ra.a);\n"
    "\t}\n"
    "\tif (ps_uniforms_vec4[9].x != 0.0) current.rgb = clamp(current.rgb + spec.rgb, 0.0, 1.0);\n"
    "\tgl_FragColor = current;\n}\n";
#ifdef __APPLE__
/* ---- Metal (MojoShader's Metal profile): the same wrapping, on MSL text ---- */
static const char *FF_MSL_PS =                              /* a vertex shader without a pixel shader: FF_PS in Metal */
    "#include <metal_stdlib>\nusing namespace metal;\n\n"
    "struct psmain_Uniforms\n{\n    float4 uniforms_float4[10];\n};\n\n"
    "struct psmain_Input\n{\n    float4 d0 [[user(color0)]];\n    float4 d1 [[user(color1)]];\n"
    "    float4 t0 [[user(texcoord0)]];\n    float4 t1 [[user(texcoord1)]];\n    float4 t2 [[user(texcoord2)]];\n    float4 t3 [[user(texcoord3)]];\n};\n\n"
    "struct psmain_Output\n{\n    float4 oC0 [[color(0)]];\n};\n\n"
    "static float4 ff_arg(float a, float4 diffuse, float4 current, float4 texel, float4 spec, float4 temp, float4 tf)\n{\n"
    "    float src = fmod(a, 8.0); float4 v = diffuse;\n"
    "    if (src == 1.0) v = current; else if (src == 2.0) v = texel; else if (src == 3.0) v = tf;\n"
    "    else if (src == 4.0) v = spec; else if (src == 5.0) v = temp;\n"
    "    if (fmod(floor(a / 8.0), 2.0) == 1.0) v = 1.0 - v;\n"
    "    if (a >= 16.0) v = float4(v.a);\n"
    "    return v;\n}\n"
    "static float4 ff_op(float o, float4 x, float4 y, float4 diffuse, float4 texel, float4 current, float4 tf)\n{\n"
    "    if (o == 2.0) return x; if (o == 3.0) return y; if (o == 4.0) return x * y;\n"
    "    if (o == 5.0) return saturate(x * y * 2.0); if (o == 6.0) return saturate(x * y * 4.0);\n"
    "    if (o == 7.0) return saturate(x + y); if (o == 8.0) return saturate(x + y - 0.5);\n"
    "    if (o == 9.0) return saturate((x + y - 0.5) * 2.0); if (o == 10.0) return saturate(x - y);\n"
    "    if (o == 11.0) return saturate(x + y - x * y); if (o == 12.0) return mix(y, x, diffuse.a);\n"
    "    if (o == 13.0) return mix(y, x, texel.a); if (o == 14.0) return mix(y, x, tf.a);\n"
    "    if (o == 15.0) return saturate(x + y * (1.0 - texel.a)); if (o == 16.0) return mix(y, x, current.a);\n"
    "    if (o == 18.0) return saturate(float4(x.rgb + x.a * y.rgb, x.a)); if (o == 19.0) return saturate(float4(x.rgb * y.rgb + x.a, x.a));\n"
    "    if (o == 20.0) return saturate(float4(x.rgb + (1.0 - x.a) * y.rgb, x.a)); if (o == 21.0) return saturate(float4((1.0 - x.rgb) * y.rgb + x.a, x.a));\n"
    "    if (o == 24.0) return float4(saturate(4.0 * dot(x.rgb - 0.5, y.rgb - 0.5)));\n"
    "    return x;\n}\n"
    "fragment psmain_Output psmain (\n    psmain_Input input [[stage_in]],\n    constant psmain_Uniforms &uniforms [[buffer(0)]],\n"
    "    texture2d<float> s0 [[texture(0)]], sampler s0s [[sampler(0)]], texture2d<float> s1 [[texture(1)]], sampler s1s [[sampler(1)]],\n"
    "    texture2d<float> s2 [[texture(2)]], sampler s2s [[sampler(2)]], texture2d<float> s3 [[texture(3)]], sampler s3s [[sampler(3)]]\n) {\n"
    "    psmain_Output output;\n"
    "    float4 diffuse = input.d0, spec = input.d1, current = diffuse, temp = float4(0.0), tf = uniforms.uniforms_float4[8];\n"
    "    for (int s = 0; s < 4; s++) {\n"
    "        float4 c = uniforms.uniforms_float4[2 * s], a = uniforms.uniforms_float4[2 * s + 1];\n"
    "        if (c.x == 1.0) break;\n"
    "        float4 texel = float4(1.0);\n"
    "        if (a.z != 0.0) {\n"
    "            if (s == 0) texel = s0.sample(s0s, input.t0.xy); else if (s == 1) texel = s1.sample(s1s, input.t1.xy);\n"
    "            else if (s == 2) texel = s2.sample(s2s, input.t2.xy); else texel = s3.sample(s3s, input.t3.xy);\n"
    "            if (a.w != 0.0) texel.a = 1.0;\n"
    "        }\n"
    "        float4 rc = ff_op(c.x, ff_arg(c.y, diffuse, current, texel, spec, temp, tf), ff_arg(c.z, diffuse, current, texel, spec, temp, tf), diffuse, texel, current, tf);\n"
    "        float4 ra = c.w == 1.0 ? current : ff_op(c.w, ff_arg(a.x, diffuse, current, texel, spec, temp, tf), ff_arg(a.y, diffuse, current, texel, spec, temp, tf), diffuse, texel, current, tf);\n"
    "        current = float4(rc.rgb, ra.a);\n"
    "    }\n"
    "    if (uniforms.uniforms_float4[9].x != 0.0) current.rgb = saturate(current.rgb + spec.rgb);\n"
    "    output.oC0 = current;\n    return output;\n}\n";
/* the member of the output struct with attribute att ("[[position]]", "[[color(0)]]"), into name; 0 if none */
static int member_with(const char *src, const char *att, char *name, size_t cap)
{
    const char *a = strstr(src, att); if (!a) return 0;
    const char *e = a; while (e > src && e[-1] == ' ') e--;
    const char *b = e; while (b > src && (isalnum((unsigned char)b[-1]) || b[-1] == '_')) b--;
    if (b == e || (size_t)(e - b) >= cap) return 0;
    memcpy(name, b, (size_t)(e - b)); name[e - b] = 0; return 1;
}
/* src with text added: decl as one more argument of the entry point, code before every "return output;" */
static char *msl_wrap(const char *src, const char *entry, const char *decl, const char *code)
{
    size_t len = 0, cap = strlen(src) * 2 + 2048; char *o = malloc(cap); o[0] = 0;
    char sig[64]; snprintf(sig, sizeof sig, " %s (\n", entry);
    const char *sg = strstr(src, sig), *end = sg ? strstr(sg, "\n) {\n") : 0;
    if (!sg || !end) { o = append(o, &len, &cap, src, strlen(src)); return o; }
    const char *args = sg + strlen(sig), *last = end; while (last > args && isspace((unsigned char)last[-1])) last--;
    o = append(o, &len, &cap, src, (size_t)(last - src));
    if (last > args && last[-1] != ',') o = append(o, &len, &cap, ",", 1);
    o = append(o, &len, &cap, "\n    ", 5); o = append(o, &len, &cap, decl, strlen(decl));
    for (const char *q = end; *q; ) {
        const char *ret = strstr(q, "return output;");
        if (!ret) { o = append(o, &len, &cap, q, strlen(q)); break; }
        o = append(o, &len, &cap, q, (size_t)(ret - q)); o = append(o, &len, &cap, code, strlen(code));
        o = append(o, &len, &cap, "return output;", 14); q = ret + 14;
    }
    return o;
}
/* user(...) names in a struct of the source (the vertex shader's outputs or the pixel shader's inputs) */
static int user_names(const char *src, const char *strct, char names[][32], int cap)
{
    const char *st = strstr(src, strct), *se = st ? strstr(st, "};") : 0; int n = 0;
    for (const char *q = st; q && q < se && n < cap; ) {
        const char *u = strstr(q, "[[user("); if (!u || u > se) break;
        u += 7; const char *e = strchr(u, ')'); if (!e || e - u >= 31) break;
        memcpy(names[n], u, (size_t)(e - u)); names[n][e - u] = 0; n++; q = e;
    }
    return n;
}
/* the vertex shader: D3D9 pixel centres (d3d_pixfix, buffer 1), an invariant position (the multi-pass lighting draws
 * with depth test EQUAL, see wrap_vs), and every output the pixel shader reads */
static char *msl_vs(const char *vs, const char *ps)
{
    char pos[64], pins[32][32], vouts[32][32]; int np = ps ? user_names(ps, "struct psmain_Input", pins, 32) : 0, nv = user_names(vs, "struct vsmain_Output", vouts, 32);
    size_t len = 0, cap = strlen(vs) + 4096; char *t = malloc(cap); t[0] = 0;
    char fill[2048] = ""; size_t fl = 0;
    const char *ost = strstr(vs, "struct vsmain_Output\n{\n"), *oend = ost ? strstr(ost, "};") : 0;
    if (ost && oend) {                                       /* missing outputs: declared, and written as zero */
        t = append(t, &len, &cap, vs, (size_t)(oend - vs));
        for (int k = 0; k < np; k++) {
            int have = 0; for (int j = 0; j < nv; j++) if (!strcmp(pins[k], vouts[j])) have = 1;
            if (have) continue;
            char m[128]; int n = snprintf(m, sizeof m, "    float4 d3d_fill%d [[user(%s)]];\n", k, pins[k]); t = append(t, &len, &cap, m, (size_t)n);
            fl += (size_t)snprintf(fill + fl, sizeof fill - fl, "    output.d3d_fill%d = float4(0.0);\n", k);
        }
        t = append(t, &len, &cap, oend, strlen(oend));
    } else t = append(t, &len, &cap, vs, strlen(vs));
    char code[2400] = "";
    if (member_with(t, "[[position]]", pos, sizeof pos)) {
        if (!getenv("D3D9_NO_INVARIANT")) {
            char *p = strstr(t, "[[position]]"); size_t at = (size_t)(p - t);   /* [[position]] -> [[position, invariant]] */
            char *u = malloc(len + 32); memcpy(u, t, at); strcpy(u + at, "[[position, invariant]]"); strcpy(u + at + 23, t + at + 12); free(t); t = u;
        }
        snprintf(code, sizeof code, "%s    output.%s.xy += d3d_pixfix.xy * output.%s.w;\n    ", fill, pos, pos);
    } else snprintf(code, sizeof code, "%s    ", fill);
    char *o = msl_wrap(t, "vsmain", "constant float4 &d3d_pixfix [[buffer(1)]]", code); free(t); return o;
}
/* the pixel shader with D3D9's alpha test after it (d3d_alphatest, buffer 1: reference, D3DCMP function, enabled) */
static char *msl_ps(const char *ps)
{
    char col[64], code[1024];
    if (!member_with(ps, "[[color(0)]]", col, sizeof col)) return msl_wrap(ps, "psmain", "constant float4 &d3d_alphatest [[buffer(1)]]", "");
    snprintf(code, sizeof code,
        "if (d3d_alphatest.z != 0.0) {\n"
        "        float d3d_a = floor(clamp(output.%s.a, 0.0, 1.0) * 255.0 + 0.5), d3d_r = d3d_alphatest.x; int d3d_f = int(d3d_alphatest.y); bool d3d_pass = true;\n"
        "        if (d3d_f == 1) d3d_pass = false; else if (d3d_f == 2) d3d_pass = d3d_a < d3d_r; else if (d3d_f == 3) d3d_pass = d3d_a == d3d_r; else if (d3d_f == 4) d3d_pass = d3d_a <= d3d_r;\n"
        "        else if (d3d_f == 5) d3d_pass = d3d_a > d3d_r; else if (d3d_f == 6) d3d_pass = d3d_a != d3d_r; else if (d3d_f == 7) d3d_pass = d3d_a >= d3d_r;\n"
        "        if (!d3d_pass) discard_fragment();\n    }\n    ", col);
    return msl_wrap(ps, "psmain", "constant float4 &d3d_alphatest [[buffer(1)]]", code);
}
#endif

static int slot_of(int usage, int index)               /* d3d9.c sem_slot(): the attribute slots of programmable draws */
{
    switch (usage) {
    case MOJOSHADER_USAGE_POSITION: case MOJOSHADER_USAGE_POSITIONT: return index ? -1 : 0;
    case MOJOSHADER_USAGE_NORMAL: return index ? -1 : 1;
    case MOJOSHADER_USAGE_COLOR: return index < 2 ? 2 + index : -1;
    case MOJOSHADER_USAGE_TEXCOORD: return index < 8 ? 4 + index : -1;
    case MOJOSHADER_USAGE_TANGENT: return index ? -1 : 12;
    case MOJOSHADER_USAGE_BINORMAL: return index ? -1 : 13;
    case MOJOSHADER_USAGE_BLENDWEIGHT: return index ? -1 : 14;
    case MOJOSHADER_USAGE_BLENDINDICES: return index ? -1 : 15;
    default: return -1;
    }
}
static void create(Prog *p)
{
    const MOJOSHADER_parseData *v = parse(p->vs), *f = p->ps ? parse(p->ps) : 0;
    if (!v || (p->ps && !f)) { p->bad = 1; if (v) MOJOSHADER_freeParseData(v); if (f) MOJOSHADER_freeParseData(f); return; }
    packs(p, 0, v); if (f) packs(p, 1, f);
    else { p->f[1][0].index = 0; p->f[1][0].count = FF_CONSTS; p->nf[1] = 1; p->tf[1] = FF_CONSTS; }   /* ff_consts */
#ifdef __APPLE__
    {   /* Metal: register -> slot pairs, the wrapped sources */
        char *ps = msl_ps(f ? f->output : FF_MSL_PS), *vs = msl_vs(v->output, ps);
        uint32_t na = 0, at[16][2];
        for (int k = 0; k < v->attribute_count && na < 16; k++) {
            int sl = slot_of(v->attributes[k].usage, v->attributes[k].index); const char *nm = v->attributes[k].name, *dg = nm;
            while (dg && *dg && !isdigit((unsigned char)*dg)) dg++;
            if (sl < 0 || !dg || !*dg) { if (shlog()) fprintf(stderr, "d3d9: vertex shader %08x: input usage %d/%d has no slot\n", p->vs->g, v->attributes[k].usage, v->attributes[k].index); continue; }
            at[na][0] = (uint32_t)sl; at[na][1] = (uint32_t)atoi(dg); na++;
        }
        uint32_t vl = (uint32_t)strlen(vs), pl = (uint32_t)strlen(ps), size = 16 + 8 * na + ((vl + 4) & ~3u) + ((pl + 4) & ~3u);
        p->id = next_id++;
        uint32_t *c = cmd_begin(DSR_MSL_CREATE, size);
        c[0] = p->id; c[1] = na; c[2] = vl; c[3] = pl; memcpy(c + 4, at, 8 * (size_t)na);
        char *sp = (char *)(c + 4 + 2 * na); memcpy(sp, vs, vl); sp[vl] = 0; sp += (vl + 4) & ~3u; memcpy(sp, ps, pl); sp[pl] = 0;
        cmd_end();
        { const char *dir = getenv("D3D9_MSL_DUMP"); if (dir) { char path[1024]; snprintf(path, sizeof path, "%s/prog%u.metal", dir, p->id); FILE *o = fopen(path, "w");   /* D3D9_MSL_DUMP=<dir>: the sources */
            if (o) { fprintf(o, "%s\n// ---- pixel ----\n%s", vs, ps); fclose(o); } } }
        if (shlog()) fprintf(stderr, "d3d9: program %u: vs %08x + ps %08x, %u attributes, constants vs %d/%d/%d ps %d/%d/%d\n", p->id, p->vs->g,
                             p->ps ? p->ps->g : 0, na, p->tf[0], p->ti[0], p->tb[0], p->tf[1], p->ti[1], p->tb[1]);
        free(ps); free(vs); MOJOSHADER_freeParseData(v); if (f) MOJOSHADER_freeParseData(f);
        return;
    }
#endif
    size_t pslen; char *ps = f ? wrap_ps(f->output, (size_t)f->output_len, &pslen) : wrap_ps(FF_PS, strlen(FF_PS), &pslen);
    size_t vslen; char *vs = wrap_vs(v->output, (size_t)v->output_len, &vslen);
    int na = 0; struct { uint32_t slot; char name[28]; } at[16];
    for (int k = 0; k < v->attribute_count && na < 16; k++) {
        int sl = slot_of(v->attributes[k].usage, v->attributes[k].index);
        if (sl < 0 || !v->attributes[k].name) { if (shlog()) fprintf(stderr, "d3d9: vertex shader %08x: input usage %d/%d has no slot\n", p->vs->g, v->attributes[k].usage, v->attributes[k].index); continue; }
        at[na].slot = (uint32_t)sl; memset(at[na].name, 0, 28); snprintf(at[na].name, 28, "%s", v->attributes[k].name); na++;
        if (shlog()) fprintf(stderr, "d3d9: program %u input %s = usage %d/%d -> slot %d\n", next_id, v->attributes[k].name, v->attributes[k].usage, v->attributes[k].index, sl);
    }
    uint32_t vl = (uint32_t)vslen, pl = (uint32_t)pslen, size = 16 + 32 * (uint32_t)na + ((vl + 4) & ~3u) + ((pl + 4) & ~3u);
    p->id = next_id++;
    uint32_t *c = cmd_begin(DSR_GLSL_CREATE, size);
    c[0] = p->id; c[1] = (uint32_t)na; c[2] = vl; c[3] = pl;
    memcpy(c + 4, at, 32 * (size_t)na);
    char *s = (char *)(c + 4 + 8 * na); memcpy(s, vs, vl); s[vl] = 0;
    s += (vl + 4) & ~3u; memcpy(s, ps, pl); s[pl] = 0;
    cmd_end();
    if (shlog()) fprintf(stderr, "d3d9: program %u: vs %08x + ps %08x, %d attributes, constants vs %d/%d/%d ps %d/%d/%d\n", p->id, p->vs->g,
                         p->ps ? p->ps->g : 0, na, p->tf[0], p->ti[0], p->tb[0], p->tf[1], p->ti[1], p->tb[1]);
    free(ps); free(vs); MOJOSHADER_freeParseData(v); if (f) MOJOSHADER_freeParseData(f);
}
/* the bound shaders' program, created on first use; 0 if they could not be translated */
uint32_t d9_shader_program(Dev9 *d)
{
    pthread_mutex_lock(&plock);
    Prog *p = 0;
    for (int k = 0; k < nprogs; k++) if (progs[k].vs == d->vs && progs[k].ps == d->ps) { p = &progs[k]; break; }
    if (!p && nprogs < MAXPROG) { p = &progs[nprogs++]; memset(p, 0, sizeof *p); p->vs = d->vs; p->ps = d->ps; create(p); }
    uint32_t id = p && !p->bad ? p->id : 0;
    pthread_mutex_unlock(&plock);
    return id;
}
/* a shader is released: forget its programs (the renderer keeps them; ids are not reused) */
void d9_shader_forget(Shader9 *s)
{
    pthread_mutex_lock(&plock);
    for (int k = 0; k < nprogs; ) if (progs[k].vs == s || progs[k].ps == s) progs[k] = progs[--nprogs]; else k++;
    pthread_mutex_unlock(&plock);
}
/* the fixed-function stages as FF_PS's constants */
static void ff_consts(Dev9 *d, float out[FF_CONSTS][4])
{
    memset(out, 0, sizeof(float) * 4 * FF_CONSTS);
    for (int s = 0; s < FF_STAGES; s++) {
        const uint32_t *t = d->tss[s];
        #define FF_ARG(a) ((float)(((a) & 7) + (((a) >> 4) & 1) * 8 + (((a) >> 5) & 1) * 16))
        out[2 * s][0] = (float)t[1]; out[2 * s][1] = FF_ARG(t[2]); out[2 * s][2] = FF_ARG(t[3]); out[2 * s][3] = (float)t[4];
        out[2 * s + 1][0] = FF_ARG(t[5]); out[2 * s + 1][1] = FF_ARG(t[6]);
        out[2 * s + 1][2] = d->tex[s] ? 1.0f : 0.0f; out[2 * s + 1][3] = d->tex[s] && !d9_fmt_alpha(d->tex[s]->fmt) ? 1.0f : 0.0f;
        #undef FF_ARG
    }
    uint32_t tf = d->rs[60];                               /* D3DRS_TEXTUREFACTOR, ARGB */
    out[2 * FF_STAGES][0] = ((tf >> 16) & 255) / 255.0f; out[2 * FF_STAGES][1] = ((tf >> 8) & 255) / 255.0f;
    out[2 * FF_STAGES][2] = (tf & 255) / 255.0f; out[2 * FF_STAGES][3] = (tf >> 24) / 255.0f;
    out[2 * FF_STAGES + 1][0] = d->rs[29] ? 1.0f : 0.0f;  /* D3DRS_SPECULARENABLE */
}
/* DSR_SHADER_CONST: u32 vs float4 count, ps float4 count, vs int4, ps int4, vs bool, ps bool; float4 vs[], ps[];
 * int4 vs[], ps[]; u32 vs[], ps[]; then float4 alpha test (reference 0-255, function, enabled, 0) */
void d9_shader_consts(Dev9 *d, uint32_t id)
{
    Prog *p = 0;
    pthread_mutex_lock(&plock);
    for (int k = 0; k < nprogs; k++) if (progs[k].id == id) { p = &progs[k]; break; }
    if (!p) { pthread_mutex_unlock(&plock); return; }
    Prog q = *p; pthread_mutex_unlock(&plock);
    uint32_t words = 6 + 4u * (uint32_t)(q.tf[0] + q.tf[1] + q.ti[0] + q.ti[1]) + (uint32_t)(q.tb[0] + q.tb[1]) + 4;
    uint32_t *c = cmd_begin(DSR_SHADER_CONST, 4 * words), *w = c + 6;
    c[0] = (uint32_t)q.tf[0]; c[1] = (uint32_t)q.tf[1]; c[2] = (uint32_t)q.ti[0]; c[3] = (uint32_t)q.ti[1]; c[4] = (uint32_t)q.tb[0]; c[5] = (uint32_t)q.tb[1];
    float ff[FF_CONSTS][4]; if (!q.ps) ff_consts(d, ff);
    for (int st = 0; st < 2; st++) for (int r = 0; r < q.nf[st]; r++) {
        if (st && !q.ps) { memcpy(w, ff, sizeof ff); w += 4 * FF_CONSTS; continue; }
        int max = st ? 224 : 256;
        for (int k = 0; k < q.f[st][r].count; k++) { int reg = q.f[st][r].index + k; if (reg < max) memcpy(w, st ? d->psc[reg] : d->vsc[reg], 16); else memset(w, 0, 16); w += 4; }
    }
    for (int st = 0; st < 2; st++) for (int r = 0; r < q.ni[st]; r++)
        for (int k = 0; k < q.i[st][r].count; k++) { int reg = q.i[st][r].index + k; if (reg < 16) memcpy(w, st ? d->psi[reg] : d->vsi[reg], 16); else memset(w, 0, 16); w += 4; }
    for (int st = 0; st < 2; st++) for (int r = 0; r < q.nb[st]; r++)
        for (int k = 0; k < q.b[st][r].count; k++) { int reg = q.b[st][r].index + k; *w++ = reg < 16 ? (st ? d->psb[reg] : d->vsb[reg]) : 0; }
    float at[4] = {(float)(d->rs[24] & 255), (float)d->rs[25], d->rs[15] ? 1.0f : 0.0f, 0}; memcpy(w, at, 16);
    cmd_end();
}
