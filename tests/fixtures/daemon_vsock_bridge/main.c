#include <arpa/inet.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include "../../../sources/VPhoneDaemon/Native/vphoned_vsock.c"
static int hold_open = 0;
static void *respond(void *arg) {
    int *fds=arg;char input[16384];size_t received=0;ssize_t n;
    while((n=read(fds[0],input,sizeof(input)))>0){received+=(size_t)n;if(hold_open && received==251*37)break;}
    if(received!=251*37)_exit(71);
    unsigned char output[251];for(int i=0;i<251;i++)output[i]=(unsigned char)i;
    for(int i=0;i<8356;i++){
        size_t offset=0;
        while(offset<sizeof(output)){
            n=write(fds[1],output+offset,sizeof(output)-offset);
            if(n<=0)goto done;
            offset+=(size_t)n;
        }
    }
done:close(fds[0]);close(fds[1]);free(fds);return NULL;
}
static int attach(int input,int output) {
    int *fds=malloc(sizeof(int)*2);if(!fds){close(input);close(output);return -1;}
    fds[0]=input;fds[1]=output;pthread_t thread;
    if(pthread_create(&thread,NULL,respond,fds)){close(input);close(output);free(fds);return -1;}
    pthread_detach(thread);return 0;
}
int main(int argc,char **argv){
    hold_open=argc>1 && strcmp(argv[1],"hold-open")==0;
    signal(SIGPIPE,SIG_DFL);setvbuf(stdout,NULL,_IOLBF,0);
    int listener=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in a={.sin_len=sizeof(a),.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if(bind(listener,(void*)&a,sizeof(a))||listen(listener,1))return 65;
    socklen_t size=sizeof(a);if(getsockname(listener,(void*)&a,&size))return 66;
    printf("%d\n",ntohs(a.sin_port));int fd=accept(listener,NULL,NULL);close(listener);
    if(vp_vsock_bridge(fd,attach))return 67;
    for(int i=0;i<70&&atomic_load(&active_connections);i++)usleep(100000);
    printf("active=%d\n",atomic_load(&active_connections));return atomic_load(&active_connections)?68:0;
}
