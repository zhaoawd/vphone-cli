#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
extern int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int main(int argc,char **argv) {
    if(argc!=2)return 64;
    int pid=atoi(argv[1]);
    // PROC_PIDLISTFDS=1; proc_fdinfo contains uint32_t proc_fd and proc_fdtype.
    int bytes=proc_pidinfo(pid,1,0,NULL,0);
    if(bytes<=0){fprintf(stderr,"proc_pidinfo size=%d errno=%d uid=%d\n",bytes,errno,getuid());return 1;}
    void *data=malloc(bytes+4096);
    if(!data)return 2;
    int actual=proc_pidinfo(pid,1,0,data,bytes+4096);
    free(data);
    if(actual<=0||actual%8){fprintf(stderr,"proc_pidinfo actual=%d errno=%d\n",actual,errno);return 3;}
    printf("{\"pid\":%d,\"fds\":%d,\"at\":%lld}\n",pid,actual/8,(long long)time(NULL));
    return 0;
}
