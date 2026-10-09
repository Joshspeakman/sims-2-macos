/* A cursor survives source mutation and destruction; invalid updates retain it. */
#include <assert.h>
#include "../runtime/win32/d3d9.c"
static uint8_t memory[4096]; uint8_t *G_MEM = memory;
int w32_screen_w = 640, w32_screen_h = 480;
int d9_fmt_bytes(uint32_t f) { return f == 21 ? 4 : 0; }
int cmd_readback(uint32_t id, const int32_t *r, uint8_t *dst, uint32_t pitch, uint32_t bpp) { (void)id; (void)r; (void)dst; (void)pitch; (void)bpp; assert(0); return 0; }
int main(void)
{
    Dev9 d = {0}; Surf9 *s = calloc(1, sizeof *s);
    s->w = s->h = 2; s->fmt = 21; s->mem = 128; s->pitch = 16;
    uint32_t pixels[4] = {0xff123456, 0x00112233, 0xffabcdef, 0x80402010};
    memcpy(memory + 128, pixels, 8); memcpy(memory + 144, pixels + 2, 8);
    assert(cursor_copy(&d, s, 1, 1) == D3D_OK);
    memset(memory + 128, 0, 32); free(s);
    assert(!memcmp(d.cursor, pixels, sizeof pixels)); assert(d.cursor_w == 2 && d.cursor_h == 2);
    Surf9 bad = {.w = 3, .h = 2, .fmt = 21};
    assert(cursor_copy(&d, &bad, 0, 0) == D3DERR_INVALIDCALL);
    assert(!memcmp(d.cursor, pixels, sizeof pixels));
    bad.w = 2; bad.fmt = 22; assert(cursor_copy(&d, &bad, 0, 0) == D3DERR_INVALIDCALL);
    free(d.cursor);
    puts("Cursor image: copy, pitched rows, source release/mutation and invalid input passed");
}
