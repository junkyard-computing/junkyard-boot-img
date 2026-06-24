#define CL_TARGET_OPENCL_VERSION 300
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
static const char* src=
"__kernel void flops(__global float* out,float a,int iters){size_t i=get_global_id(0);"
"float x0=a+0.1f*i,x1=a+0.2f*i,x2=a+0.3f*i,x3=a+0.4f*i,x4=a+0.5f*i,x5=a+0.6f*i,x6=a+0.7f*i,x7=a+0.8f*i;"
"float b=0.9999f,c=1.0001f;"
"for(int k=0;k<iters;k++){x0=fma(x0,b,c);x1=fma(x1,b,c);x2=fma(x2,b,c);x3=fma(x3,b,c);x4=fma(x4,b,c);x5=fma(x5,b,c);x6=fma(x6,b,c);x7=fma(x7,b,c);}"
"out[i]=x0+x1+x2+x3+x4+x5+x6+x7;}";
int main(int argc,char**argv){
 double secs = argc>1?atof(argv[1]):12.0;
 cl_platform_id p;clGetPlatformIDs(1,&p,0);cl_device_id d;clGetDeviceIDs(p,CL_DEVICE_TYPE_GPU,1,&d,0);
 cl_int e;cl_context ctx=clCreateContext(0,1,&d,0,0,&e);cl_command_queue q=clCreateCommandQueueWithProperties(ctx,d,0,&e);
 cl_program pr=clCreateProgramWithSource(ctx,1,&src,0,&e);
 if(clBuildProgram(pr,1,&d,"",0,0)!=CL_SUCCESS){printf("build fail\n");return 2;}
 size_t G=1<<20;int iters=4096;float a=1.0f;
 cl_mem o=clCreateBuffer(ctx,CL_MEM_WRITE_ONLY,G*4,0,&e);
 cl_kernel k=clCreateKernel(pr,"flops",&e);clSetKernelArg(k,0,sizeof(cl_mem),&o);clSetKernelArg(k,1,sizeof(float),&a);clSetKernelArg(k,2,sizeof(int),&iters);
 clEnqueueNDRangeKernel(q,k,1,0,&G,0,0,0,0);clFinish(q); /* warm */
 double t0=now(),flops=0; long n=0;
 fprintf(stderr,"SUSTAIN_START\n"); fflush(stderr);
 while(now()-t0 < secs){ clEnqueueNDRangeKernel(q,k,1,0,&G,0,0,0,0); clFinish(q); flops += (double)G*iters*16.0; n++; }
 double dt=now()-t0;
 fprintf(stderr,"SUSTAIN_END\n"); fflush(stderr);
 printf("sustained FP32: %.1f GFLOPS over %.2fs (%ld dispatches)\n", flops/dt/1e9, dt, n);
 return 0;}
