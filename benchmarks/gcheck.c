#define CL_TARGET_OPENCL_VERSION 300
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
#define CK(x) do{cl_int _e=(x);if(_e!=CL_SUCCESS){printf("ERR %s = %d\n",#x,_e);}}while(0)
static const char* src =
"__kernel void wr(__global int* o){size_t i=get_global_id(0); o[i]=(int)(i*2+1);}\n";
int main(){
 cl_platform_id p; CK(clGetPlatformIDs(1,&p,NULL));
 cl_device_id d; CK(clGetDeviceIDs(p,CL_DEVICE_TYPE_GPU,1,&d,NULL));
 char nm[256]; clGetDeviceInfo(d,CL_DEVICE_NAME,sizeof nm,nm,NULL);
 printf("device: %s\n",nm); fflush(stdout);
 cl_int e; cl_context ctx=clCreateContext(NULL,1,&d,NULL,NULL,&e); CK(e);
 cl_command_queue q=clCreateCommandQueueWithProperties(ctx,d,NULL,&e); CK(e);
 cl_program pr=clCreateProgramWithSource(ctx,1,&src,NULL,&e); CK(e);
 if(clBuildProgram(pr,1,&d,"",NULL,NULL)!=CL_SUCCESS){char l[8192];clGetProgramBuildInfo(pr,d,CL_PROGRAM_BUILD_LOG,sizeof l,l,NULL);printf("build err:%s\n",l);return 2;}
 size_t G=1024;
 int *host=malloc(G*4);
 for(size_t i=0;i<G;i++) host[i]=0x7E577E57; /* poison */
 cl_mem out=clCreateBuffer(ctx,CL_MEM_READ_WRITE|CL_MEM_COPY_HOST_PTR,G*4,host,&e); CK(e);
 cl_kernel k=clCreateKernel(pr,"wr",&e); CK(e);
 CK(clSetKernelArg(k,0,sizeof(cl_mem),&out));
 printf("--- single dispatch wr, G=%zu ---\n",G); fflush(stdout);
 double t0=now();
 CK(clEnqueueNDRangeKernel(q,k,1,NULL,&G,NULL,0,NULL,NULL));
 CK(clFinish(q));
 double dt=now()-t0;
 printf("clFinish dt=%.4f ms\n",dt*1e3); fflush(stdout);
 memset(host,0,G*4);
 CK(clEnqueueReadBuffer(q,out,CL_TRUE,0,G*4,host,0,NULL,NULL));
 printf("ReadBuffer: out[0]=%d out[1]=%d out[2]=%d out[10]=%d out[1023]=%d\n",
        host[0],host[1],host[2],host[10],host[1023]);
 int ok=1,poison=0,zero=0;
 for(size_t i=0;i<G;i++){ if(host[i]==0x7E577E57)poison++; if(host[i]==0)zero++; if(host[i]!=(int)(i*2+1))ok=0; }
 printf("verify wr: %s  (poison_remaining=%d zero=%d / %zu)\n", ok?"PASS":"FAIL", poison, zero, G);
 int *m=clEnqueueMapBuffer(q,out,CL_TRUE,CL_MAP_READ,0,G*4,0,NULL,NULL,&e); CK(e);
 printf("MapBuffer:  out[0]=%d out[1]=%d out[1023]=%d\n", m[0],m[1],m[1023]);
 CK(clEnqueueUnmapMemObject(q,out,m,0,NULL,NULL)); CK(clFinish(q));
 printf("DONE\n");
 return 0;
}
