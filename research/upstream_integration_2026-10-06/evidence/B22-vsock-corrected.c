#include <sys/types.h>
#include <sys/socket.h>
#include <sys/vsock.h>
#include <sys/uio.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
int main(int argc,char **argv){
 if(argc!=2)return 64;int vectors=atoi(argv[1]);if(vectors<1||vectors>5)return 64;int block=vectors==3;int small=vectors==4;int snd=vectors==5;if(vectors>=3)vectors=1;size_t chunk=small?8192:65536;
 setvbuf(stdout,NULL,_IOLBF,0);signal(SIGPIPE,SIG_IGN);
 int fd=socket(AF_VSOCK,SOCK_STREAM,0);struct sockaddr_vm a={.svm_len=sizeof(a),.svm_family=AF_VSOCK,.svm_port=1339,.svm_cid=VMADDR_CID_ANY};
 if(fd<0||bind(fd,(struct sockaddr*)&a,sizeof(a))||listen(fd,16)){perror("bind");return 1;}
 printf("READY vectors=%d\n",vectors);int finished=0;
 while(finished<1){int c=accept(fd,NULL,NULL);if(c<0){perror("accept");return 1;}
  struct timeval timeout={.tv_sec=10};setsockopt(c,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
  char request[8192]={0};int n=read(c,request,sizeof(request)-1);
  if(n<1||strncmp(request,"GET /v1/files/content?",strlen("GET /v1/files/content?"))!=0){const char *h="HTTP/1.1 503 unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";write(c,h,strlen(h));close(c);continue;}
  if(snd){int size=8192;setsockopt(c,SOL_SOCKET,SO_SNDBUF,&size,sizeof(size));}if(!block)fcntl(c,F_SETFL,fcntl(c,F_GETFL)|O_NONBLOCK);
  char head[]="HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\nConnection: close\r\n\r\n";
  write(c,head,strlen(head));unsigned char data[65536];size_t offset=0;
  while(offset<1048576){size_t count=chunk;if(count>1048576-offset)count=1048576-offset;for(size_t i=0;i<sizeof(data);i++)data[i]=(offset+i)%251;
   struct pollfd p={.fd=c,.events=POLLOUT};if(poll(&p,1,5000)<1){printf("WRITE_WAIT_TIMEOUT %zu\n",offset);break;}
   struct iovec io[2]={{.iov_base=data,.iov_len=vectors==1?count:32768},{.iov_base=data+32768,.iov_len=32768}};
   ssize_t wrote=writev(c,io,vectors);printf("WRITE offset=%zu ret=%zd errno=%d\n",offset,wrote,wrote<0?errno:0);
   if(wrote<0&&(errno==EINTR||errno==EAGAIN))continue;if(wrote<=0)break;offset+=wrote;
  }
  printf("SENT total=%zu\n",offset);struct pollfd p={.fd=c,.events=POLLIN};poll(&p,1,15000);close(c);finished++;
 }
 close(fd);return 0;
}
