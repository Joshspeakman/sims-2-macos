/* Exercise the real Win32 entry points, including resume racing the wait. */
#include <assert.h>
#include <stdatomic.h>
#include "../runtime/win32/threads.c"
static uint8_t memory[4096]; uint8_t *G_MEM = memory;
int w32_deterministic;
static ThreadObj thread;
static HObj handle = {H_THREAD, 1, &thread};
static _Thread_local uint32_t last_error;
static atomic_int returned;
HObj *h_get(uint32_t h, int type) { return h == 0x104 && type == H_THREAD ? &handle : NULL; }
ThreadObj *w32_thread_obj(uint32_t teb) { return teb == thread.teb ? &thread : NULL; }
void w32_set_last_error(Ctx *c, uint32_t e) { (void)c; last_error = e; }
static uint32_t call(void (*fn)(Ctx *), uint32_t teb, uint32_t h, uint32_t sp)
{
    Ctx c = {.esp = sp, .fs_base = teb}; rt_w32(G_MEM, sp + 4, h); fn(&c);
    assert(c.esp == sp + 8); return c.eax;
}
static void *worker(void *unused)
{
    (void)unused;
    assert(call(imp_kernel32_SuspendThread, thread.teb, 0xfffffffeu, 256) == 0);
    atomic_store(&returned, 1); return NULL;
}
int main(void)
{
    alarm(15);
    pthread_mutex_init(&thread.s.m, NULL); pthread_cond_init(&thread.s.cv, NULL);
    thread.teb = 123; thread.started = 1;
    assert(call(imp_kernel32_SuspendThread, 456, 99, 512) == UINT32_MAX && last_error == 6);
    assert(call(imp_kernel32_ResumeThread, 456, 99, 512) == UINT32_MAX && last_error == 6);
    assert(call(imp_kernel32_SuspendThread, 456, 0x104, 512) == UINT32_MAX && last_error == 50);
    assert(call(imp_kernel32_ResumeThread, 456, 0x104, 512) == 0);
    for (int i = 0; i < 200; i++) {
        atomic_store(&returned, 0); pthread_t pt; assert(!pthread_create(&pt, NULL, worker, NULL));
        for (;;) { pthread_mutex_lock(&thread.s.m); int parked = thread.suspended != 0; pthread_mutex_unlock(&thread.s.m); if (parked) break; sched_yield(); }
        assert(!atomic_load(&returned));
        assert(call(imp_kernel32_SuspendThread, 456, 0x104, 512) == 1);
        assert(call(imp_kernel32_ResumeThread, 456, 0x104, 512) == 2);
        assert(!atomic_load(&returned));
        assert(call(imp_kernel32_ResumeThread, 456, 0x104, 512) == 1);
        assert(!pthread_join(pt, NULL)); assert(atomic_load(&returned));
    }
    thread.suspended = 127;
    assert(call(imp_kernel32_SuspendThread, 456, 0x104, 512) == UINT32_MAX && last_error == 156);
    thread.suspended = 0; thread.started = 0;
    assert(call(imp_kernel32_SuspendThread, 456, 0x104, 512) == 0);
    assert(call(imp_kernel32_ResumeThread, 456, 0x104, 512) == 1);
    puts("Thread suspension: self/pseudo handle, nesting, wake races and errors passed");
}
