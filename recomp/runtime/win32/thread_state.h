/* Shared layout: thread objects also serve as waitable, manual-reset events. */
#ifndef W32_THREAD_STATE_H
#define W32_THREAD_STATE_H
#include "w32.h"
typedef struct Sync { pthread_mutex_t m; pthread_cond_t cv; int manual, signaled, count; uint32_t owner; char name[64]; int waiters, closed; } Sync;
typedef struct ThreadObj { Sync s; uint32_t teb, tid, exit_code, suspended; pthread_t pt; int started; } ThreadObj;
ThreadObj *w32_thread_obj(uint32_t teb);
#endif
