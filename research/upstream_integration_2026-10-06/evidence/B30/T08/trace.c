#include <xpc/xpc.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <time.h>
extern int _xpc_pipe_interface_routine(xpc_object_t,uint64_t,xpc_object_t,xpc_object_t *,uint64_t);
extern const char *xpc_strerror(int);
static int traced(xpc_object_t pipe,uint64_t routine,xpc_object_t message,xpc_object_t *reply,uint64_t flags) {
 int status=_xpc_pipe_interface_routine(pipe,routine,message,reply,flags);
 if (getenv("VPHONE_B30_TRACE")) {
  const char *label=xpc_dictionary_get_string(message,"name");
  int hasReply=reply && *reply;
  int code=hasReply?(int)xpc_dictionary_get_int64(*reply,"error"):0;
  fprintf(stderr,"B30_XPC pid=%d uid=%d euid=%d routine=%llu domain=%llu handle=%llu label=%s transport=%d reply_present=%d reply_error=%d final=%d message=%s\n",getpid(),getuid(),geteuid(),(unsigned long long)routine,(unsigned long long)xpc_dictionary_get_uint64(message,"type"),(unsigned long long)xpc_dictionary_get_uint64(message,"handle"),label?label:"<none>",status,hasReply,code,status?status:code,xpc_strerror(status?status:code));
  fflush(stderr);
 }
 return status;
}
__attribute__((used,section("__DATA,__interpose")))
static struct {const void *replacement;const void *replacee;} hook={(const void *)traced,(const void *)_xpc_pipe_interface_routine};
__attribute__((constructor)) static void loaded(void){if(getenv("VPHONE_B30_TRACE"))fprintf(stderr,"B30_TRACE_LOADED pid=%d uid=%d euid=%d\n",getpid(),getuid(),geteuid());}
