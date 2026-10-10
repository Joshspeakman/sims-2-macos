/* Real GPU regression for D3D relative constants, using synthetic bytecode. */
#import <Metal/Metal.h>
#include "mojoshader.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static void relative_constants(id<MTLDevice> dev, int ctab)
{
    const uint32_t code[] = {
        0xfffe0200,                         // vs_2_0
        0x0009fffe, 0x42415443,             // empty CTAB comment
        28, 28, 0xfffe0200, 0, 28, 0, 28, 0,
        0x0200001f, 0x80000000, 0x900f0000, // dcl_position v0
        0x0200001f, 0x80000005, 0x900f0001, // dcl_texcoord v1
        0x05000051, 0xa00f003c, 0x3f800000, 0x40000000, 0x40400000, 0x40800000, // def c60,1,2,3,4
        0x05000051, 0xa00f003d, 0x40a00000, 0x40c00000, 0x40e00000, 0x41000000, // def c61,5,6,7,8
        0x0200002e, 0xb00f0000, 0x90e40001, // mova a0,v1
        0x02000001, 0xc00f0000, 0x90e40000, // mov oPos,v0
        0x03000001, 0xe00f0000, 0xa0e42038, 0xb0000000, // mov oT0,c56[a0.x]
        0x03000001, 0xe00f0001, 0xa0e4203c, 0xb0000000, // mov oT1,c60[a0.x] (DEF array base)
        0x0000ffff
    };
    uint32_t stripped[sizeof code / 4]; stripped[0]=code[0];
    memcpy(stripped+1,code+11,sizeof code-11*4);
    const MOJOSHADER_parseData *pd=MOJOSHADER_parse("metal","fixture",
        (const unsigned char *)(ctab?code:stripped), (unsigned)(sizeof code-(ctab?0:40)),0,0,0,0,0,0,0);
    for (int i=0;i<pd->error_count;i++) fprintf(stderr,"%s\n",pd->errors[i].error);
    assert(pd->error_count==0);
    NSString *source=[NSString stringWithUTF8String:pd->output];
    source=[source stringByAppendingString:@"\nfragment float4 color(fixture_Output i [[stage_in]], constant uint &which [[buffer(0)]]) { return which ? i.oT1 : i.oT0; }\n"];
    NSError *err=nil;
    id<MTLLibrary> lib=[dev newLibraryWithSource:source options:nil error:&err];
    if (!lib) NSLog(@"%@\n%@",err,source); assert(lib);
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];
    d.vertexFunction=[lib newFunctionWithName:@"fixture"]; d.fragmentFunction=[lib newFunctionWithName:@"color"];
    d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA32Float;
    MTLVertexDescriptor *vd=[MTLVertexDescriptor vertexDescriptor];
    for (int i=0;i<2;i++) { vd.attributes[i].format=MTLVertexFormatFloat4; vd.attributes[i].offset=i*16; vd.attributes[i].bufferIndex=1; }
    vd.layouts[1].stride=32; d.vertexDescriptor=vd;
    id<MTLRenderPipelineState> ps=[dev newRenderPipelineStateWithDescriptor:d error:&err];
    if (!ps) NSLog(@"%@",err); assert(ps);
    float globals[256][4], packed[2048][4];
    for (int i=0;i<256;i++) for(int j=0;j<4;j++) globals[i][j]=1000+i*4+j;
    // Poison surrounding storage: an unchecked index must not silently appear correct.
    for (int i=0;i<2048;i++) for(int j=0;j<4;j++) packed[i][j]=12345;
    int n=0;
    for (int i=0;i<pd->uniform_count;i++) {
        const MOJOSHADER_uniform *u=&pd->uniforms[i]; if(u->constant) continue;
        assert(u->type==MOJOSHADER_UNIFORM_FLOAT);
        int count=u->array_count?u->array_count:1;
        assert(n+count<=2048 && u->index+count<=256);
        memcpy(packed+n,globals+u->index,count*16); n+=count;
    }
    id<MTLBuffer> constants=[dev newBufferWithBytes:packed length:sizeof packed options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    td.storageMode=MTLStorageModeShared; td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> target=[dev newTextureWithDescriptor:td]; id<MTLCommandQueue> q=[dev newCommandQueue];
    const int addresses[]={765,0,4,5,6,-1,-56,-57,195,199,200,-60,-61};
    for (unsigned which=0;which<2;which++) for (unsigned a=0;a<sizeof addresses/sizeof *addresses;a++) {
        int index=(which?60:56)+addresses[a];
        float vertices[3][8]={{-1,-1,0,1},{3,-1,0,1},{-1,3,0,1}};
        for(int i=0;i<3;i++) vertices[i][4]=addresses[a];
        id<MTLCommandBuffer> cb=[q commandBuffer]; MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:pass]; [enc setRenderPipelineState:ps];
        [enc setVertexBuffer:constants offset:0 atIndex:0]; [enc setVertexBytes:vertices length:sizeof vertices atIndex:1];
        [enc setFragmentBytes:&which length:sizeof which atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        assert(cb.status==MTLCommandBufferStatusCompleted);
        float result[4]; [target getBytes:result bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
        for(int j=0;j<4;j++) {
            float expected=index<0||index>=256?0:index==60?1+j:index==61?5+j:globals[index][j];
            if(result[j]!=expected) fprintf(stderr,"CTAB=%d base=%u address=%d component=%d: %g expected %g\n",ctab,which?60:56,addresses[a],j,result[j],expected);
            assert(result[j]==expected);
        }
    }
    MOJOSHADER_freeParseData(pd);
}
int main(void)
{
    @autoreleasepool {
        id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); if(!dev) return 77;
        relative_constants(dev,1); relative_constants(dev,0);
        puts("Metal: relative constants preserve signed addressing and DEF overrides, and zero out-of-range reads with/without CTAB");
    }
    return 0;
}
