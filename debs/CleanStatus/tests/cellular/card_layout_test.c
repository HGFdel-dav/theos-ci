#include "LCSCellularCardLayout.h"
#include <assert.h>
#include <stdio.h>
static unsigned checks;
#define CHECK(x) do{assert(x);checks++;}while(0)
int main(void) {
    CHECK(LCS_CELLULAR_CARD_WIDTH==336);CHECK(LCS_CELLULAR_CARD_RADIUS==38);
    CHECK(LCSCellularCardHeight(1)==216);CHECK(LCSCellularCardHeaderHeight(1)==96);
    CHECK(LCSCellularCardRowHeight(1)==60);CHECK(LCSCellularCardRowHeight(1)>=44);
    CHECK(LCSCellularCardScale(NAN)==1);CHECK(LCSCellularCardScale(INFINITY)==1);
    CHECK(LCSCellularCardScale(-100)==1);CHECK(LCSCellularCardScale(0)==1);CHECK(LCSCellularCardScale(100)==2.5);
    double previous=0;
    for(unsigned i=0;i<=300;i++) {
        double scale=i/100.0,height=LCSCellularCardHeight(scale),row=LCSCellularCardRowHeight(scale);
        CHECK(isfinite(height)&&height>=216&&height<=444);
        CHECK(height>=previous);previous=height;
        CHECK(row>=60);CHECK(height==LCSCellularCardHeaderHeight(scale)+2*row);
    }
    for(int kind=-1;kind<=2;kind++)for(int known=0;known<2;known++)for(int observed=0;observed<2;observed++) {
        LCSCellularBadge result=LCSCellularCardBadge(kind,known,observed);
        if(!LCSCellularKindValid(kind)||!known)CHECK(result==LCSCellularBadgeUnknown);
        else if(kind==LCSCellularSIMManager)CHECK(result==(observed?LCSCellularBadgeSIMOn:LCSCellularBadgeSIMOff));
        else CHECK(result==(observed?LCSCellularBadgeDataCurrent:LCSCellularBadgeDataOther));
        CHECK(LCSCellularCardBadgeGreen(result)==(LCSCellularKindValid(kind)&&known&&observed));
    }
    CHECK(!LCSCellularCardBadgeGreen(LCSCellularBadgeUnknown));
    printf("PASS cellular card layout/badges: %u production-C assertions; not UIKit rendering or touch validation.\n",checks);
    return 0;
}
