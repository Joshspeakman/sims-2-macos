/* Expose the actual fallback shader and state packing to the Metal pixel test. */
#include "../runtime/win32/d3d9_shader.c"
#include "../runtime/win32/d3d9_fmt.c"
#include <assert.h>

char *test_ff_msl(void) { return msl_ps(FF_MSL_PS); }
void test_ff_constants(unsigned stage, int projected, float out[11][4])
{
    Dev9 d = {0}; Tex9 tex = {0}; tex.fmt = 21;
    assert(stage < FF_STAGES && FF_CONSTS == 11);
    for (unsigned s = 0; s < FF_STAGES; s++) {
        d.tss[s][1] = s > stage ? 1 : 2; /* DISABLE / SELECTARG1 */
        d.tss[s][2] = s == stage ? 2 : 1; /* TEXTURE / CURRENT */
        d.tss[s][4] = 1;
        d.tss[s][24] = s == stage ? (projected ? 0x100 : 4) : 0;
    }
    d.tex[stage] = &tex;
    ff_consts(&d, out);
    for (unsigned s = 0; s < FF_STAGES; s++) assert(out[10][s] == (float)(s == stage && projected));
}
