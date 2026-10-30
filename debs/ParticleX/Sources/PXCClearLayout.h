#pragma once
#include <stdbool.h>
#include <math.h>

typedef struct { double x,y,w,h; } PXCClearRect;
typedef struct { PXCClearRect frame; bool nativeMatched; } PXCClearPlacement;
static inline bool PXCClearRectValid(PXCClearRect r) {
    return isfinite(r.x)&&isfinite(r.y)&&isfinite(r.w)&&isfinite(r.h)&&r.w>0&&r.h>0;
}
static inline double PXCClearClamp(double x,double low,double high) { return fmax(low,fmin(high,x)); }
static inline bool PXCClearReferenceValid(PXCClearRect r,PXCClearRect host) {
    if (!PXCClearRectValid(r)) return false;
    double d=fmin(r.w,r.h),ratio=r.w/r.h;
    // Reject touch regions, invalid/transitional layouts and off-host frames.
    return d>=24 && d<=fmin(host.w,host.h)*0.30 && ratio>=0.80 && ratio<=1.25 &&
        r.x>=host.x-1 && r.y>=host.y-1 && r.x+r.w<=host.x+host.w+1 && r.y+r.h<=host.y+host.h+1;
}
static inline bool PXCClearLayoutMake(PXCClearRect host,PXCClearRect safe,
    PXCClearRect first,PXCClearRect second,unsigned style,double desiredWidth,PXCClearPlacement *out) {
    if (!out || !PXCClearRectValid(host) || !PXCClearRectValid(safe) || !isfinite(desiredWidth)) return false;
    double left=fmax(host.x,safe.x)+8,right=fmin(host.x+host.w,safe.x+safe.w)-8;
    double top=fmax(host.y,safe.y),bottom=fmin(host.y+host.h,safe.y+safe.h);
    if (right-left<32 || bottom-top<32) return false;
    bool a=PXCClearReferenceValid(first,host),b=PXCClearReferenceValid(second,host);
    double d=50,cx=(left+right)*0.5,cy=bottom-12-d*0.5;
    if (a || b) {
        PXCClearRect ref=a?first:second;
        d=fmin(ref.w,ref.h);cy=ref.y+ref.h*0.5;
        if (a && b) {
            double da=fmin(first.w,first.h),db=fmin(second.w,second.h);
            d=fmin(da,db);
            // Paired native buttons must really be on the same row.
            if (fabs((first.y+first.h*0.5)-(second.y+second.h*0.5))>d*0.35) b=false;
            else {
                cx=(first.x+first.w*0.5+second.x+second.w*0.5)*0.5;
                cy=(first.y+first.h*0.5+second.y+second.h*0.5)*0.5;
            }
        }
        if (a) {
            if (first.x+first.w*0.5<cx) left=fmax(left,first.x+first.w+10);
            else right=fmin(right,first.x-10);
        }
        if (b) {
            if (second.x+second.w*0.5<cx) left=fmax(left,second.x+second.w+10);
            else right=fmin(right,second.x-10);
        }
    }
    if (d>bottom-top || right-left<d) return false;
    double width=style==1 ? d : fmax(d,desiredWidth);
    width=fmin(width,right-left);
    cx=PXCClearClamp(cx,left+width*0.5,right-width*0.5);
    cy=PXCClearClamp(cy,top+d*0.5,bottom-d*0.5);
    out->frame=(PXCClearRect){cx-width*0.5,cy-d*0.5,width,d};
    out->nativeMatched=a||b;
    return true;
}
