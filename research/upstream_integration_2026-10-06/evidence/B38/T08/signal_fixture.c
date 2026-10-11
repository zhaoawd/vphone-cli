#include <signal.h>
#include <stdio.h>
#include <unistd.h>
int main(void) {
    sigset_t mask; struct sigaction action;
    if(sigprocmask(SIG_SETMASK,NULL,&mask)||sigaction(SIGTERM,NULL,&action))return 1;
    printf("{\"pid\":%d,\"term_blocked_before\":%d,\"term_ignored_before\":%d}\n",getpid(),sigismember(&mask,SIGTERM),action.sa_handler==SIG_IGN);
    fflush(stdout);
    sigdelset(&mask,SIGTERM);
    if(sigprocmask(SIG_SETMASK,&mask,NULL)||signal(SIGTERM,SIG_DFL)==SIG_ERR)return 2;
    sleep(60);return 0;
}
