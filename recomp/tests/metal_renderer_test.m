/* Synthetic fixtures exercise the real Metal backend; no game assets required. */
#include <assert.h>
#import "../../src/renderer/renderer.m"
static DSRRenderer *r;
static void cmd(unsigned op, const void *p, unsigned n) { dsr_renderer_exec(r, op, p, n); }
static void state(unsigned key, unsigned value) { uint32_t p[] = {key, value}; cmd(DSR_RENDER_STATE, p, sizeof p); }
static void sampler_state(unsigned key, unsigned value) { uint32_t p[] = {0, key, value}; cmd(DSR_TSS, p, sizeof p); }
static void tile(float end)
{
    struct V { float x,y,z,w; uint32_t color; float u,v; } verts[4] = {
        {0,0,.5,1,0xffffffff,0,0}, {32,0,.5,1,0xffffffff,end,0},
        {0,32,.5,1,0xffffffff,0,end}, {32,32,.5,1,0xffffffff,end,end}};
    uint32_t data[4 + sizeof verts / 4] = {5, 0x144, 4, 0}; memcpy(data + 4, verts, sizeof verts);
    cmd(DSR_DRAW, data, sizeof data);
}
static uint32_t pixel(void)
{
    volatile uint32_t done = 0; uint32_t px = 0;
    dsr_renderer_set_readback(r, &px, 4, &done);
    uint32_t p[] = {1,16,16,1,1,7}; cmd(DSR_READBACK, p, sizeof p);
    assert(done == 7); return px;
}
int main(void)
{
    @autoreleasepool {
        setenv("DSR_RINGMB", "4", 1);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "Metal GPU unavailable\n"); return 77; }
        r = dsr_renderer_create(dev);
        uint32_t rt[] = {1,32,32,1,1,0,0,1}; cmd(DSR_SURFACE_CREATE,rt,sizeof rt);
        uint32_t bind[] = {1,0}; cmd(DSR_SET_RT,bind,sizeof bind);
        uint32_t vp[] = {0,0,32,32,0,0x3f800000}; cmd(DSR_VIEWPORT,vp,sizeof vp);
        state(22,1); state(7,0); state(27,0); sampler_state(1,2); sampler_state(2,2); sampler_state(4,2); sampler_state(5,2);
        uint32_t tex[] = {2,2,2,3,1,0,0,2}; cmd(DSR_SURFACE_CREATE,tex,sizeof tex);
        uint32_t upload[] = {2,0,0,2,2,8,0xffff0000,0xffff0000,0xffff0000,0xffff0000}; cmd(DSR_SURFACE_UPLOAD,upload,sizeof upload);
        uint32_t mip[] = {3,1,1,3,1,2,1,2}; cmd(DSR_SURFACE_CREATE,mip,sizeof mip);
        uint32_t green[] = {3,0,0,1,1,4,0xff00ff00}; cmd(DSR_SURFACE_UPLOAD,green,sizeof green);
        uint32_t tx[] = {0,2}; cmd(DSR_TEXTURE,tx,sizeof tx); sampler_state(18,2);
        tile(1); assert((pixel() & 0xffffff) == 0xff0000);
        id<MTLSamplerState> original = sampler_for(r,0);
        sampler_state(20,1); tile(1); assert((pixel() & 0xffffff) == 0x00ff00);
        assert(sampler_for(r,0) != original); sampler_state(20,0); assert(sampler_for(r,0) == original);
        sampler_state(16,3); sampler_state(17,3); sampler_state(21,16); assert(sampler_descriptor(r->tss[0]).maxAnisotropy == 16);
        sampler_state(17,1); sampler_state(16,1); assert(sampler_descriptor(r->tss[0]).maxAnisotropy == 1);
        sampler_state(25,3); assert(sampler_descriptor(r->tss[0]).rAddressMode == MTLSamplerAddressModeClampToEdge);
        sampler_state(13,4); sampler_state(14,4); sampler_state(15,0xffffffff); tile(20); assert((pixel() & 0xffffff) == 0xffffff);
        sampler_state(13,1); sampler_state(14,1); sampler_state(18,1);
        for (int k=6;k<10;k++) upload[k]=0xff808080; cmd(DSR_SURFACE_UPLOAD,upload,sizeof upload);
        tile(1); assert((pixel() & 255) == 128);
        sampler_state(29,1); tile(1); unsigned linear = pixel() & 255; assert(linear >= 54 && linear <= 56);
        sampler_state(29,0);
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
        if (@available(macOS 26.0, *)) {
            float bias = 2; uint32_t bits; memcpy(&bits,&bias,4); sampler_state(19,bits);
            assert(sampler_descriptor(r->tss[0]).lodBias == 2);
        }
#endif
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 vsmain(uint v [[vertex_id]]) { return float4(v,0,0,1); }\nfragment float4 psmain() { return float4(1,0,0,1); }";
        NSError *err = nil;
        id<MTLFunction> vs = [r->cache function:src entry:@"vsmain" error:&err]; assert(vs);
        NSUInteger misses = r->cache->functionMisses;
        assert(vs == [r->cache function:src entry:@"vsmain" error:&err]); assert(r->cache->functionMisses == misses);
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction=vs; d.fragmentFunction=[r->cache function:src entry:@"psmain" error:&err]; d.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
        assert([r->cache pipeline:d error:&err]); [r->cache save:YES];
        DSRMetalCache *warm = [[DSRMetalCache alloc] initWithDevice:dev]; [warm warm];
        NSUInteger warmMisses=warm->functionMisses;
        d.vertexFunction=[warm function:src entry:@"vsmain" error:&err]; d.fragmentFunction=[warm function:src entry:@"psmain" error:&err];
        assert(warm->functionMisses == warmMisses);
        assert([warm pipeline:d error:&err]); assert(warm->pipelineHits == 1 && warm->pipelineMisses == 0);
        [@"known driver failure" writeToFile:[warm->directory stringByAppendingPathComponent:@"archive-read-only"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        DSRMetalCache *readOnly=[[DSRMetalCache alloc] initWithDevice:dev]; assert(readOnly->archiveReadOnly);
        assert([readOnly pipeline:d error:&err]); assert(readOnly->pipelineHits == 1);
        [NSFileManager.defaultManager removeItemAtPath:[warm->directory stringByAppendingPathComponent:@"archive-read-only"] error:nil];
        // Corrupt archives are disposable: compilation still succeeds.
        NSString *archivePath=[warm->directory stringByAppendingPathComponent:@"pipelines.metalarc"];
        [@"invalid" writeToFile:archivePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        DSRMetalCache *bad=[[DSRMetalCache alloc] initWithDevice:dev]; assert([bad pipeline:d error:&err]);
        bad->directory=[bad->directory stringByAppendingPathComponent:@"missing/parent"];
        bad->dirty=YES; [bad save:YES]; assert([bad pipeline:d error:&err]);
        puts("Metal: mip selection, anisotropy, addressing, sRGB, shader reuse and persistent/corrupt cache passed");
    }
}
