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
 printf("PASS cellular expansion gate: %u production-C checks; no UIKit runtime\n",checks);return 0;
}
