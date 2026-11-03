/* Loaded-version evidence, not a heartbeat: PID + kernel start time prevents
 * stale records/PID reuse from being mistaken for an active helper version. */
#include <sys/stat.h>
#include <sys/event.h>
#include <errno.h>
#include <sys/proc_info.h>
#include <libproc.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#ifndef NOKCANDU_HELPER_BUILD
#define NOKCANDU_HELPER_BUILD "development"
#endif
static int helper_server_process;
void nokcandu_record_loaded_helper(void)
{
    static pid_t recorded;
    pid_t pid = getpid();
    if (recorded == pid) return;
    recorded = pid;
    Dl_info image;
    const char suffix[] = "/SharedSupport/nokcandu/nokcandu-rawmouse.dylib";
    if (!dladdr((const void *)nokcandu_record_loaded_helper, &image) || !image.dli_fname) return;
    size_t length = strlen(image.dli_fname);
    if (length < sizeof(suffix)-1 || strcmp(image.dli_fname+length-(sizeof(suffix)-1),suffix)) return;
    char directory[PATH_MAX], target[PATH_MAX], temporary[PATH_MAX];
    if (strlcpy(directory,image.dli_fname,sizeof(directory)) >= sizeof(directory)) return;
    char *slash=strrchr(directory,'/'); if(!slash)return; *slash=0;
    if(strlcat(directory,"/loaded-helpers",sizeof(directory))>=sizeof(directory))return;
    mkdir(directory,0700); struct stat st;
    if(lstat(directory,&st)||!S_ISDIR(st.st_mode)||S_ISLNK(st.st_mode))return;
    struct proc_bsdinfo process;
    if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&process,sizeof(process))!=sizeof(process))return;
    if(snprintf(target,sizeof(target),"%s/%d.json",directory,getpid())>=(int)sizeof(target)||
       snprintf(temporary,sizeof(temporary),"%s/.%d-%llu.tmp",directory,getpid(),(unsigned long long)mach_absolute_time())>=(int)sizeof(temporary))return;
    char executable[PATH_MAX];uint32_t size=sizeof(executable);
    const char *role="program";
    if(!_NSGetExecutablePath(executable,&size)){const char *base=strrchr(executable,'/');if(base&&!strcmp(base+1,"wineserver")){role="server";helper_server_process=1;}}
    int fd=open(temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(fd<0)return;
    int result=dprintf(fd,"{\"pid\":%d,\"startSeconds\":%llu,\"startMicros\":%llu,\"build\":\"%s\",\"role\":\"%s\"}\n",getpid(),(unsigned long long)process.pbi_start_tvsec,(unsigned long long)process.pbi_start_tvusec,NOKCANDU_HELPER_BUILD,role);
    close(fd);if(result>0)rename(temporary,target);unlink(temporary);
}

__attribute__((constructor)) static void record_initial_helper(void) { nokcandu_record_loaded_helper(); }

/* Wine can daemonize after constructors, then use kqueue without poll().
 * Record on its first normal event-loop call; avoid filesystem/dyld work in
 * a fork handler. Other programs pass through without recording here. */
static int helper_kevent(int queue, const struct kevent *changes, int changeCount,
                         struct kevent *events, int eventCount, const struct timespec *timeout)
{
    int saved = errno;
    if (helper_server_process) nokcandu_record_loaded_helper();
    errno = saved;
    return kevent(queue, changes, changeCount, events, eventCount, timeout);
}
__attribute__((used)) static const struct { const void *replacement, *original; } helper_event_interpose
    __attribute__((section("__DATA,__interpose"))) = { helper_kevent, kevent };
