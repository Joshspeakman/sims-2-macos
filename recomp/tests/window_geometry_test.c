/* Real USER32 calls: maximized geometry, client messages, restore and cursor edges. */
#include <assert.h>
#include <stdarg.h>
#include "../runtime/win32/user32.c"
static uint8_t memory[8192]; uint8_t *G_MEM = memory;
static uint32_t size_kind, size_value, last_error;
uint32_t w32_tid(Ctx *c) { (void)c; return 1; }
void w32_set_last_error(Ctx *c, uint32_t error) { (void)c; last_error = error; }
uint32_t w32_callback(Ctx *c, uint32_t fn, int n, const uint32_t *a)
{
    (void)c; (void)fn; assert(n == 4);
    if (a[1] == WM_SIZE) { size_kind = a[2]; size_value = a[3]; }
    return a[1] == WM_NCCREATE ? 1 : 0;
}
static uint32_t call(void (*fn)(Ctx *), int count, ...)
{
    Ctx c = {.esp = 4096}; va_list args; va_start(args, count);
    for (int i=0;i<count;i++) rt_w32(G_MEM, c.esp+4*(i+1), va_arg(args,uint32_t));
    va_end(args); fn(&c); assert(c.esp == 4096+4*(count+1)); return c.eax;
}
static void client_is(uint32_t hwnd, unsigned width, unsigned height, unsigned kind)
{
    assert(call(imp_user32_GetClientRect,2,hwnd,128u));
    assert(rt_r32(G_MEM,136) == width && rt_r32(G_MEM,140) == height);
    assert(size_value == ((height << 16) | width) && size_kind == kind);
    uint32_t w,h; assert(w32_client_size(hwnd,&w,&h) && w == width && h == height);
}
int main(void)
{
    classes[0] = (WClass){.atom=0xc000,.wndproc=1}; nclasses=1;
    w32_screen_w=1728; w32_screen_h=1116;
    uint32_t hwnd=call(imp_user32_CreateWindowExA,12,0u,0xc000u,0u,0x10cf0000u,100u,200u,648u,507u,0u,0u,0u,0u);
    assert(hwnd); client_is(hwnd,640,480,0);
    call(imp_user32_MoveWindow,6,hwnd,80u,120u,808u,627u,1u); client_is(hwnd,800,600,0);
    call(imp_user32_ShowWindow,2,hwnd,3u); client_is(hwnd,1728,1097,2);
    assert(call(imp_user32_IsZoomed,1,hwnd));
    call(imp_user32_ShowWindow,2,hwnd,3u); /* repeated maximize must preserve restored bounds */
    rt_w32(G_MEM,128,44); assert(call(imp_user32_GetWindowPlacement,2,hwnd,128u));
    assert(rt_r32(G_MEM,136)==3 && rt_r32(G_MEM,156)==80 && rt_r32(G_MEM,160)==120);
    assert(rt_r32(G_MEM,164)==888 && rt_r32(G_MEM,168)==747);
    call(imp_user32_ShowWindow,2,hwnd,6u); assert(size_kind==1 && size_value==0);
    call(imp_user32_ShowWindow,2,hwnd,9u); client_is(hwnd,1728,1097,2);
    call(imp_user32_ShowWindow,2,hwnd,1u); client_is(hwnd,800,600,0);
    assert(!call(imp_user32_IsZoomed,1,hwnd));
    assert(W(hwnd)->x==80 && W(hwnd)->y==120);

    /* Sims 2's startup: decorated bounds followed by a borderless maximized window. */
    call(imp_user32_SetWindowLongA,3,hwnd,(uint32_t)-16,0x100a0000u);
    call(imp_user32_MoveWindow,6,hwnd,(uint32_t)-3,0u,1734u,1119u,1u);
    call(imp_user32_ShowWindow,2,hwnd,3u); client_is(hwnd,1728,1116,2);
    assert(W(hwnd)->x==0 && W(hwnd)->y==0 && W(hwnd)->w==1728 && W(hwnd)->h==1116);
    int x,y; w32_set_cursor(864,558); w32_move_cursor(9000,9000,1728,1116,&x,&y);
    assert(x==1727 && y==1115); call(imp_user32_GetCursorPos,1,256u);
    assert(rt_r32(G_MEM,256)==1727 && rt_r32(G_MEM,260)==1115);
    call(imp_user32_ScreenToClient,2,hwnd,256u);
    assert(rt_r32(G_MEM,256)==1727 && rt_r32(G_MEM,260)==1115);
    w32_move_cursor(-9000,-9000,1728,1116,&x,&y); assert(x==0 && y==0);
    call(imp_user32_ShowWindow,2,hwnd,1u);
    assert(W(hwnd)->x==-3 && W(hwnd)->w==1734 && W(hwnd)->h==1119);

    uint32_t rect[]={0,0,640,480}; memcpy(memory+128,rect,sizeof rect);
    call(imp_user32_AdjustWindowRectEx,4,128u,0x00800000u,0u,0u); /* WS_BORDER is not WS_CAPTION */
    assert((int32_t)rt_r32(G_MEM,128)==-1 && (int32_t)rt_r32(G_MEM,132)==-1);
    assert(rt_r32(G_MEM,136)==641 && rt_r32(G_MEM,140)==481);
    rt_w32(G_MEM,128,0); assert(!call(imp_user32_GetWindowPlacement,2,hwnd,128u) && last_error==87);
    puts("Window geometry: client sizes, maximize/restore, borderless fullscreen and all cursor edges passed");
}
