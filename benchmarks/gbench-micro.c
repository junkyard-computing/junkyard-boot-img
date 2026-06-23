#define CL_TARGET_OPENCL_VERSION 300
#include <CL/cl.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
static double now(){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec*1e-9;}
static cl_device_id D; static cl_context C; static cl_command_queue Q;
static cl_kernel build(const char*src,const char*name){
 cl_int e; cl_program p=clCreateProgramWithSource(C,1,&src,NULL,&e);
 if(clBuildProgram(p,1,&D,"",NULL,NULL)!=CL_SUCCESS){return NULL;}
 return clCreateKernel(p,name,&e);
}
static double bestrun(cl_kernel k,size_t G,int reps){double best=1e9;for(int r=0;r<reps;r++){double t=now();clEnqueueNDRangeKernel(Q,k,1,NULL,&G,NULL,0,NULL,NULL);clFinish(Q);double dt=now()-t;if(dt<best)best=dt;}return best;}
int main(){
 cl_platform_id p;clGetPlatformIDs(1,&p,NULL);clGetDeviceIDs(p,CL_DEVICE_TYPE_GPU,1,&D,NULL);
 cl_int e;C=clCreateContext(NULL,1,&D,NULL,NULL,&e);Q=clCreateCommandQueueWithProperties(C,D,NULL,&e);
 size_t G=1<<20;int it=4096;cl_mem out=clCreateBuffer(C,CL_MEM_WRITE_ONLY,G*8,NULL,&e);
 // FP16
 {cl_kernel k=build("#pragma OPENCL EXTENSION cl_khr_fp16: enable\n__kernel void f(__global half* o,int it){size_t i=get_global_id(0);half x0=i*(half)1e-4,x1=x0+1,x2=x0+2,x3=x0+3,x4=x0+4,x5=x0+5,x6=x0+6,x7=x0+7,b=(half)0.9999,c=(half)1.0001;for(int k=0;k<it;k++){x0=fma(x0,b,c);x1=fma(x1,b,c);x2=fma(x2,b,c);x3=fma(x3,b,c);x4=fma(x4,b,c);x5=fma(x5,b,c);x6=fma(x6,b,c);x7=fma(x7,b,c);}o[i]=x0+x1+x2+x3+x4+x5+x6+x7;}","f");
  if(k){clSetKernelArg(k,0,sizeof(cl_mem),&out);clSetKernelArg(k,1,sizeof(int),&it);bestrun(k,G,2);double t=bestrun(k,G,5);printf("FP16 compute : %.1f GFLOPS\n",(double)G*it*16/t/1e9);}else printf("FP16 compute : SKIPPED (build failed)\n");}
 // INT32
 {cl_kernel k=build("__kernel void f(__global int* o,int it){size_t i=get_global_id(0);int x0=i,x1=i+1,x2=i+2,x3=i+3,x4=i+4,x5=i+5,x6=i+6,x7=i+7,b=1664525,c=1013904223;for(int k=0;k<it;k++){x0=x0*b+c;x1=x1*b+c;x2=x2*b+c;x3=x3*b+c;x4=x4*b+c;x5=x5*b+c;x6=x6*b+c;x7=x7*b+c;}o[i]=x0^x1^x2^x3^x4^x5^x6^x7;}","f");
  if(k){clSetKernelArg(k,0,sizeof(cl_mem),&out);clSetKernelArg(k,1,sizeof(int),&it);bestrun(k,G,2);double t=bestrun(k,G,5);printf("INT32 mad    : %.1f GIOPS\n",(double)G*it*16/t/1e9);}else printf("INT32 mad    : SKIPPED\n");}
 // INT8 dot (cl_arm)
 {cl_kernel k=build("#pragma OPENCL EXTENSION cl_arm_integer_dot_product_int8: enable\n__kernel void f(__global int* o,int it){size_t i=get_global_id(0);char4 a=(char4)(1,2,3,4),b=(char4)(5,6,7,8);int s0=i,s1=i,s2=i,s3=i,s4=i,s5=i,s6=i,s7=i;for(int k=0;k<it;k++){s0=arm_dot_acc(a,b,s0);s1=arm_dot_acc(a,b,s1);s2=arm_dot_acc(a,b,s2);s3=arm_dot_acc(a,b,s3);s4=arm_dot_acc(a,b,s4);s5=arm_dot_acc(a,b,s5);s6=arm_dot_acc(a,b,s6);s7=arm_dot_acc(a,b,s7);}o[i]=s0+s1+s2+s3+s4+s5+s6+s7;}","f");
  if(k){clSetKernelArg(k,0,sizeof(cl_mem),&out);clSetKernelArg(k,1,sizeof(int),&it);bestrun(k,G,2);double t=bestrun(k,G,5);printf("INT8 dot     : %.1f TOPS\n",(double)G*it*8*8/t/1e12);}else printf("INT8 dot     : SKIPPED (arm_dot_acc unavailable)\n");}
 // transfer up/down
 {size_t bytes=64*1024*1024;void*h=malloc(bytes);cl_mem b=clCreateBuffer(C,CL_MEM_READ_WRITE,bytes,NULL,&e);
  clEnqueueWriteBuffer(Q,b,CL_TRUE,0,bytes,h,0,NULL,NULL);
  double bu=1e9;for(int r=0;r<10;r++){double t=now();clEnqueueWriteBuffer(Q,b,CL_TRUE,0,bytes,h,0,NULL,NULL);double dt=now()-t;if(dt<bu)bu=dt;}
  double bd=1e9;for(int r=0;r<10;r++){double t=now();clEnqueueReadBuffer(Q,b,CL_TRUE,0,bytes,h,0,NULL,NULL);double dt=now()-t;if(dt<bd)bd=dt;}
  printf("H2D transfer : %.1f GB/s\nD2H transfer : %.1f GB/s\n",bytes/bu/1e9,bytes/bd/1e9);}
 // launch latency
 {cl_kernel k=build("__kernel void f(__global int* o){if(get_global_id(0)==0)o[0]=1;}","f");
  clSetKernelArg(k,0,sizeof(cl_mem),&out);size_t one=1;
  for(int r=0;r<100;r++){clEnqueueNDRangeKernel(Q,k,1,NULL,&one,NULL,0,NULL,NULL);}clFinish(Q);
  int N=2000;double t=now();for(int r=0;r<N;r++){clEnqueueNDRangeKernel(Q,k,1,NULL,&one,NULL,0,NULL,NULL);clFinish(Q);}double dt=now()-t;
  printf("Launch lat   : %.1f us/dispatch (submit+finish)\n",dt/N*1e6);}
 return 0;}
