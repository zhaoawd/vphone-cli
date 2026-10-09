#include <stdio.h>
#include <signal.h>
#include <pthread.h>
#include <unistd.h>
int main(void){sigset_t m;int rc=pthread_sigmask(SIG_SETMASK,NULL,&m);printf("mask_rc=%d TERM=%d INT=%d HUP=%d QUIT=%d\n",rc,sigismember(&m,SIGTERM),sigismember(&m,SIGINT),sigismember(&m,SIGHUP),sigismember(&m,SIGQUIT));return 0;}
