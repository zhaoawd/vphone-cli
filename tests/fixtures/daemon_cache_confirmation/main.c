#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static const char *fixture_executable;
static int fixture_executable_path(char *out,uint32_t *size);
#define _NSGetExecutablePath fixture_executable_path
#include "../../../sources/VPhoneDaemon/Native/vphoned_native.m"
#undef _NSGetExecutablePath
static int fixture_executable_path(char *out,uint32_t *size){
 size_t n=strlen(fixture_executable)+1;if(n>*size){*size=(uint32_t)n;return -1;}memcpy(out,fixture_executable,n);return 0;
}
int main(int argc,char **argv){
 if(argc==2 && strcmp(argv[1],"--cache")==0){puts(vp_native_api_cache_path());return 0;}
 if(argc!=5)return 64;cache=argv[1];pending=argv[2];marker=argv[3];fixture_executable=argv[4];
 vp_native_confirm_cached_binary();return access(marker,F_OK)==0?0:1;
}
