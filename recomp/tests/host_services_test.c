#include <assert.h>
#include "../runtime/platform.h"
#include "../host/log_rotation.h"
int main(void)
{
    char dir[] = "/tmp/sims2-host-test-XXXXXX"; assert(mkdtemp(dir));
    char path[512], old[528]; snprintf(path,sizeof path,"%s/runtime.log",dir); snprintf(old,sizeof old,"%s.previous",path);
    FILE *f=fopen(path,"a+"); assert(f);
    for (int i=0;i<2000;i++) fputc('x',f); fflush(f);
    assert(ds_rotate_log(f,path,1024)==1); fputs("new log\n",f); fflush(f);
    struct stat st; assert(!stat(old,&st) && st.st_size==2000); assert(!stat(path,&st) && st.st_size==8);
    assert(ds_rotate_log(f,path,1024)==0);
    assert(ds_rotate_log(f,old,1)==0); // A stale DS_LOG_FILE must not rotate someone else's file.
    fclose(f); unlink(path); unlink(old); rmdir(dir);
    uint64_t start=ds_clock_ns(); clock_t cpu=clock();
    for(int i=0;i<30;i++) { uint64_t deadline=ds_clock_ns()+1000000; ds_sleep_until_ns(deadline); assert(ds_clock_ns()>=deadline); }
    double elapsed=(ds_clock_ns()-start)/1e9, used=(double)(clock()-cpu)/CLOCKS_PER_SEC;
    assert(used < elapsed * .4 + .001);
    printf("Log rotation and monotonic sleeping: %.1f ms wall, %.1f ms CPU\n",elapsed*1000,used*1000);
}
