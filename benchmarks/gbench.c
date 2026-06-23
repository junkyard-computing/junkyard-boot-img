#define CL_TARGET_OPENCL_VERSION 300
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
static const char* src =
"__kernel void flops(__global float* out,float a,int iters){\n"
" size_t i=get_global_id(0);\n"
" float x0=a+0.1f*i,x1=a+0.2f*i,x2=a+0.3f*i,x3=a+0.4f*i,x4=a+0.5f*i,x5=a+0.6f*i,x6=a+0.7f*i,x7=a+0.8f*i;\n"
" float b=0.9999f,c=1.0001f;\n"
" for(int k=0;k<iters;k++){x0=fma(x0,b,c);x1=fma(x1,b,c);x2=fma(x2,b,c);x3=fma(x3,b,c);x4=fma(x4,b,c);x5=fma(x5,b,c);x6=fma(x6,b,c);x7=fma(x7,b,c);}\n"
" out[i]=x0+x1+x2+x3+x4+x5+x6+x7;}\n"
"__kernel void triad(__global float* c,__global const float* a,__global const float* b,float s){size_t i=get_global_id(0);c[i]=a[i]+s*b[i];}\n";
int main(){
 cl_platform_id p;clGetPlatformIDs(1,&p,NULL);
 cl_device_id d;clGetDeviceIDs(p,CL_DEVICE_TYPE_GPU,1,&d,NULL);
 char nm[256];clGetDeviceInfo(d,CL_DEVICE_NAME,sizeof nm,nm,NULL);
 cl_uint cu,mhz;clGetDeviceInfo(d,CL_DEVICE_MAX_COMPUTE_UNITS,sizeof cu,&cu,NULL);clGetDeviceInfo(d,CL_DEVICE_MAX_CLOCK_FREQUENCY,sizeof mhz,&mhz,NULL);
 cl_int e;cl_context ctx=clCreateContext(NULL,1,&d,NULL,NULL,&e);
 cl_command_queue q=clCreateCommandQueueWithProperties(ctx,d,NULL,&e);
 cl_program pr=clCreateProgramWithSource(ctx,1,&src,NULL,&e);
 if(clBuildProgram(pr,1,&d,"",NULL,NULL)!=CL_SUCCESS){char l[8192];clGetProgramBuildInfo(pr,d,CL_PROGRAM_BUILD_LOG,sizeof l,l,NULL);printf("build err:%s\n",l);return 2;}
 printf("device: %s  CUs=%u  reportedCLK=%u MHz\n",nm,cu,mhz);
 {size_t G=1<<20;int iters=4096;cl_mem out=clCreateBuffer(ctx,CL_MEM_WRITE_ONLY,G*4,NULL,&e);
  cl_kernel k=clCreateKernel(pr,"flops",&e);float a=1.0f;clSetKernelArg(k,0,sizeof(cl_mem),&out);clSetKernelArg(k,1,sizeof(float),&a);clSetKernelArg(k,2,sizeof(int),&iters);
  clEnqueueNDRangeKernel(q,k,1,NULL,&G,NULL,0,NULL,NULL);clFinish(q);
  double best=1e9;for(int r=0;r<5;r++){double t0=now();clEnqueueNDRangeKernel(q,k,1,NULL,&G,NULL,0,NULL,NULL);clFinish(q);double dt=now()-t0;if(dt<best)best=dt;}
  printf("FP32 compute : %.1f GFLOPS  (best %.4f s / 5)\n",(double)G*iters*16.0/best/1e9,best);}
 {size_t N=1<<24;size_t bytes=N*4;float *ha=malloc(bytes),*hb=malloc(bytes);for(size_t i=0;i<N;i++){ha[i]=i*1e-3f;hb[i]=i*2e-3f;}
  cl_mem A=clCreateBuffer(ctx,CL_MEM_READ_ONLY|CL_MEM_COPY_HOST_PTR,bytes,ha,&e),B=clCreateBuffer(ctx,CL_MEM_READ_ONLY|CL_MEM_COPY_HOST_PTR,bytes,hb,&e),C=clCreateBuffer(ctx,CL_MEM_WRITE_ONLY,bytes,NULL,&e);
  cl_kernel k=clCreateKernel(pr,"triad",&e);float s=3.0f;clSetKernelArg(k,0,sizeof(cl_mem),&C);clSetKernelArg(k,1,sizeof(cl_mem),&A);clSetKernelArg(k,2,sizeof(cl_mem),&B);clSetKernelArg(k,3,sizeof(float),&s);
  clEnqueueNDRangeKernel(q,k,1,NULL,&N,NULL,0,NULL,NULL);clFinish(q);
  double best=1e9;for(int r=0;r<10;r++){double t0=now();clEnqueueNDRangeKernel(q,k,1,NULL,&N,NULL,0,NULL,NULL);clFinish(q);double dt=now()-t0;if(dt<best)best=dt;}
  printf("Mem triad BW : %.1f GB/s  (best %.4f s / 10)\n",(double)bytes*3.0/best/1e9,best);}
 return 0;}
