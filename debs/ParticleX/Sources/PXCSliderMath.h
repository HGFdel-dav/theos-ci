#pragma once
#include <math.h>
#include <stdbool.h>

typedef struct { double x,y,emitterWidth,emitterHeight,birthRate; } PXCSliderGeometry;
static inline bool PXCSliderGeometryMake(double width,double height,double value,double delta,unsigned density,PXCSliderGeometry *g) {
    if (!g || !isfinite(width) || !isfinite(height) || !isfinite(value) || !isfinite(delta) || width<8 || height<8 || width>2048 || height>2048) return false;
    value=fmax(0,fmin(1,value));density=density>2?2:density;
    bool vertical=height>=width;
    g->x=vertical?width*0.5:width*value;
    g->y=vertical?height*(1-value):height*0.5;
    g->emitterWidth=vertical?width*0.76:2;
    g->emitterHeight=vertical?2:height*0.76;
    g->birthRate=(0.6+fmin(fabs(delta)*28,1.8))*(0.7+0.3*density);
    return true;
}
