// DSR native renderer core: Direct3D 7 fixed-function state + DirectDraw surfaces on Metal.
#import "renderer.h"
#import <QuartzCore/QuartzCore.h>
#include "../dsr/dsr_proto.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

volatile int dsr_flash_frame; int dsr_verbose; long dsr_stat[8]; double dsr_gpu_ms[100000]; int dsr_frame;
#define MAXSURF 65536
#define STAGE_SURF (MAXSURF - 2)    /* pixels for a scaled surface, before they are drawn into it larger (and reads, smaller) */
/* w, h: the game's size of a surface. sc: how much larger its texture is (the interface size, DSR_RENDER_SCALE: the game
 * runs at a smaller resolution, so its interface is laid out larger, and its screen-sized surfaces are drawn that much
 * larger, at the display's own resolution). Positions stay in the game's units everywhere; they become texture pixels
 * only where Metal is given a viewport, an upload or a copy. */
typedef struct { id<MTLTexture> tex, view2d, sview; uint32_t w, h, kind, fmt, level, root, slice; int used, fxrt; float sc; } Surf;   /* sview: float formats as sampled (missing channels 1, as D3D9) */   /* fxrt: an effect pass drew into it (DSR_GLOWLOG) */   /* cube faces: tex the cube, view2d the face as 2D */
static inline id<MTLTexture> tex2d(const void *sp) { const Surf *s = sp; return s->view2d ? s->view2d : s->tex; }
typedef struct {   // must match shaders.metal Uniforms
    float wvp[16], wv[16], tex0[16];
    float vp[4], fog[4], fogcolor[4], tfactor[4];
    int32_t c0[4], a0[4], c1[4], a1[4];
    float at[4];
    int32_t misc[4];
    int32_t xrgb[4];     // texture stage 0/1 is XRGB (alpha reads as 1)
    float tex1[16];      // texture-1 transform
    int32_t s1[4];       // stage 1: texcoordindex, texturetransformflags
    float tex2[16];      // texture-2 transform
    int32_t c2[4], a2[4];   // stage 2: colorop, colorarg1, colorarg2, alphaop / alphaarg1, alphaarg2
    int32_t s2[4];       // stage 2: texcoordindex, texturetransformflags, has a texture, XRGB
} Uniforms;

struct DSRRenderer {
    /* DSR_FLASHLOG=1: every shown frame sampled 32x32 (as seen: gamma applied) and checked for a white screen or a sudden
     * flash; what drew the frame (effect programs, fixed-function draws, target switches, white clears) is logged with it */
    int fl_on; id<MTLTexture> fl_probe[4]; int fl_i; uint32_t fl_prog[24][2]; int fl_np; uint32_t fl_ff, fl_rtsw, fl_wclear, fl_draws_fx;
    float scale; uint32_t mode_w, mode_h;   /* the interface size (1: none) and the game's display mode */
    id<MTLDevice> dev; id<MTLCommandQueue> q; id<MTLLibrary> lib;
    Surf s[MAXSURF];
    uint32_t rs[256], tss[16][32]; float xf[32][16]; float vp[6]; uint32_t tex[16];
    uint32_t rt, ds;
    id<MTLCommandBuffer> cb, last_cb; id<MTLRenderCommandEncoder> enc; id<MTLBlitCommandEncoder> blit; uint32_t enc_rt, enc_ds, encoders; uint64_t cb_bytes;
    id<MTLBuffer> ring; uint32_t ring_off, ring_size; id<MTLBuffer> white;
    /* pipeline, depth and sampler states by key: open-addressing tables (keys never 0), no Objective-C boxing per draw */
    uint64_t pso_k[1024]; id<MTLRenderPipelineState> pso_v[1024];
    uint64_t dso_k[64]; id<MTLDepthStencilState> dso_v[64];
    uint32_t smp_k[1024]; id<MTLSamplerState> smp_v[1024]; int pso_n, dso_n, smp_n; uint32_t pso_last;   // filled at most 3/4, then uncached
    /* the current render encoder's state, so unchanged state isn't set again (cleared with each new encoder) */
    struct { __unsafe_unretained id pso, dso, tex[3], smp[3]; int cull, ring_bound; uint32_t sref; MTLViewport vp; } es;
    id<MTLRenderPipelineState> quad_pso, quad_over_pso, zclear_pso, present_pso; id<MTLTexture> scratch, gamma_lut; uint16_t gamma[3][256]; int gamma_dirty; id<MTLDepthStencilState> zclear_ds, nodepth_ds, zsclear_ds[4];
    id<MTLSamplerState> point_clamp, linear_clamp; id<MTLTexture> dummy;
    id<MTLTexture> cur_tex; int32_t cur_x, cur_y, cur_hx, cur_hy, cur_show;   /* DSR_CURSOR */
    /* effect programs (DSR_PROG_*): Metal compiled from the game's HLSL effects (runtime/win32/hlsl.c) */
    struct { id<MTLFunction> vs, fs; uint32_t kinds; } prog[1024]; uint32_t cur_prog;
    float pconst[4096 * 4]; uint32_t npconst;
    uint64_t ppso_k[512]; id<MTLRenderPipelineState> ppso_v[512]; int ppso_n;
    id<MTLBuffer> attr_defaults; id<MTLTexture> dummy_cube, dummy_3d;
    uint32_t presented;
    id<MTLBuffer> rb_buf; volatile uint32_t *rb_done;
    double present_ts;
    id<MTLRenderPipelineState> graph_pso; const float *g_a, *g_b; int g_ha, g_hb, g_on;
    /* the game's own shader pairs (DSR_MSL_CREATE; Fallout: New Vegas): see "game shaders" below */
    struct GP *gp; uint32_t gp_cur; uint8_t vcb[65536], pcb[16384];   /* MojoShader repeats a relative-addressed array from its base to c255: The Sims 2's skinning shaders take ~17 KB */ uint32_t vcb_len, pcb_len; float atest[4]; int32_t scissor[4];
    uint64_t gpso_k[4096]; id<MTLRenderPipelineState> gpso_v[4096]; int gpso_n;
    uint64_t gdso_k[256]; id<MTLDepthStencilState> gdso_v[256]; int gdso_n;
    id<MTLBuffer> vb[DSR_VBUFS]; uint64_t vb_use[DSR_VBUFS];   /* kept vertex/index buffers (DSR_VBUF_DATA); the command buffer that last used each */
    uint64_t cb_serial; volatile uint64_t done_serial;          /* command buffers made, and finished on the GPU */
    id<MTLBuffer> vis; uint32_t vis_next; volatile uint32_t *qres; int qactive; uint32_t qseg[64], nqseg;   /* occlusion queries (DSR_QUERY) */
};

static void mat_ident(float *m) { memset(m, 0, 64); m[0] = m[5] = m[10] = m[15] = 1; }
static void mat_mul(float *o, const float *a, const float *b)   // D3D row-major: o = a * b
{
    float t[16]; for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) { float s = 0; for (int k = 0; k < 4; k++) s += a[r * 4 + k] * b[k * 4 + c]; t[r * 4 + c] = s; }
    memcpy(o, t, 64);
}

static NSString *shader_source(void)
{
    NSString *path = [[[NSProcessInfo processInfo] arguments][0] stringByDeletingLastPathComponent];
    NSString *src = [NSString stringWithContentsOfFile:[path stringByAppendingPathComponent:@"shaders.metal"] encoding:NSUTF8StringEncoding error:nil];
    if (!src) src = [NSString stringWithContentsOfFile:@"shaders.metal" encoding:NSUTF8StringEncoding error:nil];
    return src;
}

DSRRenderer *dsr_renderer_create(id<MTLDevice> dev)
{
    DSRRenderer *r = calloc(1, sizeof *r); NSError *err = nil;
    r->dev = dev; r->q = [dev newCommandQueue];
    r->lib = [dev newLibraryWithSource:shader_source() options:nil error:&err];
    if (!r->lib) { fprintf(stderr, "shader compile failed: %s\n", err.localizedDescription.UTF8String); exit(1); }
    r->ring_size = 256u << 20;
    { const char *mb = getenv("DSR_RINGMB"); if (mb && atoi(mb) >= 4 && atoi(mb) <= 256) r->ring_size = (uint32_t)atoi(mb) << 20; }   /* development: a small ring wraps often */ r->ring = [dev newBufferWithLength:r->ring_size options:MTLResourceStorageModeShared];
    { uint32_t w = 0xffffffff; r->white = [dev newBufferWithBytes:&w length:16 options:MTLResourceStorageModeShared]; }
    r->fl_on = getenv("DSR_FLASHLOG") != 0;
    { const char *sc = getenv("DSR_RENDER_SCALE"); r->scale = sc ? (float)atof(sc) : 1; if (!(r->scale >= 1 && r->scale <= 3)) r->scale = 1; }
    for (int k = 0; k < 32; k++) mat_ident(r->xf[k]);
    for (int k = 0; k < 256; k++) r->rs[k] = 0;
    r->rs[168] = 15; r->rs[56] = 8; r->rs[58] = r->rs[59] = 0xff; r->rs[53] = r->rs[54] = r->rs[55] = 1; r->rs[7] = 1; r->rs[14] = 1; r->rs[23] = 4; r->rs[22] = 3; r->rs[19] = 2; r->rs[20] = 1; r->rs[25] = 8;   // ZENABLE, ZWRITE, ZFUNC LEQUAL, CULL CCW, SRC ONE, DST ZERO, AFUNC ALWAYS
    for (int st = 0; st < 16; st++) { r->tss[st][1] = st ? 1 : 4; r->tss[st][2] = 2; r->tss[st][3] = 1; r->tss[st][4] = st ? 1 : 2; r->tss[st][5] = 2; r->tss[st][6] = 1;
                                     r->tss[st][11] = st; r->tss[st][13] = r->tss[st][14] = 1; r->tss[st][16] = r->tss[st][17] = 2; r->tss[st][18] = 1; }
    {   MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [r->lib newFunctionWithName:@"vs_quad"]; d.fragmentFunction = [r->lib newFunctionWithName:@"fs_quad"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        r->quad_pso = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        d.colorAttachments[0].blendingEnabled = YES;   // premultiplied "over" for DSR_UPLOAD_OVER
        d.colorAttachments[0].sourceRGBBlendFactor = d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        d.colorAttachments[0].destinationRGBBlendFactor = d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        r->quad_over_pso = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        d.colorAttachments[0].blendingEnabled = NO;
        d.vertexFunction = [r->lib newFunctionWithName:@"vs_zclear"]; d.fragmentFunction = nil;
        d.colorAttachments[0].writeMask = MTLColorWriteMaskNone; d.depthAttachmentPixelFormat = d.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        r->zclear_pso = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        if (!r->quad_pso || !r->zclear_pso) { fprintf(stderr, "helper pipelines: %s\n", err.localizedDescription.UTF8String); exit(1); }
        MTLDepthStencilDescriptor *z = [MTLDepthStencilDescriptor new]; z.depthCompareFunction = MTLCompareFunctionAlways; z.depthWriteEnabled = YES;
        r->zclear_ds = [dev newDepthStencilStateWithDescriptor:z];
        z.depthWriteEnabled = NO; r->nodepth_ds = [dev newDepthStencilStateWithDescriptor:z];
        for (int k = 1; k < 4; k++) {                       // clears: [1] depth, [2] stencil, [3] both (stencil = the reference value)
            MTLDepthStencilDescriptor *c = [MTLDepthStencilDescriptor new]; c.depthCompareFunction = MTLCompareFunctionAlways; c.depthWriteEnabled = (k & 1) != 0;
            if (k & 2) { MTLStencilDescriptor *sd = [MTLStencilDescriptor new]; sd.stencilCompareFunction = MTLCompareFunctionAlways;
                         sd.depthStencilPassOperation = MTLStencilOperationReplace; sd.writeMask = 0xff; c.frontFaceStencil = c.backFaceStencil = sd; }
            r->zsclear_ds[k] = [dev newDepthStencilStateWithDescriptor:c];
        } }
    {   MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [r->lib newFunctionWithName:@"vs_present"]; d.fragmentFunction = [r->lib newFunctionWithName:@"fs_present"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        r->present_pso = [dev newRenderPipelineStateWithDescriptor:d error:&err];
        if (!r->present_pso) { fprintf(stderr, "present pipeline: %s\n", err.localizedDescription.UTF8String); exit(1); }
        MTLTextureDescriptor *g = [MTLTextureDescriptor new]; g.textureType = MTLTextureType1D; g.pixelFormat = MTLPixelFormatRGBA16Unorm; g.width = 256;
        g.storageMode = MTLStorageModeShared; r->gamma_lut = [dev newTextureWithDescriptor:g];
        for (int k = 0; k < 256; k++) r->gamma[0][k] = r->gamma[1][k] = r->gamma[2][k] = k * 0x101;
        r->gamma_dirty = 1; }
    {   MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new]; sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        r->point_clamp = [dev newSamplerStateWithDescriptor:sd]; sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; r->linear_clamp = [dev newSamplerStateWithDescriptor:sd]; }
    {   MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
        r->dummy = [dev newTextureWithDescriptor:td];
        MTLTextureDescriptor *sd2 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:256 height:256 mipmapped:NO];
        sd2.storageMode = MTLStorageModePrivate; sd2.usage = MTLTextureUsageShaderRead; r->scratch = [dev newTextureWithDescriptor:sd2]; uint32_t white = 0xffffffff;
        [r->dummy replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&white bytesPerRow:4];
        MTLTextureDescriptor *cd = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm size:1 mipmapped:NO];
        r->dummy_cube = [dev newTextureWithDescriptor:cd];
        for (NSUInteger f = 0; f < 6; f++) [r->dummy_cube replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 slice:f withBytes:&white bytesPerRow:4 bytesPerImage:4];
        MTLTextureDescriptor *vd = [MTLTextureDescriptor new]; vd.textureType = MTLTextureType3D; vd.pixelFormat = MTLPixelFormatBGRA8Unorm; vd.width = vd.height = vd.depth = 1;
        r->dummy_3d = [dev newTextureWithDescriptor:vd]; [r->dummy_3d replaceRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1) mipmapLevel:0 slice:0 withBytes:&white bytesPerRow:4 bytesPerImage:4];
        /* vertex attributes a draw doesn't supply: (0, 0, 0, 1), except colour 0 white and colour 1 black (as D3D) */
        float def[16][4]; for (int k = 0; k < 16; k++) { def[k][0] = def[k][1] = def[k][2] = 0; def[k][3] = 1; }
        def[2][0] = def[2][1] = def[2][2] = 1; def[3][3] = 0;
        r->attr_defaults = [dev newBufferWithBytes:def length:sizeof def options:MTLResourceStorageModeShared]; }
    r->vis = [dev newBufferWithLength:8192 * 8 options:MTLResourceStorageModeShared];   /* occlusion queries' counts (VIS_SLOTS) */
    return r;
}

// ---------- command buffer / encoder ----------
static id<MTLCommandBuffer> cmdbuf(DSRRenderer *r) { if (!r->cb) { r->cb = [r->q commandBuffer]; r->encoders = 0; r->cb_bytes = 0; r->cb_serial++; } return r->cb; }
static void end_enc(DSRRenderer *r)
{
    if (r->enc) { [r->enc endEncoding]; r->enc = nil; }
    if (r->blit) { [r->blit endEncoding]; r->blit = nil; }
}
static void commit(DSRRenderer *r)
{
    end_enc(r);
    if (r->cb) {
        if (dsr_verbose) [r->cb addCompletedHandler:^(id<MTLCommandBuffer> cb) { if (cb.error) fprintf(stderr, "command buffer error: %s\n", cb.error.localizedDescription.UTF8String); }];
        int f = dsr_frame; [r->cb addCompletedHandler:^(id<MTLCommandBuffer> cb) { if (f < 100000) dsr_gpu_ms[f] += (cb.GPUEndTime - cb.GPUStartTime) * 1000.0; }];
        { uint64_t serial = r->cb_serial; volatile uint64_t *done = &r->done_serial;   /* kept buffers the GPU no longer reads may be written in place */
          [r->cb addCompletedHandler:^(id<MTLCommandBuffer> cb) { (void)cb; uint64_t d = __atomic_load_n(done, __ATOMIC_ACQUIRE); if (serial > d) __atomic_store_n(done, serial, __ATOMIC_RELEASE); }]; }
        [r->cb commit]; r->last_cb = r->cb; r->cb = nil;
    }
}
// Long resource-only stretches (level loading) would otherwise pile thousands of encoders into one command buffer.
static void maybe_commit(DSRRenderer *r) { if (r->cb && (r->encoders > 512 || r->cb_bytes > (64u << 20))) commit(r); }
static void *ring_alloc(DSRRenderer *r, uint32_t n, uint32_t *off)
{
    n = (n + 255) & ~255u;
    if (r->ring_off + n > r->ring_size) {   // wrap: make sure the GPU is done with the old contents
        commit(r); if (r->last_cb) [r->last_cb waitUntilCompleted];
        r->ring_off = 0;
    }
    *off = r->ring_off; r->ring_off += n; r->cb_bytes += n; return (uint8_t *)r->ring.contents + *off;
}
/* Room for everything one draw takes from the ring (vertices, indices, uniforms, constants, a fan's indices), made
 * before the draw sets any encoder state: a wrap in the middle of a draw commits, which ends the encoder, and the draw
 * then went to a new encoder without its pipeline (a crash in the GPU driver every few minutes of play). */
