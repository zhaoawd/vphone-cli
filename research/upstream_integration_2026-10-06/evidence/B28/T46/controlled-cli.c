#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc,char **argv){if(argc>2&&!strcmp(argv[1],"vm")&&!strcmp(argv[2],"list")){puts("[]");return 0;}if(argc>1&&!strcmp(argv[1],"doctor")){char *a[]={"/usr/bin/python3","-u","/private/tmp/vphone-b28-t46-ui/run.py",NULL};execv(a[0],a);return 90;}fputs("B28 controlled CLI: unsupported command\n",stderr);return 2;}
