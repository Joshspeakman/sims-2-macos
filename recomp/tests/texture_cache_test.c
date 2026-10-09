#include <assert.h>
#include "../runtime/win32/sims2_texture_cache.c"
static uint8_t memory[8192]; uint8_t *G_MEM=memory;
int w32_deterministic;
static int original_calls, fail;
static uint16_t control_word;
int vm_committed(uint32_t a,uint32_t n) { return a>=64 && (uint64_t)a+n<=sizeof memory; }
void rt_call(Ctx *c,uint32_t addr)
{
    assert(addr==COMPRESS_BC1); assert(inside_compressor); original_calls++;
    assert(!sims2_texture_compress(c)); // Reenter the real compressor exactly once.
    for(int k=0;k<8;k++) G_MEM[ARG(0)+k]=(uint8_t)(G_MEM[ARG(1)+k] ^ ARG(2));
    c->eax=fail?0x80004005u:0; c->esp+=16;
}
static void compress(uint32_t flags)
{
    Ctx c={.esp=128,.ebx=0xdeadbeef,.fcw=control_word}; rt_w32(G_MEM,132,1024); rt_w32(G_MEM,136,2048); rt_w32(G_MEM,140,flags);
    assert(sims2_texture_compress(&c)); assert(c.esp==144 && c.ebx==0xdeadbeef);
}
int main(int argc,char **argv)
{
    assert(argc==2); int reuse=!strcmp(argv[1],"reuse");
    memset(memory+2048,37,BLOCK_BYTES); compress(2); assert(original_calls==(reuse?0:1));
    assert(memory[1024]==(37^2)); memset(memory+1024,0,8); compress(2);
    assert(original_calls==(reuse?0:1) && memory[1024]==(37^2));
    int before=original_calls; uint32_t flags=3+reuse; compress(flags); assert(original_calls==before+1);
    memory[2048+200]++; compress(flags); assert(original_calls==before+2);
    fail=1; memory[2048+201]++; compress(flags); compress(flags); assert(original_calls==before+4);
    fail=0; before=original_calls; control_word=0x027f; compress(flags); assert(original_calls==before+1);
    compress(flags); assert(original_calls==before+1);
    control_word=0x067f; compress(flags); assert(original_calls==before+2);
    if (reuse) block_path[0]=0; // Leave prime fixture unchanged for repeatability.
    puts("Texture cache: input/flags/rounding mode, output, ABI, failed conversions and persistence passed");
}
