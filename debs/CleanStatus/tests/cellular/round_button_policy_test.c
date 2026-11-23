#include "LCSCellularEntryPolicy.h"
#include <stdio.h>
#include <stdlib.h>
static unsigned checks;
#define T(v) do{checks++;if(!(v)){fprintf(stderr,"round button policy failed at %d\n",__LINE__);exit(1);}}while(0)
int main(void){
 const bool original[2]={false,true};
 for(unsigned own=0;own<2;own++)for(unsigned orig=0;orig<2;orig++)for(unsigned local=0;local<2;local++){
  bool expected=own?local:orig;
  T(LCSRoundButtonAllowsGesture(own,original[orig],local)==expected);
 }
 T(!LCSRoundButtonAllowsGesture(true,true,false));
 T(LCSRoundButtonAllowsGesture(true,false,true));
 T(LCSRoundButtonAllowsGesture(false,true,false));
 T(!LCSRoundButtonAllowsGesture(false,false,true));
 printf("PASS round-button delegate policy: %u checks; no UIKit execution.\n",checks);
 return 0;
}
