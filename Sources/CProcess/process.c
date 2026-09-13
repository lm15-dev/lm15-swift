#include "CProcess.h"
#include <stdlib.h>
#include <stdatomic.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
#if defined(__APPLE__) && TARGET_OS_IPHONE
struct lm15_process { int unused; };
lm15_process *lm15_process_create(void) { return calloc(1,sizeof(lm15_process)); }
void lm15_process_cancel(lm15_process *p) { (void)p; }
void lm15_process_destroy(lm15_process *p) { free(p); }
int lm15_process_run(lm15_process *p,const char *e,char *const a[],char *const v[],int t,unsigned char *o,size_t c,size_t *n) { (void)p;(void)e;(void)a;(void)v;(void)t;(void)o;(void)c;*n=0;return -3; }
#else
#include <spawn.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <poll.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>
struct lm15_process { atomic_int cancelled; };
lm15_process *lm15_process_create(void) { return calloc(1,sizeof(lm15_process)); }
void lm15_process_cancel(lm15_process *p) { atomic_store(&p->cancelled,1); }
void lm15_process_destroy(lm15_process *p) { free(p); }
static long long milliseconds(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (long long)t.tv_sec*1000+t.tv_nsec/1000000; }
int lm15_process_run(lm15_process *p,const char *exe,char *const argv[],char *const envp[],int timeout_ms,unsigned char *out,size_t cap,size_t *length) {
    int stdout_pipe[2], stderr_pipe[2], rc=-1, status=0; pid_t pid=-1; *length=0;
    if (pipe(stdout_pipe)) return -1;
    if (pipe(stderr_pipe)) { close(stdout_pipe[0]);close(stdout_pipe[1]);return -1; }
    for(int i=0;i<2;i++) { fcntl(stdout_pipe[i],F_SETFD,FD_CLOEXEC);fcntl(stderr_pipe[i],F_SETFD,FD_CLOEXEC); }
    posix_spawn_file_actions_t actions; posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);posix_spawnattr_init(&attr);
    posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0);
    posix_spawn_file_actions_adddup2(&actions,stdout_pipe[1],STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions,stderr_pipe[1],STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions,stdout_pipe[0]);posix_spawn_file_actions_addclose(&actions,stderr_pipe[0]);
    posix_spawnattr_setflags(&attr,POSIX_SPAWN_SETPGROUP);posix_spawnattr_setpgroup(&attr,0);
    int spawned=posix_spawn(&pid,exe,&actions,&attr,argv,envp);
    posix_spawnattr_destroy(&attr);posix_spawn_file_actions_destroy(&actions);
    close(stdout_pipe[1]);close(stderr_pipe[1]);
    if(spawned) { close(stdout_pipe[0]);close(stderr_pipe[0]);return -1; }
    struct pollfd fds[2]={{stdout_pipe[0],POLLIN,0},{stderr_pipe[0],POLLIN,0}};
    long long deadline=milliseconds()+timeout_ms;int active=2,reaped=0;
    while(active || !reaped) {
        if(atomic_load(&p->cancelled)) { rc=-5;break; }
        if(milliseconds()>=deadline) { rc=-4;break; }
        int ready=poll(fds,2,25);
        if(ready<0 && errno!=EINTR) { rc=-1;break; }
        for(int i=0;i<2;i++) if(fds[i].fd>=0 && (fds[i].revents&(POLLIN|POLLHUP|POLLERR))) {
            unsigned char buffer[8192];ssize_t n=read(fds[i].fd,buffer,sizeof(buffer));
            if(n>0 && i==0) { if((size_t)n>cap-*length) { rc=-6;goto finish; } for(ssize_t k=0;k<n;k++) out[(*length)++]=buffer[k]; }
            else if(n==0 || (n<0 && errno!=EINTR && errno!=EAGAIN)) { close(fds[i].fd);fds[i].fd=-1;active--; }
        }
        if(!reaped) { pid_t got=waitpid(pid,&status,WNOHANG);if(got==pid) reaped=1; }
        if(!active && reaped) { rc=WIFEXITED(status)&&WEXITSTATUS(status)==0 ? 0 : -2;break; }
    }
finish:
    // Descendants retaining inherited pipes are also bounded by the same deadline.
    if(rc!=0) kill(-pid,SIGKILL);
    if(!reaped) while(waitpid(pid,&status,0)<0 && errno==EINTR) {}
    for(int i=0;i<2;i++) if(fds[i].fd>=0) close(fds[i].fd);
    return rc;
}
#endif