static void ring_room(DSRRenderer *r, uint64_t n)
{
    n += 6 * 256;                                   /* each allocation rounds up to 256 */
    if (n > r->ring_size) return;
    if (r->ring_off + n > r->ring_size) { commit(r); if (r->last_cb) [r->last_cb waitUntilCompleted]; r->ring_off = 0; }
}
static id<MTLBlitCommandEncoder> blit_enc(DSRRenderer *r)
{
    if (r->enc) { [r->enc endEncoding]; r->enc = nil; }
    if (!r->blit) { r->blit = [cmdbuf(r) blitCommandEncoder]; r->encoders++; }
    return r->blit;
}
static Surf *surf(DSRRenderer *r, uint32_t id) { return (id && id < MAXSURF && r->s[id].used) ? &r->s[id] : NULL; }
static void query_segment(DSRRenderer *r);
/* d3d9.c's surface formats (DSR_SURFACE_CREATE): 1 ARGB8, 2 XRGB8, 3 depth/stencil, 4-9 R16F RG16F RGBA16F R32F RG32F RGBA32F */
static MTLPixelFormat surf_pf(uint32_t fmt)
{
    static const MTLPixelFormat f[6] = {MTLPixelFormatR16Float, MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float, MTLPixelFormatR32Float, MTLPixelFormatRG32Float, MTLPixelFormatRGBA32Float};
    return fmt == 3 ? MTLPixelFormatDepth32Float_Stencil8 : fmt >= 4 && fmt <= 9 ? f[fmt - 4] : MTLPixelFormatBGRA8Unorm;
}
/* a float format as Direct3D 9 samples it: missing channels read 1 (R16F: r, 1, 1, 1) */
static void float_view(Surf *s)
{
    if (s->fmt < 4 || s->fmt > 9 || (s->fmt - 4) % 3 == 2) return;
    int ch = (int)(s->fmt - 4) % 3;
    MTLTextureSwizzleChannels sw = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, ch ? MTLTextureSwizzleGreen : MTLTextureSwizzleOne, MTLTextureSwizzleOne, MTLTextureSwizzleOne);
    s->sview = [s->tex newTextureViewWithPixelFormat:s->tex.pixelFormat textureType:s->tex.textureType levels:NSMakeRange(0, s->tex.mipmapLevelCount)
                                                slices:NSMakeRange(0, s->tex.textureType == MTLTextureTypeCube ? 6 : 1) swizzle:sw];
}
static inline id<MTLTexture> tex_sampled(const Surf *s) { return s->sview ? s->sview : tex2d(s); }   /* a 2D texture as shaders read it */
/* The depth buffer a target is drawn with: as Direct3D allows, one larger than the target (the game draws its 256x256
 * glow target with the screen's), but not one smaller, which Metal can't (an unscaled depth buffer with a target
 * enlarged by the interface size): then none. Draws ask the same, so their pipelines match the pass. */
static Surf *depth_with(DSRRenderer *r, Surf *c, Surf *z)
{
    (void)r; if (!c || !z) return z;
    NSUInteger cw = MAX(c->tex.width >> c->level, 1u), ch = MAX(c->tex.height >> c->level, 1u);
    return z->tex.width < cw || z->tex.height < ch ? NULL : z;
}
static id<MTLRenderCommandEncoder> enc_for(DSRRenderer *r, uint32_t rt, uint32_t ds)
{
    if (r->enc && r->enc_rt == rt && r->enc_ds == ds) return r->enc;
    end_enc(r); maybe_commit(r);
    Surf *c = surf(r, rt), *z = surf(r, ds); if (!c) return nil;
    z = depth_with(r, c, z);
    MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture = c->tex; p.colorAttachments[0].loadAction = MTLLoadActionLoad; p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].slice = c->slice; p.colorAttachments[0].level = c->level;
    if (z) { p.depthAttachment.texture = z->tex; p.depthAttachment.loadAction = MTLLoadActionLoad; p.depthAttachment.storeAction = MTLStoreActionStore;
             p.stencilAttachment.texture = z->tex; p.stencilAttachment.loadAction = MTLLoadActionLoad; p.stencilAttachment.storeAction = MTLStoreActionStore; }
    if (r->vis) p.visibilityResultBuffer = r->vis;
    r->enc = [cmdbuf(r) renderCommandEncoderWithDescriptor:p]; r->enc_rt = rt; r->enc_ds = z ? ds : 0; r->encoders++;
    memset(&r->es, 0, sizeof r->es); r->es.cull = -1;
    [r->enc setFrontFacingWinding:MTLWindingClockwise];   // same convention as D3D
    if (r->qactive) query_segment(r);
    return r->enc;
}

