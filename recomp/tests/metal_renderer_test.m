/* Synthetic fixtures exercise the real Metal backend; no game assets required. */
#include <assert.h>
#import "../../src/renderer/renderer.m"
static DSRRenderer *r;
extern char *test_ff_msl(void);
extern void test_ff_constants(unsigned stage, int projected, float out[11][4]);
static void projected_texture_test(id<MTLDevice> dev)
{
    char *fragment = test_ff_msl();
    NSString *source = [NSString stringWithUTF8String:fragment]; free(fragment);
    source = [source stringByAppendingString:@"\nstruct Out { float4 pos [[position]]; float4 d0 [[user(color0)]]; float4 d1 [[user(color1)]]; float4 t0 [[user(texcoord0)]]; float4 t1 [[user(texcoord1)]]; float4 t2 [[user(texcoord2)]]; float4 t3 [[user(texcoord3)]]; };\nvertex Out fixture(uint i [[vertex_id]]) { Out o; o.pos=float4(i==1?3:-1,i==2?3:-1,0,1); o.d0=float4(1); o.d1=float4(0); o.t0=o.t1=o.t2=o.t3=float4(.75,.25,7,2); return o; }\n"];
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:source options:nil error:&err];
    if (!lib) NSLog(@"%@", err); assert(lib);
    MTLRenderPipelineDescriptor *pipeline = [MTLRenderPipelineDescriptor new];
    pipeline.vertexFunction=[lib newFunctionWithName:@"fixture"]; pipeline.fragmentFunction=[lib newFunctionWithName:@"psmain"];
    pipeline.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> ps=[dev newRenderPipelineStateWithDescriptor:pipeline error:&err]; assert(ps);
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:2 height:1 mipmapped:NO];
    td.storageMode=MTLStorageModeShared;
    id<MTLTexture> tex=[dev newTextureWithDescriptor:td]; uint32_t colors[]={0xffff0000,0xff00ff00};
    [tex replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:colors bytesPerRow:8];
    td.width=1; td.usage=MTLTextureUsageRenderTarget; id<MTLTexture> target=[dev newTextureWithDescriptor:td];
    id<MTLSamplerState> sampler=[dev newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
    id<MTLCommandQueue> queue=[dev newCommandQueue];
    for (unsigned stage=0;stage<4;stage++) for (int projected=0;projected<2;projected++) {
        float constants[11][4], alpha[4]={0}; test_ff_constants(stage,projected,constants);
        id<MTLCommandBuffer> cb=[queue commandBuffer];
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass]; [enc setRenderPipelineState:ps];
        [enc setFragmentBytes:constants length:sizeof constants atIndex:0]; [enc setFragmentBytes:alpha length:sizeof alpha atIndex:1];
        for (unsigned s=0;s<4;s++) { [enc setFragmentTexture:tex atIndex:s]; [enc setFragmentSamplerState:sampler atIndex:s]; }
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        assert(cb.status == MTLCommandBufferStatusCompleted);
        uint32_t result=0; [target getBytes:&result bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        assert((result & 0xffffff) == (projected ? 0xff0000 : 0x00ff00));
    }
    puts("Metal: actual FF shader projects by w in all four stages; unprojected coordinates preserved");
}
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
static void stage_state(unsigned stage, unsigned key, unsigned value)
{
    uint32_t p[] = {stage,key,value}; cmd(DSR_TSS,p,sizeof p);
}
static void world_tile(void)
{
    struct V { float x,y,z; uint32_t color; float u,v; } verts[] = {
        {-1,1,.5,0xffffffff,.75,.25}, {1,1,.5,0xffffffff,.75,.25},
        {-1,-1,.5,0xffffffff,.75,.25}, {1,-1,.5,0xffffffff,.75,.25}};
    uint32_t data[4+sizeof verts/4] = {5,0x142,4,0}; memcpy(data+4,verts,sizeof verts);
    cmd(DSR_DRAW,data,sizeof data);
}
static void fixed_water_test(void)
{
    uint32_t upload[] = {2,0,0,2,2,8,0xffff0000,0xff00ff00,0xffff0000,0xff00ff00};
    cmd(DSR_SURFACE_UPLOAD,upload,sizeof upload);
    for (unsigned st=0;st<3;st++) {
        uint32_t tx[]={st,2}; cmd(DSR_TEXTURE,tx,sizeof tx);
        stage_state(st,13,3); stage_state(st,14,3); stage_state(st,16,1); stage_state(st,17,1); stage_state(st,18,1);
    }
    for (unsigned st=0;st<3;st++) for (unsigned count=2;count<=4;count++) for (int project=0;project<2;project++) {
        for (unsigned k=0;k<3;k++) {
            stage_state(k,1,k>st?1:2); stage_state(k,2,k==st?2:1);
            stage_state(k,4,2); stage_state(k,5,1); stage_state(k,28,1);
        }
        float matrix[16]={0}; matrix[12]=1.5; matrix[13]=.25; matrix[14]=1; matrix[15]=1;
        matrix[12+count-1]=4;
        uint32_t xf[17]={16+st}; memcpy(xf+1,matrix,sizeof matrix); cmd(DSR_TRANSFORM,xf,sizeof xf);
        stage_state(st,11,0x20000); stage_state(st,24,count|(project?0x100:0));
        world_tile(); uint32_t px=pixel();
        if ((px&0xffffff)!=(project?0xff0000:0x00ff00)) fprintf(stderr,"FF projection stage %u count %u projected %d: %08x\n",st,count,project,px);
        assert((px&0xffffff)==(project?0xff0000:0x00ff00));
    }
    for (unsigned st=0;st<3;st++) { stage_state(st,11,0); stage_state(st,24,0); }
    for (int i=6;i<10;i++) upload[i]=0x40ff0000; cmd(DSR_SURFACE_UPLOAD,upload,sizeof upload);
    state(60,0xff0000ff);
    // Keep the first reflected layer in TEMP, the second in CURRENT, then blend by the ripple alpha.
    stage_state(0,1,2); stage_state(0,2,2); stage_state(0,28,5);
    stage_state(1,1,2); stage_state(1,2,3); stage_state(1,28,1);
    stage_state(2,1,13); stage_state(2,2,5); stage_state(2,3,1); stage_state(2,28,1);
    world_tile(); uint32_t px=pixel(); assert(((px>>16)&255)==64 && (px&255)==191);
    // Writing TEMP must leave CURRENT (the incoming diffuse here) intact.
    stage_state(1,2,1); stage_state(2,1,1); world_tile(); assert(pixel()==0xffffffff);
    for (unsigned st=0;st<3;st++) { stage_state(st,1,st?1:2); stage_state(st,2,2); stage_state(st,4,st?1:2); stage_state(st,5,2); stage_state(st,28,1); }
    puts("Metal: fixed-function COUNT2/3/4 projection in all three stages and water TEMP/CURRENT blending passed");
}
int main(void)
{
    @autoreleasepool {
        setenv("DSR_RINGMB", "4", 1);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { fprintf(stderr, "Metal GPU unavailable\n"); return 77; }
        projected_texture_test(dev);
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
        fixed_water_test();
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
