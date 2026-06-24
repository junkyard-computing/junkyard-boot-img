#define CL_TARGET_OPENCL_VERSION 300
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define CK(x) do{cl_int _e=(x);if(_e!=CL_SUCCESS){printf("ERR %s = %d\n",#x,_e);}}while(0)
static const char* src="__kernel void wr(__global int* o){size_t i=get_global_id(0); o[i]=(int)(i*2+1);}\n";
static void verify(const char* tag,int* h,size_t G){int ok=1,pois=0,zero=0;for(size_t i=0;i<G;i++){if(h[i]==0x7E577E57)pois++;if(h[i]==0)zero++;if(h[i]!=(int)(i*2+1))ok=0;}printf("%-22s %s  out[0]=%d out[1]=%d out[1023]=%d  poison=%d zero=%d\n",tag,ok?"PASS":"FAIL",h[0],h[1],h[1023],pois,zero);}
int main(){
 cl_platform_id p;CK(clGetPlatformIDs(1,&p,NULL));cl_device_id d;CK(clGetDeviceIDs(p,CL_DEVICE_TYPE_GPU,1,&d,NULL));
 cl_int e;cl_context ctx=clCreateContext(NULL,1,&d,NULL,NULL,&e);CK(e);
 cl_command_queue q=clCreateCommandQueueWithProperties(ctx,d,NULL,&e);CK(e);
 cl_program pr=clCreateProgramWithSource(ctx,1,&src,NULL,&e);CK(e);
 if(clBuildProgram(pr,1,&d,"",NULL,NULL)!=CL_SUCCESS){printf("build fail\n");return 2;}
 size_t G=1024;int* host=malloc(G*4);cl_kernel k=clCreateKernel(pr,"wr",&e);
 /* TEST A: fresh buffer, never CPU-poisoned, immediate read */
 {cl_mem o=clCreateBuffer(ctx,CL_MEM_READ_WRITE,G*4,NULL,&e);CK(clSetKernelArg(k,0,sizeof(cl_mem),&o));
  CK(clEnqueueNDRangeKernel(q,k,1,NULL,&G,NULL,0,NULL,NULL));CK(clFinish(q));
  memset(host,0,G*4);CK(clEnqueueReadBuffer(q,o,CL_TRUE,0,G*4,host,0,NULL,NULL));verify("A fresh immediate:",host,G);clReleaseMemObject(o);}
 /* TEST B: poisoned buffer, immediate read */
 {for(size_t i=0;i<G;i++)host[i]=0x7E577E57;cl_mem o=clCreateBuffer(ctx,CL_MEM_READ_WRITE|CL_MEM_COPY_HOST_PTR,G*4,host,&e);CK(clSetKernelArg(k,0,sizeof(cl_mem),&o));
  CK(clEnqueueNDRangeKernel(q,k,1,NULL,&G,NULL,0,NULL,NULL));CK(clFinish(q));
  memset(host,0,G*4);CK(clEnqueueReadBuffer(q,o,CL_TRUE,0,G*4,host,0,NULL,NULL));verify("B poison immediate:",host,G);clReleaseMemObject(o);}
 /* TEST C: poisoned buffer, SLEEP 600ms (GPU autosuspend flushes L2) before read */
 {for(size_t i=0;i<G;i++)host[i]=0x7E577E57;cl_mem o=clCreateBuffer(ctx,CL_MEM_READ_WRITE|CL_MEM_COPY_HOST_PTR,G*4,host,&e);CK(clSetKernelArg(k,0,sizeof(cl_mem),&o));
  CK(clEnqueueNDRangeKernel(q,k,1,NULL,&G,NULL,0,NULL,NULL));CK(clFinish(q));usleep(600000);
  memset(host,0,G*4);CK(clEnqueueReadBuffer(q,o,CL_TRUE,0,G*4,host,0,NULL,NULL));verify("C poison +600ms sleep:",host,G);clReleaseMemObject(o);}
 printf("DONE\n");return 0;}
