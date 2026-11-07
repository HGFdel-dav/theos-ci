/* Host only: cc -std=c11 -Wall -Wextra -Werror -pedantic tests/chat/layout_follow_20261107.c -lm -o /var/minis/workspace/layout_follow_20261107 */
#include "../../MiniSightChatLayout.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
static unsigned checks,failures,cases;
#define CHECK(x) do { ++checks; if(!(x)){++failures;if(failures<12)fprintf(stderr,"FAIL case=%u line=%d: %s\n",cases,__LINE__,#x);} } while(0)
static uint32_t seed=7112026;
static double rnd(double a,double b){seed=1664525u*seed+1013904223u;return a+(b-a)*(seed/4294967295.);}
static int overlap(MSRect a,MSRect b){return MSChatLayoutIntersects(a,b);}
static void rectok(MSRect a,MSRect s){CHECK(isfinite(a.x)&&isfinite(a.y)&&isfinite(a.w)&&isfinite(a.h));CHECK(a.w>=0&&a.h>=0);CHECK(a.x>=s.x-1e-6&&a.y>=s.y-1e-6&&a.x+a.w<=s.x+s.w+1e-6&&a.y+a.h<=s.y+s.h+1e-6);}
static void layout(MSRect safe,MSRect pet,MSSize wanted,double width,double key,int visible){
 ++cases; MSRect usable={MSChatLayoutCoordinate(safe.x,0),MSChatLayoutCoordinate(safe.y,0),MSChatLayoutLength(safe.w,0),MSChatLayoutLength(safe.h,0)};
 if(isfinite(key)&&key>0)usable.h=fmax(0,fmin(usable.h,key-8-usable.y));
 MSChatFloatingFrames f=MSChatFloatingLayoutWithComposer(safe,pet,wanted,width,key,visible);
 rectok(f.messages,usable);rectok(f.composer,usable);CHECK(f.placedBelow==0);
 // Compare avoidance against the SAME normalized pet the production solver uses.
 MSRect np=pet; np.w=MSChatLayoutLength(np.w,0); np.h=MSChatLayoutLength(np.h,0);
 np.x=MSChatLayoutCoordinate(np.x,usable.x+usable.w*.5-np.w*.5);
 np.y=MSChatLayoutCoordinate(np.y,usable.y+usable.h-np.h);
 CHECK(!overlap(f.messages,f.composer));CHECK(f.petAvoidance==(overlap(f.messages,np)||overlap(f.composer,np)));
 CHECK(isfinite(f.tailX)&&f.tailX>=0&&f.tailX<=(visible?f.composer.w:f.messages.w));
 if(f.messages.h>0&&f.composer.h>0) CHECK(f.composer.y>=f.messages.y+f.messages.h+6-1e-6);
 if(!visible) CHECK(f.composer.h==0);
 if(visible&&usable.h>=38) CHECK(f.composer.h==38);
}
int main(void){
 MSRect safe={0,59,390,751},pet={163,620,64,64};
 layout(safe,pet,(MSSize){216,96},216,0,1);
 layout(safe,(MSRect){160,59,64,64},(MSSize){216,96},216,0,1); /* top pet: never below */
 layout((MSRect){20,30,230,140},(MSRect){103,88,44,44},(MSSize){200,400},216,0,1);
 layout(safe,pet,(MSSize){216,100},216,500,1); /* keyboard top */
 layout(safe,pet,(MSSize){216,100},216,60,1); /* keyboard clips to zero */
 layout(safe,pet,(MSSize){216,96},216,0,0); /* composer hidden */
 layout((MSRect){0,0,0,0},(MSRect){0,0,0,0},(MSSize){0,0},NAN,NAN,1);
 for(unsigned i=0;i<300;++i){
  MSRect s={rnd(-400,400),rnd(-200,200),rnd(0,800),rnd(0,1200)};
  MSRect p={rnd(-1000,1000),rnd(-1000,1400),rnd(0,180),rnd(0,220)};
  MSSize m={i%9?rnd(1,700):NAN,i%7?rnd(0,900):INFINITY};
  double w=i%11?rnd(0,500):NAN,k=i%5?rnd(-100,1500):INFINITY;
  if(i%31==0)s=(MSRect){NAN,INFINITY,NAN,-4};
  if(i%17==0)p.x=NAN;
  if(i%19==0)p.y=NAN;
  layout(s,p,m,w,k,i%3!=0);
 }
 for(unsigned i=0;i<160;++i){
  ++cases;double w=i%7?rnd(0,300):NAN,h=i%5?rnd(0,80):INFINITY;
  MSChatComposerFrames f=MSChatComposerLayout(w,h,i&1);MSRect bound={0,0,fmax(0,MSFinite(w,0)),fmax(0,MSFinite(h,0))};
  rectok(f.field,bound);rectok(f.more,bound);rectok(f.mic,bound);rectok(f.send,bound);
  if(!f.hasMore)CHECK(f.more.w==0&&f.more.h==0);
  if(!f.hasMic)CHECK(f.mic.w==0&&f.mic.h==0);
  CHECK(isfinite(f.field.x)&&isfinite(f.field.y)&&isfinite(f.send.x)&&isfinite(f.send.y));
 }
 printf("layout_follow_20261107: cases=%u checks=%u failures=%u\n",cases,checks,failures);
 return failures?1:0;
}
