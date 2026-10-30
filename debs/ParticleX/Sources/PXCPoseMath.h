#pragma once
#include <stdbool.h>
#include <math.h>

typedef struct { double a,b,c,d,tx,ty; } PXCPoseTransform;
static inline bool PXCPoseTransformMake(double width,double height,
    double ox,double oy,double xx,double xy,double yx,double yy,
    double canvasX,double canvasY,PXCPoseTransform *out) {
    if (!out || !isfinite(width) || !isfinite(height) || width<2 || height<2 ||
        !isfinite(ox) || !isfinite(oy) || !isfinite(xx) || !isfinite(xy) ||
        !isfinite(yx) || !isfinite(yy) || !isfinite(canvasX) || !isfinite(canvasY)) return false;
    *out=(PXCPoseTransform){(xx-ox)/width,(xy-oy)/width,(yx-ox)/height,(yy-oy)/height,ox-canvasX,oy-canvasY};
    return fabs(out->a*out->d-out->b*out->c)>1e-8;
}
