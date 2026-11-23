#include "LCSCellularEntryPolicy.h"
#include <stdio.h>
#include <stdlib.h>
static unsigned checks;
#define T(v) do{checks++;if(!(v)){fprintf(stderr,"expansion gate failed at %d\n",__LINE__);exit(1);}}while(0)
int main(void){
 const LCSCellularExpansion states[]={LCSCellularExpansionUnknown,LCSCellularExpansionCollapsed,LCSCellularExpansionExpanded,(LCSCellularExpansion)2,(LCSCellularExpansion)-2};
 for(unsigned i=0;i<5;i++)for(unsigned own=0;own<2;own++)for(unsigned local=0;local<2;local++)
  T(LCSCellularMayBeginPress(states[i],own,local)==(states[i]==LCSCellularExpansionCollapsed&&own&&local));
 T(!LCSCellularMayBeginPress(LCSCellularExpansionUnknown,true,true));
 T(!LCSCellularMayBeginPress(LCSCellularExpansionExpanded,true,true));
 T(LCSCellularMayBeginPress(LCSCellularExpansionCollapsed,true,true));
 /* Model a callback ordering race using the ACTUAL production predicate. */
 LCSCellularExpansion current=LCSCellularExpansionUnknown;
 T(!LCSCellularMayBeginPress(current,true,true));
 current=LCSCellularExpansionCollapsed;T(LCSCellularMayBeginPress(current,true,true));
 current=LCSCellularExpansionExpanded;T(!LCSCellularMayBeginPress(current,true,true));
 current=LCSCellularExpansionCollapsed;T(LCSCellularMayBeginPress(current,true,true));
 T(!LCSCellularMayBeginPress(current,true,false)); /* OFF/lock/cancel gate */
 T(!LCSCellularMayBeginPress(current,false,true)); /* unrelated recognizer */
 /* Window fallback: only when direct touch is unavailable, visible, and inside. */
 for(unsigned use=0;use<2;use++)for(unsigned direct=0;direct<2;direct++)for(unsigned vis=0;vis<2;vis++)for(unsigned hit=0;hit<2;hit++)
  T(LCSCellularWindowFallbackAllows(use,direct,vis,hit)==(use&&!direct&&vis&&hit));
 T(LCSCellularWindowFallbackAllows(true,false,true,true));
 T(!LCSCellularWindowFallbackAllows(true,true,true,true)); /* direct touch works: fallback stays off */
 T(!LCSCellularWindowFallbackAllows(false,false,true,true)); /* direct recognizer is not the fallback */
 T(!LCSCellularWindowFallbackAllows(true,false,false,true)); /* hidden/offscreen button */
 T(!LCSCellularWindowFallbackAllows(true,false,true,false)); /* touch outside the button region */
 printf("PASS cellular expansion gate: %u production-C checks; no UIKit runtime\n",checks);return 0;
}