// ---------- surfaces ----------
static void surface_create(DSRRenderer *r, const uint32_t *p, uint32_t size)
{
    uint32_t id = p[0], w = p[1], h = p[2], kind = p[3], fmt = p[4], parent = p[5], level = p[6];
    uint32_t face = size >= 40 ? p[8] : 0, cube = size >= 40 && (p[9] & 1);
    if (id >= MAXSURF) return;
    Surf *s = &r->s[id]; s->tex = s->view2d = s->sview = nil; s->used = 1; s->fxrt = 0; s->w = w; s->h = h; s->kind = kind; s->fmt = fmt; s->level = level; s->root = id; s->slice = face; s->sc = 1;
    /* the screen's surfaces (the back buffer, depth buffers and textures the size of the screen, which the game draws into
     * with the screen's depth buffer) are drawn larger with an interface size */
    float sc = r->scale > 1 && !parent && !cube && w == r->mode_w && h == r->mode_h && !(kind == 3 && size >= 32 && p[7] > 1) ? r->scale : 1;
    uint32_t pw = (uint32_t)lroundf(w * sc), ph = (uint32_t)lroundf(h * sc);
    if (parent && surf(r, parent)) {                       // a mip level (or another cube face): shares the root's texture
        Surf *root = surf(r, parent); s->tex = root->tex; s->root = parent; s->sview = root->sview;
        if (cube && level == 0)                            // a cube face: its own 2D view
            s->view2d = [s->tex newTextureViewWithPixelFormat:s->tex.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0, s->tex.mipmapLevelCount) slices:NSMakeRange(face, 1)];
        else s->view2d = root->view2d;
        return;
    }
    if (kind == 3 && parent == 0 && cube) {
        uint32_t levels = p[7] ? p[7] : 1;
        MTLTextureDescriptor *d = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm size:w mipmapped:levels > 1];
        d.mipmapLevelCount = levels; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView; d.storageMode = MTLStorageModePrivate;
        s->tex = [r->dev newTextureWithDescriptor:d];
        s->view2d = [s->tex newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm textureType:MTLTextureType2D levels:NSMakeRange(0, levels) slices:NSMakeRange(0, 1)];
    } else if (kind == 3 && parent == 0) {
        uint32_t levels = size >= 32 && p[7] ? p[7] : 1;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:surf_pf(fmt == 3 ? 1 : fmt) width:pw height:ph mipmapped:levels > 1];
        d.mipmapLevelCount = levels; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView; d.storageMode = MTLStorageModePrivate;   // XRGB: alpha forced to 1 in the shader (swizzles can't be render targets)
        s->tex = [r->dev newTextureWithDescriptor:d]; s->sc = sc; float_view(s);
    } else {
        MTLPixelFormat pf = surf_pf(fmt);                    // depth buffers carry an 8-bit stencil; render targets may be floating point
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:pw height:ph mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView; d.storageMode = MTLStorageModePrivate;   // XRGB targets: alpha is never read back as destination alpha
        s->tex = [r->dev newTextureWithDescriptor:d]; s->sc = sc; float_view(s);
    }
}
static void quad(DSRRenderer *r, uint32_t dst, const int32_t *drect, uint32_t src, const int32_t *srect, int fill, uint32_t color);
static Surf *stage(DSRRenderer *r, uint32_t w, uint32_t h)   /* an unscaled texture at least w x h (STAGE_SURF) */
{
    Surf *g = &r->s[STAGE_SURF];
    if (!g->tex || g->tex.width < w || g->tex.height < h) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:MAX(w, g->tex.width) height:MAX(h, g->tex.height) mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
        g->tex = [r->dev newTextureWithDescriptor:d]; g->view2d = nil; g->used = 1; g->kind = 4; g->fmt = 1; g->level = 0; g->root = STAGE_SURF; g->slice = 0; g->sc = 1;
    }
    g->w = (uint32_t)g->tex.width; g->h = (uint32_t)g->tex.height; return g;
}
static void surface_upload(DSRRenderer *r, const uint32_t *p, uint32_t size)
{
    Surf *s = surf(r, p[0]); if (!s || s->fmt == 3 || s->fmt >= 4) return;     /* (float render targets are never uploaded) */
    uint32_t x = p[1], y = p[2], w = p[3], h = p[4], pitch = p[5], off;
    if (!w || !h || 24 + (uint64_t)pitch * h > size) return;                     /* 64-bit: no wrap */
    if (s->sc != 1) {                                                            /* a scaled target: its pixels go to the stage first */
        if ((uint64_t)x + w > s->w || (uint64_t)y + h > s->h) return;
        Surf *g = stage(r, w, h);
        if (!r->enc) maybe_commit(r);
        void *dst = ring_alloc(r, pitch * h, &off); memcpy(dst, p + 6, pitch * h);
        [blit_enc(r) copyFromBuffer:r->ring sourceOffset:off sourceBytesPerRow:pitch sourceBytesPerImage:pitch * h sourceSize:MTLSizeMake(w, h, 1)
                toTexture:g->tex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        int32_t dr[4] = {(int32_t)x, (int32_t)y, (int32_t)(x + w), (int32_t)(y + h)}, sr[4] = {0, 0, (int32_t)w, (int32_t)h};
        quad(r, p[0], dr, STAGE_SURF, sr, 0, 0);
        return;
    }
    if (s->level >= s->tex.mipmapLevelCount || (uint64_t)x + w > (s->tex.width >> s->level ?: 1) || (uint64_t)y + h > (s->tex.height >> s->level ?: 1)) return;
    if (!r->enc) maybe_commit(r);
    void *dst = ring_alloc(r, pitch * h, &off); memcpy(dst, p + 6, pitch * h);
    [blit_enc(r) copyFromBuffer:r->ring sourceOffset:off sourceBytesPerRow:pitch sourceBytesPerImage:pitch * h sourceSize:MTLSizeMake(w, h, 1)
            toTexture:s->tex destinationSlice:s->slice destinationLevel:s->level destinationOrigin:MTLOriginMake(x, y, 0)];
}

// ---------- quads (blits, fills) ----------
// The game composited its cursor over zeros (see surface.c): the pixels are premultiplied, alpha = coverage.
static void upload_over(DSRRenderer *r, const uint32_t *p, uint32_t size)
{
    Surf *s = surf(r, p[0]); uint32_t x = p[1], y = p[2], w = p[3], h = p[4], pitch = p[5], off;
    if (!s || !w || !h || 24 + (uint64_t)pitch * h > size) return;
    if (w > 256 || h > 256) { surface_upload(r, p, size); return; }
    if ((uint64_t)x + w > s->w || (uint64_t)y + h > s->h) return;
    if (!r->enc) maybe_commit(r);
    void *dst = ring_alloc(r, pitch * h, &off); memcpy(dst, p + 6, pitch * h);
    [blit_enc(r) copyFromBuffer:r->ring sourceOffset:off sourceBytesPerRow:pitch sourceBytesPerImage:pitch * h sourceSize:MTLSizeMake(w, h, 1)
            toTexture:r->scratch destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    int32_t dr[4] = {(int32_t)x, (int32_t)y, (int32_t)(x + w), (int32_t)(y + h)}, sr[4] = {0, 0, (int32_t)w, (int32_t)h};
    quad(r, p[0], dr, 0, sr, 2, 0);
}
/* the helper pipelines (0 the quad, 1 the "over" quad, 2 the depth/stencil clear) for a colour target of another format
 * than the screen's (the game's floating-point render targets) */
static id<MTLRenderPipelineState> helper_pso(DSRRenderer *r, int kind, MTLPixelFormat pf)
{
    if (pf == MTLPixelFormatBGRA8Unorm) return kind == 0 ? r->quad_pso : kind == 1 ? r->quad_over_pso : r->zclear_pso;
    static uint64_t k_[64]; static __strong id<MTLRenderPipelineState> v_[64]; static int n_;
    uint64_t key = (uint64_t)pf << 8 | (uint64_t)kind;
    for (int k = 0; k < n_; k++) if (k_[k] == key) return v_[k];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; NSError *err = nil;
    d.colorAttachments[0].pixelFormat = pf;
    if (kind < 2) {
        d.vertexFunction = [r->lib newFunctionWithName:@"vs_quad"]; d.fragmentFunction = [r->lib newFunctionWithName:@"fs_quad"];
        if (kind == 1) { d.colorAttachments[0].blendingEnabled = YES; d.colorAttachments[0].sourceRGBBlendFactor = d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
                         d.colorAttachments[0].destinationRGBBlendFactor = d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha; }
    } else {
        d.vertexFunction = [r->lib newFunctionWithName:@"vs_zclear"]; d.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
        d.depthAttachmentPixelFormat = d.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    }
    id<MTLRenderPipelineState> p = [r->dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) { fprintf(stderr, "dsr: helper pipeline %d for format %lu: %s\n", kind, (unsigned long)pf, err.localizedDescription.UTF8String); return nil; }
    if (n_ < 64) { k_[n_] = key; v_[n_] = p; n_++; }
    return p;
}
static void quad(DSRRenderer *r, uint32_t dst, const int32_t *drect, uint32_t src, const int32_t *srect, int fill, uint32_t color)
{
    Surf *d = surf(r, dst), *s = surf(r, src); if (!d || d->fmt == 3 || !(d->tex.usage & MTLTextureUsageRenderTarget)) return;
    struct { float dst[4], src[4], color[4]; int32_t mode[4]; } q;
    q.dst[0] = drect[0] / (float)d->w; q.dst[1] = drect[1] / (float)d->h; q.dst[2] = drect[2] / (float)d->w; q.dst[3] = drect[3] / (float)d->h;
    if (fill == 2) { q.src[0] = srect[0] / 256.0f; q.src[1] = srect[1] / 256.0f; q.src[2] = srect[2] / 256.0f; q.src[3] = srect[3] / 256.0f; }
    else if (s) { float sw = s->w, sh = s->h; q.src[0] = srect[0] / sw; q.src[1] = srect[1] / sh; q.src[2] = srect[2] / sw; q.src[3] = srect[3] / sh; }
    q.color[0] = ((color >> 16) & 255) / 255.0f; q.color[1] = ((color >> 8) & 255) / 255.0f; q.color[2] = (color & 255) / 255.0f; q.color[3] = ((color >> 24) & 255) / 255.0f;
    q.mode[0] = fill == 1;
    id<MTLRenderPipelineState> qp = helper_pso(r, fill == 2 ? 1 : 0, d->tex.pixelFormat); if (!qp) return;
    id<MTLRenderCommandEncoder> e = enc_for(r, dst, 0); if (!e) return;
    [e setRenderPipelineState:qp]; [e setDepthStencilState:r->nodepth_ds]; [e setCullMode:MTLCullModeNone];
    [e setViewport:(MTLViewport){0, 0, d->w * d->sc, d->h * d->sc, 0, 1}];                   /* texture pixels (a scaled target: larger) */
    [e setVertexBytes:&q length:sizeof q atIndex:0]; [e setFragmentBytes:&q length:sizeof q atIndex:0];
    float ssc = fill == 2 || !s ? 1 : s->sc;                                                  /* scaled one way or the other: filtered */
    [e setFragmentTexture:fill == 2 ? r->scratch : s ? tex2d(s) : r->dummy atIndex:0]; [e setFragmentSamplerState:ssc != d->sc ? r->linear_clamp : r->point_clamp atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    memset(&r->es, 0, sizeof r->es); r->es.cull = -1;   // the draw-state cache no longer matches the encoder
}

// ---------- fixed-function draws ----------
static MTLBlendFactor bf(uint32_t b)
{
    switch (b) { case 1: return MTLBlendFactorZero; case 2: return MTLBlendFactorOne; case 3: return MTLBlendFactorSourceColor; case 4: return MTLBlendFactorOneMinusSourceColor;
    case 5: return MTLBlendFactorSourceAlpha; case 6: return MTLBlendFactorOneMinusSourceAlpha; case 7: return MTLBlendFactorDestinationAlpha; case 8: return MTLBlendFactorOneMinusDestinationAlpha;
    case 9: return MTLBlendFactorDestinationColor; case 10: return MTLBlendFactorOneMinusDestinationColor; case 11: return MTLBlendFactorSourceAlphaSaturated; default: return MTLBlendFactorOne; }
}
static MTLCompareFunction cmpf(uint32_t f)
{
    switch (f) { case 1: return MTLCompareFunctionNever; case 2: return MTLCompareFunctionLess; case 3: return MTLCompareFunctionEqual; case 4: return MTLCompareFunctionLessEqual;
    case 5: return MTLCompareFunctionGreater; case 6: return MTLCompareFunctionNotEqual; case 7: return MTLCompareFunctionGreaterEqual; default: return MTLCompareFunctionAlways; }
}
/* a target without alpha (XRGB, the back buffer too): D3D reads its destination alpha as 1 */
static uint32_t target_bf(DSRRenderer *r, uint32_t b)
{
    Surf *t = surf(r, r->rt); if (!t || t->fmt != 2) return b;
    return b == 7 ? 2 : b == 8 ? 1 : b;                     /* DESTALPHA -> ONE, INVDESTALPHA -> ZERO */
}
static id<MTLRenderPipelineState> pipeline_for(DSRRenderer *r, uint32_t fvf, int has_depth)
{
    uint32_t blend = r->rs[27] ? 1 : 0, sb = blend ? target_bf(r, r->rs[19]) : 2, db = blend ? target_bf(r, r->rs[20]) : 1;
    uint32_t atest = r->rs[15] ? 1 : 0;                                                       // D3DRS_ALPHATESTENABLE
    uint32_t cw = r->rs[168] & 15;                                                            // D3DRS_COLORWRITEENABLE (R1 G2 B4 A8)
    Surf *ct = surf(r, r->rt); MTLPixelFormat cpf = ct ? ct->tex.pixelFormat : MTLPixelFormatBGRA8Unorm;
    uint64_t key = ((uint64_t)fvf << 32) | (uint64_t)cw << 20 | (blend << 16) | (sb << 8) | (db << 4) | atest << 2 | (uint64_t)has_depth << 1 | 1;   // never 0
    if (cpf != MTLPixelFormatBGRA8Unorm) key ^= (uint64_t)cpf << 25;
    if (key == r->pso_k[r->pso_last]) return r->pso_v[r->pso_last];                                         // same as the last draw
    uint32_t h = (uint32_t)((key * 0x9e3779b97f4a7c15ull) >> 54);
    while (r->pso_k[h] && r->pso_k[h] != key) h = (h + 1) & 1023;
    if (r->pso_k[h]) { r->pso_last = h; return r->pso_v[h]; }
    id<MTLRenderPipelineState> p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; NSError *err = nil;
    d.vertexFunction = [r->lib newFunctionWithName:@"vs_main"];
    {   MTLFunctionConstantValues *fc = [MTLFunctionConstantValues new]; bool at = atest; [fc setConstantValue:&at type:MTLDataTypeBool atIndex:0];
        d.fragmentFunction = [r->lib newFunctionWithName:@"fs_main" constantValues:fc error:&err]; }
    d.colorAttachments[0].pixelFormat = cpf;
    if (has_depth) d.depthAttachmentPixelFormat = d.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    d.colorAttachments[0].writeMask = (cw & 1 ? MTLColorWriteMaskRed : 0) | (cw & 2 ? MTLColorWriteMaskGreen : 0) | (cw & 4 ? MTLColorWriteMaskBlue : 0) | (cw & 8 ? MTLColorWriteMaskAlpha : 0);
    if (blend) { d.colorAttachments[0].blendingEnabled = YES; d.colorAttachments[0].sourceRGBBlendFactor = d.colorAttachments[0].sourceAlphaBlendFactor = bf(sb);
                 d.colorAttachments[0].destinationRGBBlendFactor = d.colorAttachments[0].destinationAlphaBlendFactor = bf(db); }
    MTLVertexDescriptor *v = [MTLVertexDescriptor vertexDescriptor]; uint32_t off = 0;
    int rhw = (fvf & 0xe) == 4;
    v.attributes[0].format = rhw ? MTLVertexFormatFloat4 : MTLVertexFormatFloat3; v.attributes[0].offset = 0; v.attributes[0].bufferIndex = 0; off = rhw ? 16 : 12;
    if (fvf & 0x10) off += 12;                                                            // normal (unused: lighting off)
    if (fvf & 0x40) { v.attributes[1].format = MTLVertexFormatUChar4Normalized_BGRA; v.attributes[1].offset = off; v.attributes[1].bufferIndex = 0; off += 4; }
    else { v.attributes[1].format = MTLVertexFormatUChar4Normalized_BGRA; v.attributes[1].offset = 0; v.attributes[1].bufferIndex = 2; }
    if (fvf & 0x80) off += 4;                                                             // specular (unused)
    if ((fvf >> 8) & 0xf) { v.attributes[2].format = MTLVertexFormatFloat2; v.attributes[2].offset = off; v.attributes[2].bufferIndex = 0; }
    else { v.attributes[2].format = MTLVertexFormatFloat2; v.attributes[2].offset = 0; v.attributes[2].bufferIndex = 2; }
    uint32_t stride = off; for (uint32_t n = (fvf >> 8) & 0xf, k = 0; k < n; k++) { uint32_t f = (fvf >> (16 + 2 * k)) & 3; stride += f == 0 ? 8 : f == 1 ? 12 : f == 2 ? 16 : 4; }
    v.layouts[0].stride = stride;
    if (!(fvf & 0x40) || !((fvf >> 8) & 0xf)) { v.layouts[2].stride = 16; v.layouts[2].stepFunction = MTLVertexStepFunctionConstant; v.layouts[2].stepRate = 0; }
    d.vertexDescriptor = v;
    double t0 = CACurrentMediaTime();
    p = [r->dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) { fprintf(stderr, "pipeline fvf %x: %s\n", fvf, err.localizedDescription.UTF8String); return nil; }
    static int psolog = -1; if (psolog < 0) psolog = getenv("DSR_PSOLOG") != 0;
    if (psolog) fprintf(stderr, "dsr: new pipeline %#llx in %.1f ms (frame %d)\n", (unsigned long long)key, (CACurrentMediaTime() - t0) * 1000, dsr_frame);
    if (r->pso_n < 768) { r->pso_k[h] = key; r->pso_v[h] = p; r->pso_n++; r->pso_last = h; }   // the game uses a few dozen
    return p;
}
static MTLStencilOperation sop(uint32_t o)
{
    switch (o) { case 2: return MTLStencilOperationZero; case 3: return MTLStencilOperationReplace; case 4: return MTLStencilOperationIncrementClamp;
    case 5: return MTLStencilOperationDecrementClamp; case 6: return MTLStencilOperationInvert; case 7: return MTLStencilOperationIncrementWrap;
    case 8: return MTLStencilOperationDecrementWrap; default: return MTLStencilOperationKeep; }
}
/* depth test/write and the stencil test (D3DRS_STENCIL*: 52 enable, 53 fail, 54 z-fail, 55 pass, 56 function, 58 read
 * mask, 59 write mask; the reference, 57, is set on the encoder) */
static id<MTLDepthStencilState> depth_for(DSRRenderer *r)
{
    uint32_t en = r->rs[7] ? 1 : 0, wr = en && r->rs[14] ? 1 : 0, fn = en ? r->rs[23] : 8, st = r->rs[52] ? 1 : 0;
    uint64_t key = (uint64_t)(en << 16 | wr << 8 | fn << 1 | 1);
    if (st) key |= (uint64_t)1 << 20 | (uint64_t)(r->rs[53] & 15) << 24 | (uint64_t)(r->rs[54] & 15) << 28 | (uint64_t)(r->rs[55] & 15) << 32
                 | (uint64_t)(r->rs[56] & 15) << 36 | (uint64_t)(r->rs[58] & 255) << 40 | (uint64_t)(r->rs[59] & 255) << 48;
    uint32_t h = (uint32_t)((key * 0x9e3779b97f4a7c15ull) >> 58);
    while (r->dso_k[h] && r->dso_k[h] != key) h = (h + 1) & 63;
    if (r->dso_k[h]) return r->dso_v[h];
    id<MTLDepthStencilState> s;
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new]; d.depthCompareFunction = en ? cmpf(fn) : MTLCompareFunctionAlways; d.depthWriteEnabled = wr;
    if (st) {
        MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
        sd.stencilCompareFunction = cmpf(r->rs[56]); sd.stencilFailureOperation = sop(r->rs[53]); sd.depthFailureOperation = sop(r->rs[54]);
        sd.depthStencilPassOperation = sop(r->rs[55]); sd.readMask = r->rs[58] & 255; sd.writeMask = r->rs[59] & 255;
        d.frontFaceStencil = d.backFaceStencil = sd;
    }
    s = [r->dev newDepthStencilStateWithDescriptor:d]; if (r->dso_n < 48) { r->dso_k[h] = key; r->dso_v[h] = s; r->dso_n++; } return s;
}
static id<MTLSamplerState> sampler_for(DSRRenderer *r, int st)
{
    uint32_t au = r->tss[st][13], av = r->tss[st][14], mag = r->tss[st][16], min = r->tss[st][17], mip = r->tss[st][18];
    uint32_t key = ((au << 16) | (av << 12) | (mag << 8) | (min << 4) | mip) << 1 | 1, h = (key * 2654435761u) >> 22;
    while (r->smp_k[h] && r->smp_k[h] != key) h = (h + 1) & 1023;
    if (r->smp_k[h]) return r->smp_v[h];
    id<MTLSamplerState> s;
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    MTLSamplerAddressMode (^am)(uint32_t) = ^MTLSamplerAddressMode(uint32_t a) { return a == 2 ? MTLSamplerAddressModeMirrorRepeat : a == 3 ? MTLSamplerAddressModeClampToEdge : a == 4 ? MTLSamplerAddressModeClampToBorderColor : MTLSamplerAddressModeRepeat; };
    d.sAddressMode = am(au); d.tAddressMode = am(av);
    d.magFilter = mag >= 2 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest; d.minFilter = min >= 2 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.mipFilter = mip == 3 ? MTLSamplerMipFilterLinear : mip == 2 ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterNotMipmapped;
    s = [r->dev newSamplerStateWithDescriptor:d]; if (r->smp_n < 768) { r->smp_k[h] = key; r->smp_v[h] = s; r->smp_n++; } return s;
}
static void draw(DSRRenderer *r, const uint32_t *p, uint32_t size)
{
    uint32_t prim = p[0], fvf = p[1], nv = p[2], ni = p[3], stride = 0, voff, ioff = 0;
    { int rhw = (fvf & 0xe) == 4; stride = rhw ? 16 : 12; if (fvf & 0x10) stride += 12; if (fvf & 0x40) stride += 4; if (fvf & 0x80) stride += 4;
      for (uint32_t n = (fvf >> 8) & 0xf, k = 0; k < n; k++) { uint32_t f = (fvf >> (16 + 2 * k)) & 3; stride += f == 0 ? 8 : f == 1 ? 12 : f == 2 ? 16 : 4; } }
    dsr_stat[0]++;
    static int drawlog = -1; if (drawlog < 0) drawlog = getenv("DSR_DRAWLOG") != 0;
    if (drawlog) {   /* each distinct kind of draw once (development) */
        static uint64_t seen[512]; static int ns;
        uint64_t key = ((uint64_t)prim << 56) ^ ((uint64_t)fvf << 24) ^ ((uint64_t)r->rs[27] << 20) ^ ((uint64_t)r->rs[19] << 12) ^ ((uint64_t)r->rs[20] << 8)
                     ^ ((uint64_t)r->tss[0][1] << 4) ^ (uint64_t)r->tss[1][1] ^ ((uint64_t)r->rs[15] << 40) ^ ((uint64_t)r->rs[14] << 44);
        int dup = 0; for (int k = 0; k < ns; k++) if (seen[k] == key) dup = 1;
        if (!dup && ns < 512) { seen[ns++] = key;
            fprintf(stderr, "draw: prim %u fvf %#x nv %u ni %u | blend %u src %u dst %u atest %u zwrite %u zfunc %u | st0 op %u/%u tci %#x ttf %#x tex %u | st1 op %u/%u ttf %#x tex %u\n",
                    prim, fvf, nv, ni, r->rs[27], r->rs[19], r->rs[20], r->rs[15], r->rs[14], r->rs[23], r->tss[0][1], r->tss[0][4], r->tss[0][11], r->tss[0][24], r->tex[0],
                    r->tss[1][1], r->tss[1][4], r->tss[1][24], r->tex[1]); }
    }
    if (!nv || 16 + (uint64_t)nv * stride + (uint64_t)ni * 2 > size) { dsr_stat[1]++; return; }   /* 64-bit: no wrap */
    if (prim == 6 && (ni ? ni : nv) < 3) return;                                 /* a fan of fewer than 3: nothing (as D3D) */
    ring_room(r, (uint64_t)nv * stride + (uint64_t)ni * 2 + sizeof(Uniforms) + (uint64_t)(ni ? ni : nv) * 6);
    { static int na = -1, nb = -1; if (na < 0) { na = nb = getenv("DSR_GLOWLOG") ? 400 : 0; } Surf *t_ = surf(r, r->rt), *x0_ = surf(r, r->tex[0]);
      int into = t_ && t_->fxrt, add = r->rs[27] && r->rs[19] == 2 && r->rs[20] == 2 && x0_ && x0_->fxrt;
      if ((into && na > 0) || (add && nb > 0)) { if (into) na--; else nb--; float fs, fe; memcpy(&fs, &r->rs[36], 4); memcpy(&fe, &r->rs[37], 4);
        fprintf(stderr, "glow %s rt %u (%ux%u) fvf %x nv %u: fog %u %u/%u | blend %u %u/%u cw %x z %u/%u | tf %08x st0 %u/%u,%u a%u/%u,%u st1 %u/%u | tex0 %u\n",
                into ? "draw into" : "add from", r->rt, t_ ? t_->w : 0, t_ ? t_->h : 0, fvf, nv, r->rs[28], r->rs[35], r->rs[140], r->rs[27], r->rs[19], r->rs[20], r->rs[168],
                r->rs[7], r->rs[14], r->rs[60], r->tss[0][1], r->tss[0][2], r->tss[0][3], r->tss[0][4], r->tss[0][5], r->tss[0][6], r->tss[1][1], r->tss[1][4], r->tex[0]); } }
    Surf *rt = surf(r, r->rt), *ds = surf(r, r->ds); if (!rt) { dsr_stat[2]++; return; }
    ds = depth_with(r, rt, ds);
    id<MTLRenderPipelineState> pso = pipeline_for(r, fvf, ds != NULL); if (!pso) { dsr_stat[3]++; return; }
    id<MTLRenderCommandEncoder> e = enc_for(r, r->rt, r->ds); if (!e) { dsr_stat[4]++; return; }
    void *vdst = ring_alloc(r, nv * stride, &voff); memcpy(vdst, p + 4, nv * stride);
    if (ni) { void *idst = ring_alloc(r, ni * 2, &ioff); memcpy(idst, (const uint8_t *)(p + 4) + nv * stride, ni * 2); }
    e = enc_for(r, r->rt, r->ds);   // ring_alloc may have flushed
    Uniforms u; memset(&u, 0, sizeof u);
    float wv[16]; mat_mul(wv, r->xf[1], r->xf[2]); mat_mul(u.wvp, wv, r->xf[3]); memcpy(u.wv, wv, 64); memcpy(u.tex0, r->xf[16], 64); memcpy(u.tex1, r->xf[17], 64);
    u.s1[0] = r->tss[1][11]; u.s1[1] = r->tss[1][24];
    memcpy(u.tex2, r->xf[18], 64);   /* stage 2 (The Sims 2's projected shadows and lights: a third stage, camera-space texgen) */
    u.c2[0] = r->tss[2][1]; u.c2[1] = r->tss[2][2]; u.c2[2] = r->tss[2][3]; u.c2[3] = r->tss[2][4]; u.a2[0] = r->tss[2][5]; u.a2[1] = r->tss[2][6];
    u.s2[0] = r->tss[2][11]; u.s2[1] = r->tss[2][24];
    u.vp[0] = r->vp[0]; u.vp[1] = r->vp[1]; u.vp[2] = r->vp[2] ? r->vp[2] : rt->w; u.vp[3] = r->vp[3] ? r->vp[3] : rt->h;
    { float fs, fe; memcpy(&fs, &r->rs[36], 4); memcpy(&fe, &r->rs[37], 4); u.fog[0] = fs; u.fog[1] = fe; u.fog[2] = r->rs[28] && r->rs[140] == 3 && fe != fs ? 1 : 0; }
    uint32_t fc = r->rs[34]; u.fogcolor[0] = ((fc >> 16) & 255) / 255.0f; u.fogcolor[1] = ((fc >> 8) & 255) / 255.0f; u.fogcolor[2] = (fc & 255) / 255.0f; u.fogcolor[3] = 1;
    uint32_t tf = r->rs[60]; u.tfactor[0] = ((tf >> 16) & 255) / 255.0f; u.tfactor[1] = ((tf >> 8) & 255) / 255.0f; u.tfactor[2] = (tf & 255) / 255.0f; u.tfactor[3] = (tf >> 24) / 255.0f;
    u.c0[0] = r->tss[0][1]; u.c0[1] = r->tss[0][2]; u.c0[2] = r->tss[0][3]; u.c0[3] = r->tss[0][4]; u.a0[0] = r->tss[0][5]; u.a0[1] = r->tss[0][6]; u.a0[2] = r->tss[0][11]; u.a0[3] = r->tss[0][24];
    u.c1[0] = r->tss[1][1]; u.c1[1] = r->tss[1][2]; u.c1[2] = r->tss[1][3]; u.c1[3] = r->tss[1][4]; u.a1[0] = r->tss[1][5]; u.a1[1] = r->tss[1][6];
    u.at[0] = (r->rs[24] & 255) / 255.0f; u.at[1] = r->rs[25]; u.at[2] = r->rs[15] ? 1 : 0;
    Surf *t0 = surf(r, r->tex[0]), *t1 = surf(r, r->tex[1]);
    u.misc[0] = (fvf & 0xe) == 4; u.misc[1] = (fvf & 0x40) != 0; u.misc[2] = t0 != NULL; u.misc[3] = t1 != NULL;
    u.xrgb[0] = t0 && t0->fmt == 2; u.xrgb[1] = t1 && t1->fmt == 2;
    Surf *t2 = u.c1[0] > 1 && u.c2[0] > 1 ? surf(r, r->tex[2]) : NULL; u.s2[2] = t2 != NULL; u.s2[3] = t2 && t2->fmt == 2;
    uint32_t uoff; memcpy(ring_alloc(r, sizeof u, &uoff), &u, sizeof u);   // one copy, read by both stages
    e = enc_for(r, r->rt, r->ds);                                         // (ring_alloc may have flushed)
    id<MTLDepthStencilState> dso = depth_for(r);
    if (r->es.pso != pso) { [e setRenderPipelineState:pso]; r->es.pso = pso; }
    if (r->es.dso != dso) { [e setDepthStencilState:dso]; r->es.dso = dso; }
    if (r->rs[52] && r->es.sref != (r->rs[57] & 255) + 1) { [e setStencilReferenceValue:r->rs[57] & 255]; r->es.sref = (r->rs[57] & 255) + 1; }
    uint32_t cull = r->rs[22];
    int cm = cull == 2 ? MTLCullModeFront : cull == 3 ? MTLCullModeBack : MTLCullModeNone;   // D3DCULL_CW culls clockwise (= front here)
    if (r->es.cull != cm) { [e setCullMode:(MTLCullMode)cm]; r->es.cull = cm; }
    MTLViewport vp = {r->vp[0] * rt->sc, r->vp[1] * rt->sc, u.vp[2] * rt->sc, u.vp[3] * rt->sc, r->vp[4], r->vp[5] ? r->vp[5] : 1};   /* u.vp stays in the game's units */
    if (memcmp(&vp, &r->es.vp, sizeof vp)) { [e setViewport:vp]; r->es.vp = vp; }
    if (!r->es.ring_bound) {
        [e setVertexBuffer:r->ring offset:voff atIndex:0]; [e setVertexBuffer:r->white offset:0 atIndex:2];
        [e setVertexBuffer:r->ring offset:uoff atIndex:1]; [e setFragmentBuffer:r->ring offset:uoff atIndex:1]; r->es.ring_bound = 1;
    } else { [e setVertexBufferOffset:voff atIndex:0]; [e setVertexBufferOffset:uoff atIndex:1]; [e setFragmentBufferOffset:uoff atIndex:1]; }
    id<MTLTexture> x0 = t0 ? tex2d(t0) : r->dummy, x1 = t1 ? tex2d(t1) : r->dummy; id<MTLSamplerState> s0 = sampler_for(r, 0), s1 = sampler_for(r, 1);
    if (r->es.tex[0] != x0) { [e setFragmentTexture:x0 atIndex:0]; r->es.tex[0] = x0; }
    if (r->es.smp[0] != s0) { [e setFragmentSamplerState:s0 atIndex:0]; r->es.smp[0] = s0; }
    if (r->es.tex[1] != x1) { [e setFragmentTexture:x1 atIndex:1]; r->es.tex[1] = x1; }
    if (r->es.smp[1] != s1) { [e setFragmentSamplerState:s1 atIndex:1]; r->es.smp[1] = s1; }
    if (t2) { id<MTLTexture> x2 = tex2d(t2); id<MTLSamplerState> s2 = sampler_for(r, 2);
        if (r->es.tex[2] != x2) { [e setFragmentTexture:x2 atIndex:2]; r->es.tex[2] = x2; }
        if (r->es.smp[2] != s2) { [e setFragmentSamplerState:s2 atIndex:2]; r->es.smp[2] = s2; } }
    MTLPrimitiveType pt; uint32_t count = ni ? ni : nv;
    switch (prim) { case 1: pt = MTLPrimitiveTypePoint; break; case 2: pt = MTLPrimitiveTypeLine; break; case 3: pt = MTLPrimitiveTypeLineStrip; break;
                    case 5: pt = MTLPrimitiveTypeTriangleStrip; break; default: pt = MTLPrimitiveTypeTriangle; }
    if (prim == 6) {   // triangle fan -> list
        uint32_t tris = count - 2, ooff; uint16_t *ix = ring_alloc(r, tris * 6, &ooff);
        const uint16_t *src = ni ? (const uint16_t *)((const uint8_t *)(p + 4) + nv * stride) : NULL;
        for (uint32_t k = 0; k < tris; k++) { ix[k * 3] = src ? src[0] : 0; ix[k * 3 + 1] = src ? src[k + 1] : k + 1; ix[k * 3 + 2] = src ? src[k + 2] : k + 2; }
        e = enc_for(r, r->rt, r->ds);
        [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:tris * 3 indexType:MTLIndexTypeUInt16 indexBuffer:r->ring indexBufferOffset:ooff];
    } else if (ni) [e drawIndexedPrimitives:pt indexCount:ni indexType:MTLIndexTypeUInt16 indexBuffer:r->ring indexBufferOffset:ioff];
    else [e drawPrimitives:pt vertexStart:0 vertexCount:nv];
}
/* ---- effect programs ---- */
typedef struct FxU {                   /* hlsl.c's FxU: fixed-function state an effect program reads */
    float wvp[16], wv[16]; float vp[4], fog[4], fogcolor[4], tfactor[4], at[4];
    int32_t misc[4], cop[8][4], aop[8][4], tex[8][4];
} FxU;
static void prog_create(DSRRenderer *r, const uint32_t *p, uint32_t size)
{
    uint32_t pid = p[0], kinds = p[1], len = p[2];
    if (pid >= 1024 || size < 12 || len > size - 12) return;
    NSString *src = [[NSString alloc] initWithBytes:p + 3 length:len encoding:NSUTF8StringEncoding]; NSError *err = nil;
    const char *patch = getenv("DSR_FXPATCH");                           // development: "old=>new||old=>new" applied to every program's source
    if (patch) for (NSString *one in [@(patch) componentsSeparatedByString:@"||"]) { NSArray *pp = [one componentsSeparatedByString:@"=>"];
        if (pp.count == 2) src = [src stringByReplacingOccurrencesOfString:pp[0] withString:pp[1]]; }
    double t0 = CACurrentMediaTime();
    id<MTLLibrary> lib = [r->dev newLibraryWithSource:src options:[MTLCompileOptions new] error:&err];
    r->prog[pid].vs = [lib newFunctionWithName:@"vs_fx"]; r->prog[pid].fs = [lib newFunctionWithName:@"fs_fx"]; r->prog[pid].kinds = kinds;
    if (!r->prog[pid].vs || !r->prog[pid].fs) fprintf(stderr, "dsr: effect program %u: %s\n", pid, err ? err.localizedDescription.UTF8String : "functions missing");
    else if (getenv("DSR_PSOLOG")) fprintf(stderr, "dsr: effect program %u compiled in %.1f ms\n", pid, (CACurrentMediaTime() - t0) * 1000);
}
static id<MTLRenderPipelineState> prog_pipeline(DSRRenderer *r, uint32_t mask, int has_depth)
{
    uint32_t blend = r->rs[27] ? 1 : 0, sb = blend ? target_bf(r, r->rs[19]) : 2, db = blend ? target_bf(r, r->rs[20]) : 1, cw = r->rs[168] & 15;
    uint64_t key = (uint64_t)r->cur_prog << 48 | (uint64_t)mask << 32 | cw << 20 | blend << 16 | sb << 8 | db << 4 | (uint64_t)has_depth << 1 | 1;
    uint32_t h = (uint32_t)((key * 0x9e3779b97f4a7c15ull) >> 55);
    while (r->ppso_k[h] && r->ppso_k[h] != key) h = (h + 1) & 511;
    if (r->ppso_k[h]) return r->ppso_v[h];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; NSError *err = nil;
    d.vertexFunction = r->prog[r->cur_prog].vs; d.fragmentFunction = r->prog[r->cur_prog].fs;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    d.colorAttachments[0].writeMask = (cw & 1 ? MTLColorWriteMaskRed : 0) | (cw & 2 ? MTLColorWriteMaskGreen : 0) | (cw & 4 ? MTLColorWriteMaskBlue : 0) | (cw & 8 ? MTLColorWriteMaskAlpha : 0);
    if (has_depth) d.depthAttachmentPixelFormat = d.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    if (blend) { d.colorAttachments[0].blendingEnabled = YES; d.colorAttachments[0].sourceRGBBlendFactor = d.colorAttachments[0].sourceAlphaBlendFactor = bf(sb);
                 d.colorAttachments[0].destinationRGBBlendFactor = d.colorAttachments[0].destinationAlphaBlendFactor = bf(db); }
    MTLVertexDescriptor *v = [MTLVertexDescriptor vertexDescriptor]; int col = 0, ns = __builtin_popcount(mask);
    for (int sl = 0; sl < 16; sl++) {
        v.attributes[sl].format = MTLVertexFormatFloat4;
        if (mask >> sl & 1) { v.attributes[sl].bufferIndex = 0; v.attributes[sl].offset = 16u * (uint32_t)col++; }
        else { v.attributes[sl].bufferIndex = 3; v.attributes[sl].offset = 16u * (uint32_t)sl; }
    }
    v.layouts[0].stride = 16u * (uint32_t)(ns ? ns : 1);
    v.layouts[3].stride = 256; v.layouts[3].stepFunction = MTLVertexStepFunctionConstant; v.layouts[3].stepRate = 0;
    d.vertexDescriptor = v;
    id<MTLRenderPipelineState> pso = [r->dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!pso) { fprintf(stderr, "dsr: effect pipeline (program %u): %s\n", r->cur_prog, err.localizedDescription.UTF8String); return nil; }
    if (r->ppso_n < 384) { r->ppso_k[h] = key; r->ppso_v[h] = pso; r->ppso_n++; }
    return pso;
}
static void draw_prog(DSRRenderer *r, const uint32_t *p, uint32_t size)
{
    uint32_t prim = p[0], mask = p[1] & 0xffff, nv = p[2], ni = p[3], pretrans = p[4], ns = (uint32_t)__builtin_popcount(mask), stride = 16 * ns, voff, ioff = 0;
    dsr_stat[0]++;
    if (!nv || !ns || 20 + (uint64_t)nv * stride + (uint64_t)ni * 2 > size) { dsr_stat[1]++; return; }
    if (prim == 6 && (ni ? ni : nv) < 3) return;
    if (r->cur_prog >= 1024 || !r->prog[r->cur_prog].vs) return;
    ring_room(r, (uint64_t)nv * stride + (uint64_t)ni * 2 + 16ull * (r->npconst ? r->npconst : 1) + (uint64_t)(ni ? ni : nv) * 6);
    if (r->fl_on) {
        int k = 0; while (k < r->fl_np && r->fl_prog[k][0] != r->cur_prog) k++;
        if (k == r->fl_np && k < 24) { r->fl_prog[k][0] = r->cur_prog; r->fl_prog[k][1] = 0; r->fl_np++; }
        if (k < 24) r->fl_prog[k][1]++; r->fl_draws_fx++;
    }
    Surf *rt = surf(r, r->rt), *ds = surf(r, r->ds); if (!rt) { dsr_stat[2]++; return; }
    ds = depth_with(r, rt, ds);
    id<MTLRenderPipelineState> pso = prog_pipeline(r, mask, ds != NULL); if (!pso) { dsr_stat[3]++; return; }
    id<MTLRenderCommandEncoder> e = enc_for(r, r->rt, r->ds); if (!e) { dsr_stat[4]++; return; }
    void *vdst = ring_alloc(r, nv * stride, &voff); memcpy(vdst, p + 5, nv * stride);
    if (ni) { void *idst = ring_alloc(r, ni * 2, &ioff); memcpy(idst, (const uint8_t *)(p + 5) + nv * stride, ni * 2); }
    FxU u; memset(&u, 0, sizeof u);
    float wv[16]; mat_mul(wv, r->xf[1], r->xf[2]); mat_mul(u.wvp, wv, r->xf[3]); memcpy(u.wv, wv, 64);
    u.vp[0] = r->vp[0]; u.vp[1] = r->vp[1]; u.vp[2] = r->vp[2] ? r->vp[2] : rt->w; u.vp[3] = r->vp[3] ? r->vp[3] : rt->h;
    { float fs, fe; memcpy(&fs, &r->rs[36], 4); memcpy(&fe, &r->rs[37], 4); u.fog[0] = fs; u.fog[1] = fe; u.fog[2] = r->rs[28] ? 1 : 0; }
    uint32_t fc = r->rs[34]; u.fogcolor[0] = ((fc >> 16) & 255) / 255.0f; u.fogcolor[1] = ((fc >> 8) & 255) / 255.0f; u.fogcolor[2] = (fc & 255) / 255.0f; u.fogcolor[3] = 1;
    uint32_t tf = r->rs[60]; u.tfactor[0] = ((tf >> 16) & 255) / 255.0f; u.tfactor[1] = ((tf >> 8) & 255) / 255.0f; u.tfactor[2] = (tf & 255) / 255.0f; u.tfactor[3] = (tf >> 24) / 255.0f;
    u.at[0] = (r->rs[24] & 255) / 255.0f; u.at[1] = r->rs[25]; u.at[2] = r->rs[15] ? 1 : 0;
    u.misc[0] = (int32_t)(pretrans & 1);
    for (int st = 0; st < 8; st++) {
        u.cop[st][0] = (int32_t)r->tss[st][1]; u.cop[st][1] = (int32_t)r->tss[st][2]; u.cop[st][2] = (int32_t)r->tss[st][3]; u.cop[st][3] = (int32_t)r->tss[st][4];
        u.aop[st][0] = (int32_t)r->tss[st][5]; u.aop[st][1] = (int32_t)r->tss[st][6]; u.aop[st][3] = (int32_t)r->tss[st][11];
        Surf *t = surf(r, r->tex[st]); u.tex[st][0] = t != NULL; u.tex[st][1] = t && t->fmt == 2;
    }
    e = enc_for(r, r->rt, r->ds);                                         // (ring_alloc may have flushed)
    [e setRenderPipelineState:pso]; [e setDepthStencilState:depth_for(r)];
    if (r->rs[52]) [e setStencilReferenceValue:r->rs[57] & 255];
    uint32_t cull = r->rs[22]; [e setCullMode:cull == 2 ? MTLCullModeFront : cull == 3 ? MTLCullModeBack : MTLCullModeNone];
    [e setViewport:(MTLViewport){r->vp[0] * rt->sc, r->vp[1] * rt->sc, u.vp[2] * rt->sc, u.vp[3] * rt->sc, r->vp[4], r->vp[5] ? r->vp[5] : 1}];   /* u.vp stays in the game's units */
    [e setVertexBuffer:r->ring offset:voff atIndex:0]; [e setVertexBuffer:r->attr_defaults offset:0 atIndex:3];
    [e setVertexBytes:&u length:sizeof u atIndex:1]; [e setFragmentBytes:&u length:sizeof u atIndex:1];
    uint32_t nc = r->npconst ? r->npconst : 1, coff;
    void *cdst = ring_alloc(r, 16 * nc, &coff); memcpy(cdst, r->pconst, 16 * nc);
    e = enc_for(r, r->rt, r->ds);
    [e setVertexBuffer:r->ring offset:coff atIndex:2]; [e setFragmentBuffer:r->ring offset:coff atIndex:2];
    [e setVertexBuffer:r->ring offset:voff atIndex:0];
    for (int k = 0; k < 8; k++) {                                         // texture/sampler slots (the device's stages)
        uint32_t kind = (r->prog[r->cur_prog].kinds >> (2 * k)) & 3; Surf *t = surf(r, r->tex[k]);
        id<MTLTexture> x = kind == 1 ? r->dummy_cube : kind == 2 ? r->dummy_3d : (t ? tex2d(t) : r->dummy);
        if (kind == 1 && t && t->tex.textureType == MTLTextureTypeCube) x = t->tex;
        [e setFragmentTexture:x atIndex:(NSUInteger)k]; [e setFragmentSamplerState:sampler_for(r, k) atIndex:(NSUInteger)k];
    }
    if (rt->w == 256 && rt->h == 256) rt->fxrt = 1;
    { static int n = -1; if (n < 0) n = getenv("DSR_GLOWLOG") ? 600 : 0;
      if (n > 0 && rt->w == 256) { n--; Surf *t0 = surf(r, r->tex[0]);
        fprintf(stderr, "glow prog %u rt %u (%ux%u) vp %.0fx%.0f mask %04x nv %u pre %u | blend %u %u/%u | tex0 %u %ux%u%s\n", r->cur_prog, r->rt, rt->w, rt->h, r->vp[2], r->vp[3],
                mask, nv, pretrans, r->rs[27], r->rs[19], r->rs[20], r->tex[0], t0 ? t0->w : 0, t0 ? t0->h : 0, t0 ? "" : " (none: white)"); } }
    static int tlog = -1; if (tlog < 0) tlog = getenv("DSR_FXTEXLOG") ? atoi(getenv("DSR_FXTEXLOG")) : 0;
    { static int n = -1; if (n < 0) n = getenv("DSR_RTLOG") ? atoi(getenv("DSR_RTLOG")) : 0; static uint32_t lastp; static int lastf;
      if (n > 0 && r->rs[28] && (r->cur_prog != lastp || dsr_frame != lastf)) { n--; lastp = r->cur_prog; lastf = dsr_frame; fprintf(stderr, "dsr: frame %d: program %u draws into %u after %ld draws\n", dsr_frame, r->cur_prog, r->rt, dsr_stat[0]); } }
    if (tlog > 0) { tlog--; { float fs, fe, fd; memcpy(&fs, &r->rs[36], 4); memcpy(&fe, &r->rs[37], 4); memcpy(&fd, &r->rs[38], 4);
                                fprintf(stderr, "dsr: fog enable %u table %u vertex %u range %u start %g end %g density %g colour %08x; alpha test %u ref %u func %u; blend %u %u/%u\n", r->rs[28], r->rs[35], r->rs[140], r->rs[48], fs, fe, fd, r->rs[34], r->rs[15], r->rs[24], r->rs[25], r->rs[27], r->rs[19], r->rs[20]); }
                    fprintf(stderr, "dsr: program %u draws with", r->cur_prog);
        for (int k = 0; k < 8; k++) { Surf *t = surf(r, r->tex[k]); if (t) fprintf(stderr, " [%d] %u %ux%u%s%s", k, r->tex[k], t->w, t->h, t->tex.textureType == MTLTextureTypeCube ? " cube" : "", t->tex ? "" : " (no texture)"); else if (r->tex[k]) fprintf(stderr, " [%d] %u (unknown)", k, r->tex[k]); }
        fprintf(stderr, "\n"); }
    memset(&r->es, 0, sizeof r->es); r->es.cull = -1;                     // the fixed-function path sets its state again
    MTLPrimitiveType pt; uint32_t count = ni ? ni : nv;
    switch (prim) { case 1: pt = MTLPrimitiveTypePoint; break; case 2: pt = MTLPrimitiveTypeLine; break; case 3: pt = MTLPrimitiveTypeLineStrip; break;
                    case 5: pt = MTLPrimitiveTypeTriangleStrip; break; default: pt = MTLPrimitiveTypeTriangle; }
    if (prim == 6) {
        uint32_t tris = count - 2, ooff; uint16_t *ix = ring_alloc(r, tris * 6, &ooff);
        const uint16_t *src = ni ? (const uint16_t *)((const uint8_t *)(p + 5) + nv * stride) : NULL;
        for (uint32_t k = 0; k < tris; k++) { ix[k * 3] = src ? src[0] : 0; ix[k * 3 + 1] = src ? src[k + 1] : (uint16_t)(k + 1); ix[k * 3 + 2] = src ? src[k + 2] : (uint16_t)(k + 2); }
        e = enc_for(r, r->rt, r->ds);
        [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:tris * 3 indexType:MTLIndexTypeUInt16 indexBuffer:r->ring indexBufferOffset:ooff];
    } else if (ni) [e drawIndexedPrimitives:pt indexCount:ni indexType:MTLIndexTypeUInt16 indexBuffer:r->ring indexBufferOffset:ioff];
    else [e drawPrimitives:pt vertexStart:0 vertexCount:nv];
}
static void clear_rect(DSRRenderer *r, uint32_t flags, uint32_t color, float z, uint32_t stencil, const int32_t *rc, int has_ds)
{
    if (flags & 1) quad(r, r->rt, rc, 0, rc, 1, color);                          // D3DCLEAR_TARGET
    if ((flags & 6) && has_ds) {                                                // D3DCLEAR_ZBUFFER, D3DCLEAR_STENCIL
        Surf *ct = surf(r, r->rt); id<MTLRenderPipelineState> zp = ct ? helper_pso(r, 2, ct->tex.pixelFormat) : nil; if (!zp) return;
        id<MTLRenderCommandEncoder> e = enc_for(r, r->rt, r->ds); float zz[4] = {z, 0, 0, 0};
        [e setRenderPipelineState:zp]; [e setDepthStencilState:r->zsclear_ds[(flags >> 1) & 3]]; [e setCullMode:MTLCullModeNone];
        if (flags & 4) [e setStencilReferenceValue:stencil & 255];
        float sc = surf(r, r->rt)->sc;
        [e setViewport:(MTLViewport){rc[0] * sc, rc[1] * sc, (rc[2] - rc[0]) * sc, (rc[3] - rc[1]) * sc, 0, 1}];
        [e setVertexBytes:zz length:16 atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        memset(&r->es, 0, sizeof r->es); r->es.cull = -1;
    }
}

static void clear(DSRRenderer *r, const uint32_t *p, uint32_t size)
{
    if (r->fl_on && (p[0] & 1) && (p[1] & 0xffffff) == 0xffffff) r->fl_wclear++;   /* a clear to white (DSR_FLASHLOG) */
    uint32_t flags = p[0], color = p[1]; float z; memcpy(&z, &p[2], 4);
    Surf *rt = surf(r, r->rt), *ds = surf(r, r->ds); if (!rt) return;
    ds = depth_with(r, rt, ds);
    if (dsr_verbose) fprintf(stderr, "clear flags %x color %08x rt %u (%ux%u fmt %u usage %lx) ds %u vp %.0f %.0f %.0f %.0f\n", flags, color, r->rt, rt->w, rt->h, rt->fmt, (unsigned long)rt->tex.usage, r->ds, r->vp[0], r->vp[1], r->vp[2], r->vp[3]);
    int32_t full[4] = {(int32_t)r->vp[0], (int32_t)r->vp[1], (int32_t)(r->vp[0] + (r->vp[2] ? r->vp[2] : rt->w)), (int32_t)(r->vp[1] + (r->vp[3] ? r->vp[3] : rt->h))};
    full[0] = full[0] > 0 ? full[0] : 0; full[1] = full[1] > 0 ? full[1] : 0;
    full[2] = full[2] < (int32_t)rt->w ? full[2] : (int32_t)rt->w; full[3] = full[3] < (int32_t)rt->h ? full[3] : (int32_t)rt->h;
    // D3D clears only the given rects (each clipped to the viewport), or the whole viewport when there are none. The game
    // relies on it: the inventory's paper doll is kept inside its box by clearing depth to 0 everywhere, then to 1 in the
    // box, before drawing the doll.
    uint32_t nr = size >= 20 ? p[4] : 0; if (nr > (size - 20) / 16) nr = 0;
    for (uint32_t k = 0; k < (nr ? nr : 1); k++) {
        int32_t rc[4]; memcpy(rc, nr ? (const int32_t *)(p + 5 + 4 * k) : full, 16);
        if (rc[0] < full[0]) rc[0] = full[0];
        if (rc[1] < full[1]) rc[1] = full[1];
        if (rc[2] > full[2]) rc[2] = full[2];
        if (rc[3] > full[3]) rc[3] = full[3];
        if (rc[2] > rc[0] && rc[3] > rc[1]) clear_rect(r, flags, color, z, p[3], rc, ds != 0);
    }
    if (getenv("DSR_CHECKCLEAR")) {
        static int n; if (n++ < 4) {
            id<MTLBuffer> b = [r->dev newBufferWithLength:4 options:MTLResourceStorageModeShared]; end_enc(r);
            id<MTLBlitCommandEncoder> be = [cmdbuf(r) blitCommandEncoder];
            [be copyFromTexture:rt->tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(100, 100, 0) sourceSize:MTLSizeMake(1, 1, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
            [be endEncoding]; dsr_renderer_flush(r, 1);
            fprintf(stderr, "after clear %d: px %08x, cb status %ld err %s\n", n, *(uint32_t *)b.contents, (long)r->last_cb.status, r->last_cb.error.localizedDescription.UTF8String ?: "-"); } }
}

void dsr_renderer_flush(DSRRenderer *r, int wait)
{
    commit(r);
    if (wait && r->last_cb) [r->last_cb waitUntilCompleted];
}
// Encode "presented surface -> dst" (gamma applied) into the current command buffer; returns that command buffer,
// uncommitted, so the caller can attach presentDrawable / completion handlers and then call dsr_renderer_flush.
id<MTLCommandBuffer> dsr_renderer_present_to(DSRRenderer *r, id<MTLTexture> dst)
{
    Surf *s = surf(r, r->presented); if (!s) return nil;
    if (r->gamma_dirty) {
        uint16_t px[256][4];
        for (int k = 0; k < 256; k++) { px[k][0] = r->gamma[0][k]; px[k][1] = r->gamma[1][k]; px[k][2] = r->gamma[2][k]; px[k][3] = 0xffff; }
        [r->gamma_lut replaceRegion:MTLRegionMake1D(0, 256) mipmapLevel:0 withBytes:px bytesPerRow:sizeof px];
        r->gamma_dirty = 0;
    }
    end_enc(r);
    MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture = dst; p.colorAttachments[0].loadAction = MTLLoadActionDontCare; p.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cmdbuf(r) renderCommandEncoderWithDescriptor:p];
    [e setRenderPipelineState:r->present_pso];
    [e setFragmentTexture:s->tex atIndex:0]; [e setFragmentTexture:r->gamma_lut atIndex:1];
    [e setFragmentSamplerState:(dst.width == s->tex.width && dst.height == s->tex.height) ? r->point_clamp : r->linear_clamp atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (r->cur_show && r->cur_tex && s->w && s->h) {   /* the Windows cursor, over the frame; as large as the game's pixels */
        struct { float dst[4], src[4], color[4]; int32_t mode[4]; } q = {{0}};
        float x0 = (float)(r->cur_x - r->cur_hx), y0 = (float)(r->cur_y - r->cur_hy), sc = (float)dst.width / s->w;
        q.dst[0] = x0 / s->w; q.dst[1] = y0 / s->h; q.dst[2] = (x0 + r->cur_tex.width) / s->w; q.dst[3] = (y0 + r->cur_tex.height) / s->h;
        q.src[2] = q.src[3] = 1;
        [e setRenderPipelineState:r->quad_over_pso]; [e setVertexBytes:&q length:sizeof q atIndex:0]; [e setFragmentBytes:&q length:sizeof q atIndex:0];
        [e setFragmentTexture:r->cur_tex atIndex:0]; [e setFragmentSamplerState:fabsf(sc - roundf(sc)) < 0.01f ? r->point_clamp : r->linear_clamp atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [e setRenderPipelineState:r->present_pso]; [e setFragmentTexture:s->tex atIndex:0]; [e setFragmentTexture:r->gamma_lut atIndex:1];
    }
    if (r->fl_on) {   /* DSR_FLASHLOG: the frame as shown, sampled 32x32, checked when the GPU is done */
        [e endEncoding];
        int i = r->fl_i++ & 3;
        if (!r->fl_probe[i]) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModeShared; r->fl_probe[i] = [r->dev newTextureWithDescriptor:d];
        }
        MTLRenderPassDescriptor *pp = [MTLRenderPassDescriptor renderPassDescriptor];
        pp.colorAttachments[0].texture = r->fl_probe[i]; pp.colorAttachments[0].loadAction = MTLLoadActionDontCare; pp.colorAttachments[0].storeAction = MTLStoreActionStore;
        e = [cmdbuf(r) renderCommandEncoderWithDescriptor:pp];
        [e setRenderPipelineState:r->present_pso]; [e setFragmentTexture:s->tex atIndex:0]; [e setFragmentTexture:r->gamma_lut atIndex:1];
        [e setFragmentSamplerState:r->point_clamp atIndex:0]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        id<MTLTexture> probe = r->fl_probe[i]; int frame = dsr_frame;
        char ctx[600]; int n = snprintf(ctx, sizeof ctx, "fixed %u, effects %u, target switches %u, white clears %u | programs", r->fl_ff, r->fl_draws_fx, r->fl_rtsw, r->fl_wclear);
        for (int k = 0; k < r->fl_np && n < (int)sizeof ctx - 24; k++) n += snprintf(ctx + n, sizeof ctx - n, " %u:%u", r->fl_prog[k][0], r->fl_prog[k][1]);
        NSString *what = @(ctx); r->fl_np = 0; r->fl_ff = r->fl_rtsw = r->fl_wclear = r->fl_draws_fx = 0;
        [r->cb addCompletedHandler:^(id<MTLCommandBuffer> cb) { (void)cb;
            uint8_t px[32 * 32 * 4]; [probe getBytes:px bytesPerRow:128 fromRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0];
            double m[3] = {0, 0, 0}, lum = 0; int white = 0;
            for (int k = 0; k < 1024; k++) { double b = px[4 * k] / 255.0, g = px[4 * k + 1] / 255.0, rr = px[4 * k + 2] / 255.0, l = 0.299 * rr + 0.587 * g + 0.114 * b;
                m[0] += rr; m[1] += g; m[2] += b; lum += l; if (l > 0.92) white++; }
            lum /= 1024; m[0] /= 1024; m[1] /= 1024; m[2] /= 1024; double wf = white / 1024.0;
            static double el, ew, ec[3]; static int warm;
            const char *kind = NULL;
            if (warm > 30) {
                if (wf > 0.5 && ew < 0.25) kind = "WHITE";
                else if (fabs(lum - el) > 0.22) kind = "FLASH";
                else for (int c = 0; c < 3; c++) if (fabs(m[c] - ec[c]) > 0.25) kind = c == 1 ? "GREEN FLASH" : c == 0 ? "RED FLASH" : "BLUE FLASH";
            }
            if (kind) {
                fprintf(stderr, "dsr: %s frame %d: brightness %.2f (recently %.2f), white %.0f%%, rgb %.2f %.2f %.2f | %s\n", kind, frame, lum, el, wf * 100, m[0], m[1], m[2], what.UTF8String);
                extern volatile int dsr_flash_frame, dsr_trace_req; dsr_flash_frame = frame;
                static int traced; if (wf > 0.5 && traced++ < 2) dsr_trace_req = 1;   /* the next frame's commands, twice per run */
            }
            double a = warm < 30 ? 0.3 : kind ? 0.02 : 0.1; warm++;
            el += a * (lum - el); ew += a * (wf - ew); for (int c = 0; c < 3; c++) ec[c] += a * (m[c] - ec[c]);
        }];
        [e endEncoding]; e = nil;
    }
    if (r->g_on && !r->fl_on) {   // frame-time graph, bottom-left: 240 columns, 0..40 ms
        if (!r->graph_pso) {
            MTLRenderPipelineDescriptor *gd = [MTLRenderPipelineDescriptor new]; NSError *err = nil;
            gd.vertexFunction = [r->lib newFunctionWithName:@"vs_present"]; gd.fragmentFunction = [r->lib newFunctionWithName:@"fs_graph"];
            gd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; gd.colorAttachments[0].blendingEnabled = YES;
            gd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha; gd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            r->graph_pso = [r->dev newRenderPipelineStateWithDescriptor:gd error:&err];
            if (!r->graph_pso) fprintf(stderr, "graph pipeline: %s\n", err.localizedDescription.UTF8String);
        }
        if (r->graph_pso) {
            float g[2 * 240 + 4]; int k;
            for (k = 0; k < 240; k++) { g[k] = r->g_a[(r->g_ha + k) % 240]; g[240 + k] = r->g_b[(r->g_hb + k) % 240]; }
            double w = dst.width * 0.36, h = dst.height * 0.22;
            [e setViewport:(MTLViewport){8, dst.height - h - 8, w, h, 0, 1}];
            [e setRenderPipelineState:r->graph_pso];
            [e setFragmentBytes:g length:sizeof g atIndex:0];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
    }
    [e endEncoding];
    return r->cb;
}
void dsr_renderer_set_readback(DSRRenderer *r, void *area, size_t size, volatile uint32_t *done)
{
    r->rb_buf = [r->dev newBufferWithBytesNoCopy:area length:size options:MTLResourceStorageModeShared deallocator:nil]; r->rb_done = done;
}
static void readback(DSRRenderer *r, const uint32_t *p)
{
    Surf *s = surf(r, p[0]); uint32_t x = p[1], y = p[2], w = p[3], h = p[4]; int ok = 0;
    if (s && s->sc != 1 && r->rb_buf && s->fmt != 3 && w && h && (uint64_t)x + w <= s->w && (uint64_t)y + h <= s->h && (uint64_t)w * h * 4 <= r->rb_buf.length) {
        /* a scaled surface, read at the game's size: drawn smaller into the stage, then read from there */
        Surf *g = stage(r, w, h);
        int32_t dr[4] = {0, 0, (int32_t)w, (int32_t)h}, sr[4] = {(int32_t)x, (int32_t)y, (int32_t)(x + w), (int32_t)(y + h)};
        quad(r, STAGE_SURF, dr, p[0], sr, 0, 0);
        if (r->enc) { [r->enc endEncoding]; r->enc = nil; }
        [blit_enc(r) copyFromTexture:g->tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                             toBuffer:r->rb_buf destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
        dsr_renderer_flush(r, 1);
        if (r->rb_done) __atomic_store_n(r->rb_done, p[5], __ATOMIC_RELEASE);
        return;
    }
    if (s && r->rb_buf && s->fmt != 3 && w && h && (uint64_t)x + w <= s->w && (uint64_t)y + h <= s->h && (uint64_t)w * h * 4 <= r->rb_buf.length) {
        if (r->enc) { [r->enc endEncoding]; r->enc = nil; }
        [blit_enc(r) copyFromTexture:s->tex sourceSlice:s->slice sourceLevel:s->level sourceOrigin:MTLOriginMake(x, y, 0) sourceSize:MTLSizeMake(w, h, 1)
                             toBuffer:r->rb_buf destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
        dsr_renderer_flush(r, 1); ok = 1;
    }
    if (r->rb_done) __atomic_store_n(r->rb_done, ok ? p[5] : p[5] | 0x80000000u, __ATOMIC_RELEASE);   /* high bit: not done */
}
double dsr_renderer_present_time(DSRRenderer *r) { return r->present_ts; }
void dsr_renderer_set_graph(DSRRenderer *r, const float *a, int ha, const float *b, int hb) { r->g_a = a; r->g_ha = ha; r->g_b = b; r->g_hb = hb; r->g_on = 1; }
void dsr_renderer_presented_size(DSRRenderer *r, uint32_t *w, uint32_t *h) { Surf *s = surf(r, r->presented); *w = s ? (uint32_t)lroundf(s->w * s->sc) : 0; *h = s ? (uint32_t)lroundf(s->h * s->sc) : 0; }
id<MTLTexture> dsr_renderer_rt(DSRRenderer *r) { Surf *s = surf(r, r->rt); return s ? s->tex : nil; }
id<MTLTexture> dsr_renderer_presented(DSRRenderer *r) { Surf *s = surf(r, r->presented); return s ? s->tex : nil; }

/* DSR_FLASHLOG's trace: every command of one frame (the one after a white frame is flagged, or DSR_TRACEBASE=<frame>) */
volatile int dsr_trace_req;
static void trace_cmd(DSRRenderer *r, uint32_t op, const uint32_t *p, uint32_t size)
{
    Surf *t;
    switch (op) {
    case DSR_SET_RT: t = surf(r, p[0]); fprintf(stderr, "trace: target %u (%ux%u fmt %u kind %u) depth %u\n", p[0], t ? t->w : 0, t ? t->h : 0, t ? t->fmt : 0, t ? t->kind : 0, p[1]); break;
    case DSR_CLEAR: fprintf(stderr, "trace: clear target %u flags %x color %08x rects %u viewport %.0f,%.0f %.0fx%.0f\n", r->rt, p[0], p[1], size >= 20 ? p[4] : 0, r->vp[0], r->vp[1], r->vp[2], r->vp[3]); break;
    case DSR_BLT: fprintf(stderr, "trace: blt %u <- %u [%d,%d,%d,%d] <- [%d,%d,%d,%d] flags %x fill %08x\n", p[0], p[5], (int)p[1], (int)p[2], (int)p[3], (int)p[4], (int)p[6], (int)p[7], (int)p[8], (int)p[9], p[10], p[11]); break;
    case DSR_DRAW: case DSR_DRAW_PROG: {
        Surf *t0 = surf(r, r->tex[0]);
        fprintf(stderr, "trace: %s target %u prog %u prim %u nv %u | blend %u %u/%u z %u/%u atest %u | tex0 %u (%ux%u fmt %u) op %u/%u a %u/%u | tfactor %08x vp %.0fx%.0f\n",
                op == DSR_DRAW ? "draw" : "draw_prog", r->rt, op == DSR_DRAW_PROG ? r->cur_prog : 0, p[0], op == DSR_DRAW_PROG ? p[3] : p[2], r->rs[27], r->rs[19], r->rs[20], r->rs[7], r->rs[14], r->rs[15],
                r->tex[0], t0 ? t0->w : 0, t0 ? t0->h : 0, t0 ? t0->fmt : 0, r->tss[0][1], r->tss[0][2], r->tss[0][5], r->tss[0][6], r->rs[60], r->vp[2], r->vp[3]); break; }
    case DSR_PRESENT: fprintf(stderr, "trace: present %u (frame %d)\n", p[0], dsr_frame); break;
    default: break;
    }
}
/* ---- game shaders: the game's own vs/ps 1.1-3.0 pairs (DSR_MSL_CREATE, from runtime/win32/d3d9_shader.c), as Fallout:
 * New Vegas draws everything. MojoShader's Metal profile reads vertex inputs by register ([[attribute(register)]]),
 * constants from buffer 0 (float4[], int4[], bool[] in that order), textures and samplers by sampler register; the
 * D3D9 layer's wrapping adds buffer 1 (vertex: pixel-centre offset; pixel: alpha test). Vertex buffers are the kept
 * buffers (DSR_VBUF_DATA) or the command's own float4 vertices; registers a draw doesn't supply read (0, 0, 0, 1).
 * The Linux port's OpenGL renderer (src/renderer/linux/renderer.c) is the reference for every D3D9 detail here. ---- */
#define GP_BASE 0x10000u
#define GP_MAX 16384u
#define VB_FIRST 2                                   /* vertex buffer indices: 0 constants, 1 pixel-centre offset, 2.. streams */
#define VB_DEFAULTS 29                               /* (0, 0, 0, 1) for the registers a draw doesn't supply */
typedef struct GP { __strong id<MTLFunction> vs, fs; uint32_t hash; int ok; uint8_t slot_reg[32]; uint16_t in_regs; uint8_t samp[16]; } GP;   /* slot_reg: register + 1; samp: 1 2D, 2 cube, 3 3D */
static GP *gp_of(DSRRenderer *r, uint32_t id) { return id >= GP_BASE && id - GP_BASE < GP_MAX && r->gp ? &r->gp[id - GP_BASE] : NULL; }
static uint32_t fnv1a(uint32_t h, const void *p, size_t n) { const uint8_t *b = p; for (size_t k = 0; k < n; k++) h = (h ^ b[k]) * 16777619u; return h; }
static id<MTLFunction> msl_function(DSRRenderer *r, const char *src, NSString *name, uint32_t pid, const char *what)
{
    MTLCompileOptions *o = [MTLCompileOptions new]; NSError *err = nil;
    if (@available(macOS 11.0, *)) o.preserveInvariance = YES;   /* the position is [[invariant]]: multi-pass lighting draws with depth EQUAL */
    if (@available(macOS 15.0, *)) o.mathMode = MTLMathModeSafe; else { _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wdeprecated-declarations\"") o.fastMathEnabled = NO; _Pragma("clang diagnostic pop") }   /* Direct3D's arithmetic: no reassociation, NaN and infinity kept */
    double t0 = CACurrentMediaTime();
    id<MTLLibrary> lib = [r->dev newLibraryWithSource:@(src) options:o error:&err];
    id<MTLFunction> f = lib ? [lib newFunctionWithName:name] : nil;
    static int log = -1; if (log < 0) log = getenv("DSR_PSOLOG") != 0;
    if (log) fprintf(stderr, "dsr: game shader %u (%s) compiled in %.1f ms (frame %d)\n", pid, what, (CACurrentMediaTime() - t0) * 1000, dsr_frame);
    if (!f) { static int n; if (n++ < 20) fprintf(stderr, "dsr: game shader %u (%s): %s\n", pid, what, err ? err.localizedDescription.UTF8String : "no entry point"); }
    return f;
}
static void msl_create(DSRRenderer *r, const uint32_t *p, uint32_t size)
{
    uint32_t pid = p[0], na = p[1], vl = p[2], pl = p[3];
    if (!r->gp) r->gp = calloc(GP_MAX, sizeof *r->gp);
    GP *g = gp_of(r, pid); if (!g || na > 16 || 16ull + 8ull * na + ((vl + 4) & ~3u) + ((pl + 4) & ~3u) > size) return;
    const char *vs = (const char *)(p + 4 + 2 * na), *ps = vs + ((vl + 4) & ~3u);
    g->hash = fnv1a(fnv1a(2166136261u, vs, vl), ps, pl); memset(g->slot_reg, 0, sizeof g->slot_reg); memset(g->samp, 0, sizeof g->samp); g->in_regs = 0;
    for (uint32_t k = 0; k < na; k++) if (p[4 + 2 * k] < 32 && p[5 + 2 * k] < 16) g->slot_reg[p[4 + 2 * k]] = (uint8_t)(p[5 + 2 * k] + 1);
    for (const char *q = vs; (q = strstr(q, "[[attribute(")); q += 12) { int reg = atoi(q + 12); if (reg >= 0 && reg < 16) g->in_regs |= (uint16_t)(1u << reg); }
    for (const char *q = ps; (q = strstr(q, "[[texture(")); q += 10) {               /* each sampler's texture type */
        int st = atoi(q + 10); const char *ln = q; while (ln > ps && ln[-1] != '\n') ln--;
        if (st < 0 || st >= 16) continue;
        g->samp[st] = strstr(ln, "texturecube") && strstr(ln, "texturecube") < q ? 2 : strstr(ln, "texture3d") && strstr(ln, "texture3d") < q ? 3 : 1;
    }
    { const char *dir = getenv("DSR_MSL_DUMP"); if (dir) { char path[1024]; snprintf(path, sizeof path, "%s/%08x.metal", dir, g->hash); FILE *o = fopen(path, "w");   /* DSR_MSL_DUMP=<dir> */
        if (o) { fprintf(o, "%s\n// ---- pixel ----\n%s", vs, ps); fclose(o); } } }
    double t0 = CACurrentMediaTime();
    g->vs = msl_function(r, vs, @"vsmain", pid, "vertex"); g->fs = g->vs ? msl_function(r, ps, @"psmain", pid, "pixel") : nil;
    g->ok = g->vs && g->fs;
    static int plog = -1; if (plog < 0) plog = getenv("DSR_PROGLOG") != 0;
    if (plog) fprintf(stderr, "dsr: game shader %u is %08x, compiled in %.1f ms%s\n", pid, g->hash, (CACurrentMediaTime() - t0) * 1000, g->ok ? "" : " (failed)");
}
/* DSR_SHADER_CONST: the bound program's registers, laid out as each stage's MojoShader uniform struct */
static void shader_consts(DSRRenderer *r, const uint32_t *p, uint32_t size)
{
    uint32_t vf = p[0], pf = p[1], vi = p[2], pi = p[3], vb = p[4], pb = p[5];
    if (24ull + 16ull * (vf + pf + vi + pi) + 4ull * (vb + pb) + 16 > size) return;
    const uint32_t *w = p + 6, *f[2] = {w, w + 4 * vf}, *i[2], *b[2];
    i[0] = w + 4 * (vf + pf); i[1] = i[0] + 4 * vi; b[0] = i[1] + 4 * pi; b[1] = b[0] + vb;
    uint32_t nf[2] = {vf, pf}, ni[2] = {vi, pi}, nb[2] = {vb, pb};
    for (int st = 0; st < 2; st++) {
        uint8_t *o = st ? r->pcb : r->vcb; uint32_t len = 16 * (nf[st] + ni[st]) + nb[st]; len = (len + 15) & ~15u;
        if (len > (st ? sizeof r->pcb : sizeof r->vcb)) { static int w; if (!w++) fprintf(stderr, "dsr: a program's constants (%u bytes) don't fit (left out)\n", len); len = 0; }
        if (len) { memcpy(o, f[st], 16 * nf[st]); memcpy(o + 16 * nf[st], i[st], 16 * ni[st]);
                   for (uint32_t k = 0; k < nb[st]; k++) o[16 * (nf[st] + ni[st]) + k] = b[st][k] != 0; }
        if (st) r->pcb_len = len; else r->vcb_len = len;
    }
    memcpy(r->atest, b[1] + pb, 16);
}
/* kept vertex and index buffers (DSR_VBUF_DATA): written in place unless the GPU may still read them. The record's
 * top byte carries the game's lock flags (d3d9.c buf_locked): 1 every lock was NOOVERWRITE (in place: the game wrote
 * nothing the GPU still reads), 2 one was DISCARD (another buffer, without the old contents). Otherwise a buffer the
 * GPU may still read is replaced by a copy. Replaced buffers wait in a pool until the GPU is done with them, then are
 * used again: a game that rewrites part of a large buffer many times a frame no longer makes and frees buffers. */
#define VB_POOL 64
static id<MTLBuffer> vb_pool[VB_POOL]; static uint64_t vb_pool_serial[VB_POOL]; static int vb_pool_n;
static id<MTLBuffer> vb_get(DSRRenderer *r, uint32_t len)
{
    uint64_t done = __atomic_load_n(&r->done_serial, __ATOMIC_ACQUIRE);
    for (int k = 0; k < vb_pool_n; k++)
        if (vb_pool[k].length == len && vb_pool_serial[k] <= done) {
            id<MTLBuffer> b = vb_pool[k]; vb_pool[k] = vb_pool[--vb_pool_n]; vb_pool_serial[k] = vb_pool_serial[vb_pool_n]; vb_pool[vb_pool_n] = nil;
            return b;
        }
    return [r->dev newBufferWithLength:len options:MTLResourceStorageModeShared];
}
static void vb_retire(id<MTLBuffer> b, uint64_t serial)
{
    if (!b) return;
    if (vb_pool_n == VB_POOL) {                                  /* full: the oldest goes */
        int o = 0; for (int k = 1; k < VB_POOL; k++) if (vb_pool_serial[k] < vb_pool_serial[o]) o = k;
        vb_pool[o] = vb_pool[--vb_pool_n]; vb_pool_serial[o] = vb_pool_serial[vb_pool_n]; vb_pool[vb_pool_n] = nil;
    }
    vb_pool[vb_pool_n] = b; vb_pool_serial[vb_pool_n++] = serial;
}
static void vbuf_data(DSRRenderer *r, const uint32_t *p, uint32_t size)
{
    uint32_t bid = p[0] & 0xffffff, how = p[0] >> 24, total = p[1], off = p[2], n = p[3];
    if (bid >= DSR_VBUFS || !total || 16ull + n > size || (uint64_t)off + n > total) return;
    id<MTLBuffer> b = r->vb[bid];
    if (!b || b.length != total) { vb_retire(b, r->vb_use[bid]); r->vb[bid] = b = vb_get(r, total); r->vb_use[bid] = 0; }
    else if (!(how & 1) && r->vb_use[bid] > __atomic_load_n(&r->done_serial, __ATOMIC_ACQUIRE)) {   /* in use: another buffer (the command buffer keeps the old) */
        id<MTLBuffer> c = vb_get(r, total);
        if (!(how & 2) && (off || n != total)) memcpy(c.contents, b.contents, total);
        vb_retire(b, r->vb_use[bid]); r->vb[bid] = b = c; r->vb_use[bid] = 0;
    }
    if (n) memcpy((uint8_t *)b.contents + off, p + 4, n);
}
/* D3DDECLTYPE as Metal reads it (missing components 0, 0, 0, 1 as in D3D); MTLVertexFormatInvalid: none */
static MTLVertexFormat decl_format(uint32_t t)
{
    switch (t) {
    case 0: return MTLVertexFormatFloat; case 1: return MTLVertexFormatFloat2; case 2: return MTLVertexFormatFloat3; case 3: return MTLVertexFormatFloat4;
    case 4: return MTLVertexFormatUChar4Normalized_BGRA; case 5: return MTLVertexFormatUChar4; case 6: return MTLVertexFormatShort2; case 7: return MTLVertexFormatShort4;
    case 8: return MTLVertexFormatUChar4Normalized; case 9: return MTLVertexFormatShort2Normalized; case 10: return MTLVertexFormatShort4Normalized;
    case 11: return MTLVertexFormatUShort2Normalized; case 12: return MTLVertexFormatUShort4Normalized; case 15: return MTLVertexFormatHalf2; case 16: return MTLVertexFormatHalf4;
    default: return MTLVertexFormatInvalid;
    }
}
static MTLBlendFactor gbf(uint32_t b)                 /* D3DBLEND, including BLENDFACTOR (14, 15) */
{
    return b == 14 ? MTLBlendFactorBlendColor : b == 15 ? MTLBlendFactorOneMinusBlendColor : bf(b);
}
static MTLBlendOperation gbop(uint32_t o) { return o == 2 ? MTLBlendOperationSubtract : o == 3 ? MTLBlendOperationReverseSubtract : o == 4 ? MTLBlendOperationMin : o == 5 ? MTLBlendOperationMax : MTLBlendOperationAdd; }
/* depth and stencil, both faces (TWOSIDEDSTENCILMODE 185: counter-clockwise faces use 186-189) */
static id<MTLDepthStencilState> gdepth_for(DSRRenderer *r, int has_ds)
{
    uint32_t en = has_ds && r->rs[7], wr = en && r->rs[14], st = has_ds && r->rs[52], two = st && r->rs[185];
    uint32_t k[12] = {en, wr, en ? r->rs[23] : 8, st, st ? r->rs[53] : 0, st ? r->rs[54] : 0, st ? r->rs[55] : 0, st ? r->rs[56] : 0, st ? (r->rs[58] & 255) | (r->rs[59] & 255) << 8 : 0,
                      two ? r->rs[186] | r->rs[187] << 4 | r->rs[188] << 8 | r->rs[189] << 12 : 0, two, 0};
    uint64_t key = (uint64_t)fnv1a(2166136261u, k, sizeof k) << 1 | 1;
    uint32_t h = (uint32_t)(key * 0x9e3779b97f4a7c15ull >> 56);
    while (r->gdso_k[h] && r->gdso_k[h] != key) h = (h + 1) & 255;
    if (r->gdso_k[h]) return r->gdso_v[h];
    MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new]; d.depthCompareFunction = en ? cmpf(r->rs[23]) : MTLCompareFunctionAlways; d.depthWriteEnabled = wr;
    if (st) {
        MTLStencilDescriptor *f = [MTLStencilDescriptor new], *b = [MTLStencilDescriptor new];
        f.stencilCompareFunction = cmpf(r->rs[56]); f.stencilFailureOperation = sop(r->rs[53]); f.depthFailureOperation = sop(r->rs[54]); f.depthStencilPassOperation = sop(r->rs[55]);
        f.readMask = b.readMask = r->rs[58] & 255; f.writeMask = b.writeMask = r->rs[59] & 255;
        if (two) { b.stencilCompareFunction = cmpf(r->rs[189]); b.stencilFailureOperation = sop(r->rs[186]); b.depthFailureOperation = sop(r->rs[187]); b.depthStencilPassOperation = sop(r->rs[188]); }
        else { b.stencilCompareFunction = f.stencilCompareFunction; b.stencilFailureOperation = f.stencilFailureOperation; b.depthFailureOperation = f.depthFailureOperation; b.depthStencilPassOperation = f.depthStencilPassOperation; }
        d.frontFaceStencil = f; d.backFaceStencil = b;   /* front: clockwise (the encoder's winding), as D3D */
    }
    id<MTLDepthStencilState> s = [r->dev newDepthStencilStateWithDescriptor:d];
    if (r->gdso_n < 192) { r->gdso_k[h] = key; r->gdso_v[h] = s; r->gdso_n++; }
    return s;
}
typedef struct { uint32_t reg, fmt, off, buf; } GAttr;          /* a register's format, offset and buffer index */
typedef struct { uint32_t stride, step; } GLayout;               /* step: 0 per vertex, 1 constant */
static id<MTLRenderPipelineState> gpipeline(DSRRenderer *r, GP *g, const GAttr *at, int na, const GLayout *lay, int nl, Surf *rt, Surf *ds)
{
    uint32_t blend = r->rs[27] ? 1 : 0, src = r->rs[19], dst = r->rs[20], sep = r->rs[206], sa = sep ? r->rs[207] : src, da = sep ? r->rs[208] : dst, op = r->rs[171], opa = sep ? r->rs[209] : op;
    if (src == 12) { src = 5; dst = 6; } if (src == 13) { src = 6; dst = 5; } if (sa == 12) { sa = 5; da = 6; } if (sa == 13) { sa = 6; da = 5; }
    src = target_bf(r, src); dst = target_bf(r, dst); sa = target_bf(r, sa); da = target_bf(r, da);
    MTLPixelFormat cpf = rt->tex.pixelFormat; uint32_t cw = r->rs[168] & 15;
    uint32_t k[8] = {g->hash, blend, blend ? src | dst << 4 | sa << 8 | da << 12 | op << 16 | opa << 20 : 0, cw, (uint32_t)cpf, ds ? 1 : 0, (uint32_t)na, (uint32_t)nl};
    uint32_t h1 = fnv1a(fnv1a(fnv1a(2166136261u, k, sizeof k), at, sizeof *at * (size_t)na), lay, sizeof *lay * (size_t)nl);
    uint64_t key = ((uint64_t)h1 << 32 | (uint64_t)fnv1a(h1 ^ 0x5bd1e995u, k, sizeof k)) | 1;
    uint32_t h = (uint32_t)(key * 0x9e3779b97f4a7c15ull >> 52);
    while (r->gpso_k[h] && r->gpso_k[h] != key) h = (h + 1) & 4095;
    if (r->gpso_k[h]) return r->gpso_v[h];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new]; NSError *err = nil;
    d.vertexFunction = g->vs; d.fragmentFunction = g->fs;
    d.colorAttachments[0].pixelFormat = cpf;
    d.colorAttachments[0].writeMask = (cw & 1 ? MTLColorWriteMaskRed : 0) | (cw & 2 ? MTLColorWriteMaskGreen : 0) | (cw & 4 ? MTLColorWriteMaskBlue : 0) | (cw & 8 ? MTLColorWriteMaskAlpha : 0);
    if (ds) d.depthAttachmentPixelFormat = d.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    if (blend) {
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[0]; c.blendingEnabled = YES;
        c.sourceRGBBlendFactor = gbf(src); c.destinationRGBBlendFactor = gbf(dst); c.sourceAlphaBlendFactor = gbf(sa); c.destinationAlphaBlendFactor = gbf(da);
        c.rgbBlendOperation = gbop(op); c.alphaBlendOperation = gbop(opa);
    }
    MTLVertexDescriptor *v = [MTLVertexDescriptor vertexDescriptor];
    for (int k2 = 0; k2 < na; k2++) { v.attributes[at[k2].reg].format = (MTLVertexFormat)at[k2].fmt; v.attributes[at[k2].reg].offset = at[k2].off; v.attributes[at[k2].reg].bufferIndex = at[k2].buf; }
    for (int k2 = 0; k2 < nl; k2++) { v.layouts[VB_FIRST + k2].stride = lay[k2].stride ? lay[k2].stride : 16;
        if (lay[k2].step) { v.layouts[VB_FIRST + k2].stepFunction = MTLVertexStepFunctionConstant; v.layouts[VB_FIRST + k2].stepRate = 0; } }
    for (int k2 = 0; k2 < na; k2++) if (at[k2].buf == VB_DEFAULTS) {   /* (Metal: a layout only for a buffer an attribute reads) */
        v.layouts[VB_DEFAULTS].stride = 16; v.layouts[VB_DEFAULTS].stepFunction = MTLVertexStepFunctionConstant; v.layouts[VB_DEFAULTS].stepRate = 0; break; }
    d.vertexDescriptor = v;
    double t0 = CACurrentMediaTime();
    id<MTLRenderPipelineState> pso = [r->dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!pso) { static int n; if (n++ < 20) fprintf(stderr, "dsr: pipeline for game shader %08x: %s\n", g->hash, err.localizedDescription.UTF8String); }
    static int psolog = -1; if (psolog < 0) psolog = getenv("DSR_PSOLOG") != 0;
    if (psolog) fprintf(stderr, "dsr: game pipeline %08x in %.1f ms (frame %d)\n", g->hash, (CACurrentMediaTime() - t0) * 1000, dsr_frame);
    if (r->gpso_n < 3072) { r->gpso_k[h] = key; r->gpso_v[h] = pso; r->gpso_n++; }     /* (a failure is remembered too: nil) */
    return pso;
}
/* DSR_DRAW_PROG (vb 0: float4 vertices in the command) or DSR_DRAW_PROG_VB (vb 1: elements of kept buffers) */
static void gdraw(DSRRenderer *r, const uint32_t *p, uint32_t size, int vb)
{
    uint32_t prim = p[0], mask = vb ? 0 : p[1] & 0xffff, nv = vb ? p[1] : p[2], ni = vb ? p[2] : p[3], flags = vb ? p[3] : p[4], ns = (uint32_t)__builtin_popcount(mask);
    GP *g = gp_of(r, r->gp_cur); dsr_stat[0]++;
    if (!g || !g->ok || !nv || (vb ? 36ull + 20ull * p[8] > size : 20ull + 16ull * nv * ns + 2ull * ni > size)) { dsr_stat[1]++; return; }
    if (prim == 6 && (ni ? ni : nv) < 3) return;
    Surf *rt = surf(r, r->rt), *ds = surf(r, r->ds); if (!rt || !rt->tex) { dsr_stat[2]++; return; }
    ds = depth_with(r, rt, ds);
    { static const char *skip; static int init; if (!init) { init = 1; skip = getenv("DSR_SKIP_PROG"); }   /* DSR_SKIP_PROG=hash,...: those programs' draws left out */
      if (skip) { char hx[16]; snprintf(hx, sizeof hx, "%08x", g->hash); if (strstr(skip, hx)) return; } }
    /* the vertex layout: registers from elements (or the command's float4 slots), the rest (0, 0, 0, 1) */
    GAttr at[16]; GLayout lay[16]; __unsafe_unretained id<MTLBuffer> lbuf[16]; uint32_t loff[16]; int na = 0, nl = 0; uint16_t have = 0;
    uint32_t inl_bytes = vb ? 0 : nv * ns * 16;
    if (vb) {
        const uint32_t *e = p + 9;
        for (uint32_t k = 0; k < p[8] && k < 16; k++, e += 5) {
            uint32_t slot = e[0], bid = e[1], off = e[2], stride = e[3]; MTLVertexFormat f = decl_format(e[4]);
            if (slot >= 32 || !g->slot_reg[slot] || bid >= DSR_VBUFS || !r->vb[bid] || f == MTLVertexFormatInvalid) continue;
            uint32_t reg = g->slot_reg[slot] - 1u; if (!(g->in_regs >> reg & 1) || (have >> reg & 1)) continue;
            uint32_t aoff = stride ? off % stride : 0, boff = off - aoff; int l = 0;
            while (l < nl && !(lbuf[l] == r->vb[bid] && loff[l] == boff && lay[l].stride == stride)) l++;
            if (l == nl) { if (nl == VB_DEFAULTS - VB_FIRST) continue; lbuf[nl] = r->vb[bid]; loff[nl] = boff; lay[nl].stride = stride; lay[nl].step = stride == 0; nl++; r->vb_use[bid] = r->cb_serial + (r->cb ? 0 : 1); }
            at[na++] = (GAttr){reg, (uint32_t)f, aoff, (uint32_t)(VB_FIRST + l)}; have |= (uint16_t)(1u << reg);
        }
    } else if (ns) {
        lay[0].stride = ns * 16; lay[0].step = 0; lbuf[0] = nil; loff[0] = 0; nl = 1;
        for (uint32_t sl = 0, c = 0; sl < 32; sl++) if (mask >> sl & 1) {
            uint32_t reg = g->slot_reg[sl] ? g->slot_reg[sl] - 1u : 99;
            if (reg < 16 && (g->in_regs >> reg & 1) && !(have >> reg & 1)) { at[na++] = (GAttr){reg, MTLVertexFormatFloat4, c * 16, VB_FIRST}; have |= (uint16_t)(1u << reg); }
            c++;
        }
    }
    for (uint32_t reg = 0; reg < 16; reg++) if ((g->in_regs >> reg & 1) && !(have >> reg & 1)) at[na++] = (GAttr){reg, MTLVertexFormatFloat4, 0, VB_DEFAULTS};
    id<MTLRenderPipelineState> pso = gpipeline(r, g, at, na, lay, nl, rt, ds); if (!pso) { dsr_stat[3]++; return; }
    /* indices: from a kept buffer, or the command's own; fans become lists */
    uint32_t count = ni ? ni : nv, isz = vb && (flags & 2) ? 4 : 2;
    const uint8_t *isrc = NULL; id<MTLBuffer> ibuf = nil; uint32_t ioff = 0;
    if (vb && ni) { if (p[4] >= DSR_VBUFS || !r->vb[p[4]] || (uint64_t)p[5] + (uint64_t)ni * isz > r->vb[p[4]].length) { dsr_stat[1]++; return; }
                    ibuf = r->vb[p[4]]; ioff = p[5]; isrc = (const uint8_t *)ibuf.contents + ioff; r->vb_use[p[4]] = r->cb_serial + (r->cb ? 0 : 1); }
    else if (ni) isrc = (const uint8_t *)(p + 5) + inl_bytes;
    ring_room(r, (uint64_t)inl_bytes + (uint64_t)ni * isz + r->vcb_len + r->pcb_len + 64 + (uint64_t)count * 12);
    uint32_t voff = 0, cvoff = 0, cpoff = 0, xoff = 0, fix_off, at_off;
    if (inl_bytes) memcpy(ring_alloc(r, inl_bytes, &voff), p + 5, inl_bytes);
    if (r->vcb_len) memcpy(ring_alloc(r, r->vcb_len, &cvoff), r->vcb, r->vcb_len);
    if (r->pcb_len) memcpy(ring_alloc(r, r->pcb_len, &cpoff), r->pcb, r->pcb_len);
    float vpw = r->vp[2] ? r->vp[2] : rt->w, vph = r->vp[3] ? r->vp[3] : rt->h;
    { float fix[4] = {1.0f / vpw, -1.0f / vph, 0, 0}; memcpy(ring_alloc(r, 16, &fix_off), fix, 16); }   /* D3D9 pixel centres (d3d9_shader.c msl_vs) */
    memcpy(ring_alloc(r, 16, &at_off), r->atest, 16);
    MTLIndexType it = isz == 4 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16; uint32_t icount = count; MTLPrimitiveType pt;
    switch (prim) { case 1: pt = MTLPrimitiveTypePoint; break; case 2: pt = MTLPrimitiveTypeLine; break; case 3: pt = MTLPrimitiveTypeLineStrip; break;
                    case 5: pt = MTLPrimitiveTypeTriangleStrip; break; default: pt = MTLPrimitiveTypeTriangle; }
    int indexed = ni != 0;
    if (prim == 6) {                                  /* a fan: as a list of 32-bit indices */
        uint32_t tris = count - 2; uint32_t *ix = ring_alloc(r, tris * 12, &xoff);
        for (uint32_t k = 0; k < tris; k++) for (int j = 0; j < 3; j++) { uint32_t n = j ? k + (uint32_t)j : 0;
            ix[k * 3 + (uint32_t)j] = isrc ? (isz == 4 ? ((const uint32_t *)isrc)[n] : ((const uint16_t *)isrc)[n]) : (vb ? p[7] : 0) + n; }
        it = MTLIndexTypeUInt32; icount = tris * 3; pt = MTLPrimitiveTypeTriangle; indexed = 2;
    } else if (ni && (!ibuf || (ioff & 3))) {         /* the command's indices (or a kept buffer's at an unaligned offset): from the ring */
        void *ix = ring_alloc(r, ni * isz, &xoff); memcpy(ix, isrc, (size_t)ni * isz); indexed = 2;
    }
    id<MTLRenderCommandEncoder> e = enc_for(r, r->rt, r->ds); if (!e) { dsr_stat[4]++; return; }
    [e setRenderPipelineState:pso]; [e setDepthStencilState:gdepth_for(r, ds != NULL)];
    if (ds && r->rs[52]) [e setStencilReferenceValue:r->rs[57] & 255];
    uint32_t cull = r->rs[22]; [e setCullMode:cull == 2 ? MTLCullModeFront : cull == 3 ? MTLCullModeBack : MTLCullModeNone];
    { float bias, slope; memcpy(&bias, &r->rs[195], 4); memcpy(&slope, &r->rs[175], 4); [e setDepthBias:bias * 16777216.0f slopeScale:slope clamp:0]; }
    { uint32_t f = r->rs[193]; [e setBlendColorRed:((f >> 16) & 255) / 255.f green:((f >> 8) & 255) / 255.f blue:(f & 255) / 255.f alpha:(f >> 24) / 255.f]; }
    [e setViewport:(MTLViewport){r->vp[0] * rt->sc, r->vp[1] * rt->sc, vpw * rt->sc, vph * rt->sc, r->vp[4], r->vp[5] ? r->vp[5] : 1}];
    {   /* the scissor (SCISSORTESTENABLE 174), within the target; the whole target otherwise */
        NSUInteger tw = MAX(rt->tex.width >> rt->level, 1u), th = MAX(rt->tex.height >> rt->level, 1u);
        int32_t x0 = 0, y0 = 0, x1 = (int32_t)tw, y1 = (int32_t)th;
        if (r->rs[174]) { x0 = (int32_t)(r->scissor[0] * rt->sc); y0 = (int32_t)(r->scissor[1] * rt->sc); x1 = (int32_t)(r->scissor[2] * rt->sc); y1 = (int32_t)(r->scissor[3] * rt->sc);
            if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0; if (x1 > (int32_t)tw) x1 = (int32_t)tw; if (y1 > (int32_t)th) y1 = (int32_t)th; }
        if (x1 <= x0 || y1 <= y0) { memset(&r->es, 0, sizeof r->es); r->es.cull = -1; return; }
        [e setScissorRect:(MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)}];
    }
    if (r->vcb_len) [e setVertexBuffer:r->ring offset:cvoff atIndex:0];
    [e setVertexBuffer:r->ring offset:fix_off atIndex:1];
    if (r->pcb_len) [e setFragmentBuffer:r->ring offset:cpoff atIndex:0];
    [e setFragmentBuffer:r->ring offset:at_off atIndex:1];
    for (int l = 0; l < nl; l++) [e setVertexBuffer:lbuf[l] ? lbuf[l] : r->ring offset:lbuf[l] ? loff[l] : voff atIndex:(NSUInteger)(VB_FIRST + l)];
    [e setVertexBuffer:r->attr_defaults offset:0 atIndex:VB_DEFAULTS];
    for (int k = 0; k < 16; k++) {                   /* each sampler: the stage's texture, if it is of the shader's type */
        if (!g->samp[k]) continue;
        Surf *t = surf(r, r->tex[k]); id<MTLTexture> x;
        if (g->samp[k] == 2) x = t && t->tex.textureType == MTLTextureTypeCube ? (t->sview ? t->sview : t->tex) : r->dummy_cube;
        else if (g->samp[k] == 3) x = t && t->tex.textureType == MTLTextureType3D ? t->tex : r->dummy_3d;
        else x = t && t->tex && (t->view2d || t->tex.textureType == MTLTextureType2D) && !(t->tex == rt->tex) ? tex_sampled(t) : r->dummy;
        [e setFragmentTexture:x atIndex:(NSUInteger)k]; [e setFragmentSamplerState:sampler_for(r, k) atIndex:(NSUInteger)k];
    }
    if (indexed == 2) [e drawIndexedPrimitives:pt indexCount:icount indexType:it indexBuffer:r->ring indexBufferOffset:xoff instanceCount:1 baseVertex:vb ? (NSInteger)(int32_t)p[6] : 0 baseInstance:0];
    else if (indexed) [e drawIndexedPrimitives:pt indexCount:icount indexType:it indexBuffer:ibuf indexBufferOffset:ioff instanceCount:1 baseVertex:(NSInteger)(int32_t)p[6] baseInstance:0];
    else [e drawPrimitives:pt vertexStart:vb ? p[7] : 0 vertexCount:nv];
    [e setScissorRect:(MTLScissorRect){0, 0, MAX(rt->tex.width >> rt->level, 1u), MAX(rt->tex.height >> rt->level, 1u)}];   /* the other paths draw without one */
    [e setDepthBias:0 slopeScale:0 clamp:0];
    memset(&r->es, 0, sizeof r->es); r->es.cull = -1;   /* the fixed-function path sets its state again */
}
/* ---- occlusion queries (DSR_QUERY): samples counted into the visibility buffer, a slot per render pass the query spans
 * (Metal counts per pass); the sum is published when the command buffer that ended the query has finished ---- */
#define VIS_SLOTS 8192
static void query_segment(DSRRenderer *r)            /* the active query in the current encoder: a fresh slot */
{
    if (!r->enc || !r->vis || r->nqseg >= 64) return;
    uint32_t slot = r->vis_next++ % VIS_SLOTS; ((uint64_t *)r->vis.contents)[slot] = 0;
    r->qseg[r->nqseg++] = slot; [r->enc setVisibilityResultMode:MTLVisibilityResultModeCounting offset:slot * 8];
}
void dsr_renderer_set_queries(DSRRenderer *r, volatile uint32_t *results) { r->qres = results; }
static void query(DSRRenderer *r, const uint32_t *p)
{
    uint32_t k = p[0]; if (!k || k >= 1024) return;
    if (!r->vis) return;                             /* (made with the renderer: every render pass has to carry it) */
    if (p[1]) {                                       /* begin (one active at a time, as the OpenGL renderer) */
        if (r->qactive && r->enc) [r->enc setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
        r->qactive = (int)k; r->nqseg = 0;
        if (r->enc) query_segment(r);                 /* (else the next encoder starts the first segment) */
        return;
    }
    if (r->qactive != (int)k) { if (r->qres) { r->qres[k] = 1000; __atomic_store_n(&r->qres[1024 + k], p[2], __ATOMIC_RELEASE); } return; }   /* an End without a Begin */
    if (r->enc) [r->enc setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
    r->qactive = 0;
    uint32_t n = r->nqseg, serial = p[2]; uint32_t *segs = malloc(sizeof r->qseg); memcpy(segs, r->qseg, sizeof r->qseg); r->nqseg = 0;
    volatile uint32_t *qres = r->qres; id<MTLBuffer> vis = r->vis;
    [cmdbuf(r) addCompletedHandler:^(id<MTLCommandBuffer> cb) { (void)cb;
        uint64_t sum = 0; for (uint32_t j = 0; j < n; j++) sum += ((const uint64_t *)vis.contents)[segs[j]];
        free(segs);
        if (getenv("DSR_QUERYLOG")) fprintf(stderr, "query %u serial %u -> %llu (%u passes)\n", k, serial, (unsigned long long)sum, n);
        if (qres) { qres[k] = (uint32_t)(sum > 0xffffffffu ? 0xffffffffu : sum); __atomic_store_n(&qres[1024 + k], serial, __ATOMIC_RELEASE); } }];
}

int dsr_renderer_exec(DSRRenderer *r, uint32_t op, const uint8_t *pl, uint32_t size)
{
    const uint32_t *p = (const uint32_t *)pl;
    {   static int tracing, base = -2; if (base == -2) base = getenv("DSR_TRACEBASE") ? atoi(getenv("DSR_TRACEBASE")) : -1;
        if (tracing) trace_cmd(r, op, p, size);
        if (op == DSR_PRESENT) {
            if (tracing) { tracing = 0; fprintf(stderr, "trace: end\n"); }
            else if (dsr_trace_req || dsr_frame + 1 == base) { dsr_trace_req = 0; tracing = 1; fprintf(stderr, "trace: frame %d begins\n", dsr_frame + 1); }
        } }
    switch (op) {
    case DSR_RENDER_STATE: if (p[0] < 256) r->rs[p[0]] = p[1]; break;
    case DSR_TSS: if (p[0] < 16 && p[1] < 32) { r->tss[p[0]][p[1]] = p[2]; if (p[1] == 12) r->tss[p[0]][13] = r->tss[p[0]][14] = p[2]; } break;
    case DSR_TEXTURE: if (p[0] < 16) r->tex[p[0]] = p[1]; break;
    case DSR_TRANSFORM: if (p[0] < 32) memcpy(r->xf[p[0]], p + 1, 64); break;
    case DSR_VIEWPORT: r->vp[0] = p[0]; r->vp[1] = p[1]; r->vp[2] = p[2]; r->vp[3] = p[3]; memcpy(&r->vp[4], p + 4, 8); break;
    case DSR_CLEAR: { static int n = -1; if (n < 0) n = getenv("DSR_RTLOG") ? atoi(getenv("DSR_RTLOG")) : 0;
        Surf *t = surf(r, r->rt); if (n > 0 && t && t->kind == 3) { n--; fprintf(stderr, "dsr: clear of %u: flags %x colour %08x\n", r->rt, p[0], p[1]); } }
        clear(r, p, size); break;
    case DSR_DRAW: draw(r, p, size); if (r->fl_on) r->fl_ff++; break;
    case DSR_SET_RT: if (r->fl_on && p[0] != r->rt) r->fl_rtsw++; r->rt = p[0]; r->ds = p[1];
        { static int n = -1; if (n < 0) n = getenv("DSR_RTLOG") ? atoi(getenv("DSR_RTLOG")) : 0;          // development: off-screen targets
          Surf *t = surf(r, p[0]); if (n > 0 && r->rs[28]) { n--; fprintf(stderr, "dsr: frame %d: render target %u (%ux%u) depth %u, after %ld draws\n", dsr_frame, p[0], t ? t->w : 0, t ? t->h : 0, p[1], dsr_stat[0]); } }
        break;
    case DSR_SURFACE_CREATE: surface_create(r, p, size); break;
    case DSR_SURFACE_DESTROY: if (p[0] < MAXSURF) { r->s[p[0]].used = 0; r->s[p[0]].tex = nil; } break;
    case DSR_SURFACE_UPLOAD: surface_upload(r, p, size); break;
    case DSR_UPLOAD_OVER: upload_over(r, p, size); break;
    case DSR_READBACK: readback(r, p); break;
    case DSR_BLT: { int32_t dr[4], sr[4]; memcpy(dr, p + 1, 16); memcpy(sr, p + 6, 16);
                    if (p[5]) quad(r, p[0], dr, p[5], sr, 0, 0); else if (!(p[10] & 0x20000)) quad(r, p[0], dr, 0, dr, 1, p[11]); } break;
    case DSR_PRESENT: r->presented = p[0]; dsr_frame++;   // caller presents/commits
        { static int glow = -1; if (glow < 0) glow = getenv("DSR_GLOWLOG") != 0;   // development: effect targets in the corner
          if (glow) { int x = 0; for (uint32_t id = 1; id < MAXSURF && x < 5 * 260; id++) if (r->s[id].used && r->s[id].fxrt) {
              int32_t d[4] = {x, 0, x + 256, 256}, sr[4] = {0, 0, 256, 256}; uint32_t ort = r->rt; quad(r, p[0], d, id, sr, 0, 0); r->rt = ort; x += 260; } } }
        { static int show = -1; if (show < 0) show = getenv("DSR_SHOWSURF") ? atoi(getenv("DSR_SHOWSURF")) : 0;   // development: a surface in the corner
          Surf *t = surf(r, (uint32_t)show); if (show > 0 && t) { int32_t d[4] = {0, 0, (int32_t)t->w, (int32_t)t->h}, sr[4] = {0, 0, (int32_t)t->w, (int32_t)t->h};
            uint32_t ort = r->rt; quad(r, p[0], d, (uint32_t)show, sr, 0, 0); r->rt = ort; } }
        r->present_ts = (size >= 16 && p[3]) ? (((uint64_t)p[2] << 32) | p[1]) / (double)p[3] : -1; return 1;
    case DSR_PROG_CREATE: prog_create(r, p, size); break;
    case DSR_PROG_USE: r->cur_prog = p[0] < 1024 ? p[0] : 0; r->gp_cur = p[0]; break;
    case DSR_PROG_CONST: if (size >= 4 && p[0] <= 4096 && 4 + 16 * (uint64_t)p[0] <= size) { memcpy(r->pconst, p + 1, 16 * (size_t)p[0]); r->npconst = p[0]; } break;
    case DSR_DRAW_PROG: if (r->gp_cur >= GP_BASE) { if (size >= 20) gdraw(r, p, size, 0); } else draw_prog(r, p, size); break;
    case DSR_MSL_CREATE: if (size >= 16) msl_create(r, p, size); break;
    case DSR_SHADER_CONST: if (size >= 24) shader_consts(r, p, size); break;
    case DSR_DRAW_PROG_VB: if (size >= 36) gdraw(r, p, size, 1); break;
    case DSR_VBUF_DATA: if (size >= 16) vbuf_data(r, p, size); break;
    case DSR_VBUF_FREE: if (size >= 4 && p[0] < DSR_VBUFS) { r->vb[p[0]] = nil; r->vb_use[p[0]] = 0; } break;
    case DSR_QUERY: if (size >= 12) query(r, p); break;
    case DSR_SCISSOR: if (size >= 16) memcpy(r->scissor, p, 16); break;
    case DSR_MODE: r->mode_w = p[0]; r->mode_h = p[1]; break;
    case DSR_CURSOR: if (size >= 12) { r->cur_x = (int32_t)p[0]; r->cur_y = (int32_t)p[1]; r->cur_show = (int32_t)p[2]; }
        if (size >= 28 && p[3] && p[4] && p[3] <= 256 && p[4] <= 256 && 28 + 4ull * p[3] * p[4] <= size) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:p[3] height:p[4] mipmapped:NO];
            d.usage = MTLTextureUsageShaderRead; d.storageMode = MTLStorageModeShared;
            id<MTLTexture> t = [r->dev newTextureWithDescriptor:d];
            [t replaceRegion:MTLRegionMake2D(0, 0, p[3], p[4]) mipmapLevel:0 withBytes:p + 7 bytesPerRow:4 * p[3]];
            r->cur_tex = t; r->cur_hx = (int32_t)p[5]; r->cur_hy = (int32_t)p[6];
        }
        break;
    case DSR_GAMMA: if (size >= 1536) { memcpy(r->gamma, p, 1536); r->gamma_dirty = 1; } break;
    default: break;
    }
    return 0;
}
