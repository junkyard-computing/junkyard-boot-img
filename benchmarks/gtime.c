#define CL_TARGET_OPENCL_VERSION 300
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
#define CK(x) do{cl_int _e=(x);if(_e!=CL_SUCCESS){printf("ERR %s = %d\n",#x,_e);}}while(0)
static const char* src =
"__kernel void busy(__global int* o,int iters){size_t i=get_global_id(0);int x=(int)i;"
"for(int k=0;k<iters;k++){x=x*1664525+1013904223;} o[i]=x;}\n";
int main(){
 cl_platform_id p; CK(clGetPlatformIDs(1,&p,NULL));
 cl_device_id d; CK(clGetDeviceIDs(p,CL_DEVICE_TYPE_GPU,1,&d,NULL));
 char nm[256]; clGetDeviceInfo(d,CL_DEVICE_NAME,sizeof nm,nm,NULL); printf("device: %s\n",nm);
 cl_int e; cl_context ctx=clCreateContext(NULL,1,&d,NULL,NULL,&e); CK(e);
 cl_command_queue q=clCreateCommandQueueWithProperties(ctx,d,NULL,&e); CK(e);
 cl_program pr=clCreateProgramWithSource(ctx,1,&src,NULL,&e); CK(e);
 if(clBuildProgram(pr,1,&d,"",NULL,NULL)!=CL_SUCCESS){char l[8192];clGetProgramBuildInfo(pr,d,CL_PROGRAM_BUILD_LOG,sizeof l,l,NULL);printf("build err:%s\n",l);return 2;}
 size_t G=4096;
 cl_mem out=clCreateBuffer(ctx,CL_MEM_WRITE_ONLY,G*4,NULL,&e); CK(e);
 cl_kernel k=clCreateKernel(pr,"busy",&e); CK(e); CK(clSetKernelArg(k,0,sizeof(cl_mem),&out));
 int iters_list[]={1,1000,100000,1000000,10000000};
 for(int j=0;j<5;j++){ int it=iters_list[j]; CK(clSetKernelArg(k,1,sizeof(int),&it));
   CK(clEnqueueNDRangeKernel(q,k,1,NULL,&G,NULL,0,NULL,NULL)); CK(clFinish(q));
   double best=1e9; for(int r=0;r<3;r++){ double t=now(); CK(clEnqueueNDRangeKernel(q,k,1,NULL,&G,NULL,0,NULL,NULL)); cl_int fe=clFinish(q); double dt=now()-t; if(fe!=CL_SUCCESS)printf("  (finish e=%d)\n",fe); if(dt<best)best=dt; }
   printf("iters=%-9d : clFinish best = %.4f ms\n", it, best*1e3);
 }
 printf("DONE (flat => shader NOT executing)\n");
 return 0;
}
