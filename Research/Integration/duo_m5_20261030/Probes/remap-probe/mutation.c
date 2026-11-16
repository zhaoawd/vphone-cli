// Controlled code changes affect only this generated research process.
#include <mach/mach.h>
#include <libkern/OSCacheControl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
extern int mutation_marker(void), mutation_replacement(void);
extern const unsigned char mutation_hook_template[];
volatile int debug_value = 41;
static int call(uintptr_t address) { int (*volatile f)(void)=(void *)address; return f(); }
int main(int argc, char **argv) {
    if (argc != 2 && argc != 3) return 2;
    int inlineOnly=argc==3&&strcmp(argv[2],"--inline-only")==0;
    int debugWait=argc==3&&strcmp(argv[2],"--wait-for-debugger")==0;
    if(debugWait){
        FILE *f=fopen(argv[1],"w");if(!f)return 3;
        fprintf(f,"{\"pid\":%d,\"waiting\":true,\"debugValue\":41,\"debugAddress\":\"0x%llx\"}\n",getpid(),(unsigned long long)(uintptr_t)&debug_value);fclose(f);
        for(int i=0;i<600&&debug_value!=73;i++)usleep(100000);
        if(debug_value!=73)return 5;
    }
    vm_address_t source=(uintptr_t)mutation_marker & ~((uintptr_t)vm_page_size-1),alias=0;
    vm_size_t size=vm_page_size;
    vm_prot_t current=0,maximum=0;
    kern_return_t remap=vm_remap(mach_task_self(),&alias,size,0,VM_FLAGS_ANYWHERE,
        mach_task_self(),source,TRUE,&current,&maximum,VM_INHERIT_NONE);
    int original=call((uintptr_t)mutation_marker),privateAnswer=-1,hookAnswer=-1,restored=-1,sourceRemapAnswer=-1;
    kern_return_t sourceRemap=-1;
    kern_return_t writable=-1,executable=-1,hookWritable=-1,hookExecutable=-1;
    uintptr_t offset=(uintptr_t)mutation_marker-source;
    if(remap==KERN_SUCCESS){
        writable=vm_protect(mach_task_self(),alias,size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
        if(writable==KERN_SUCCESS){
            memcpy((void *)(alias+offset),(void *)mutation_replacement,8);
            sys_icache_invalidate((void *)alias,size);
            executable=vm_protect(mach_task_self(),alias,size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE);
            if(executable==KERN_SUCCESS)privateAnswer=call(alias+offset);
        }
        vm_deallocate(mach_task_self(),alias,size);
    }
    unsigned char before[16],hook[16];
    memcpy(before,(void *)mutation_marker,sizeof before);
    memcpy(hook,mutation_hook_template,sizeof hook);
    uintptr_t replacement=(uintptr_t)mutation_replacement;
    memcpy(hook+8,&replacement,sizeof replacement);
    hookWritable=vm_protect(mach_task_self(),source,size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY);
    if(hookWritable==KERN_SUCCESS){
        memcpy((void *)mutation_marker,hook,sizeof hook);
        sys_icache_invalidate((void *)source,size);
        hookExecutable=vm_protect(mach_task_self(),source,size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE);
        if(hookExecutable==KERN_SUCCESS)hookAnswer=call((uintptr_t)mutation_marker);
        if(hookExecutable==KERN_SUCCESS){
            alias=0;
            sourceRemap=vm_remap(mach_task_self(),&alias,size,0,VM_FLAGS_ANYWHERE,
                mach_task_self(),source,TRUE,&current,&maximum,VM_INHERIT_NONE);
            if(sourceRemap==KERN_SUCCESS){
                // A successful remap may return a mapping without execute permission.
                if(!inlineOnly&&!debugWait&&(current&VM_PROT_EXECUTE))sourceRemapAnswer=call(alias+offset);
                vm_deallocate(mach_task_self(),alias,size);
            }
        }
        if(vm_protect(mach_task_self(),source,size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY)==KERN_SUCCESS){
            memcpy((void *)mutation_marker,before,sizeof before);
            sys_icache_invalidate((void *)source,size);
            if(vm_protect(mach_task_self(),source,size,FALSE,VM_PROT_READ|VM_PROT_EXECUTE)==KERN_SUCCESS)
                restored=call((uintptr_t)mutation_marker);
        }
    }
    for(int i=0;i<1200;i++){
        FILE *f=fopen(argv[1],"w");if(!f)return 3;
        fprintf(f,"{\"pid\":%d,\"remap\":%d,\"writable\":%d,\"executable\":%d,\"original\":%d,\"privateAnswer\":%d,\"hookWritable\":%d,\"hookExecutable\":%d,\"hookAnswer\":%d,\"sourceRemap\":%d,\"sourceRemapAnswer\":%d,\"restored\":%d,\"debugValue\":%d,\"debugAddress\":\"0x%llx\"}\n",
            getpid(),remap,writable,executable,original,privateAnswer,hookWritable,hookExecutable,hookAnswer,sourceRemap,sourceRemapAnswer,restored,debug_value,(unsigned long long)(uintptr_t)&debug_value);
        fclose(f);usleep(100000);
    }
    return original==42&&(inlineOnly||privateAnswer==91)&&hookAnswer==91&&restored==42?0:4;
}
