#include "LCSCellularEntryPolicy.h"
#include <stdio.h>
int main(void){LCSEntryAttempt a={0};LCSEntryRect r={0,0,10,10};LCSEntryGates g={1,1,1,1,1,1,1,1,1,1};if(!LCSEntryReceive(&a,g,r,3,3,1,0))return 1;if(!LCSEntryBegin(&a,g,r,3,3,0))return 2;LCSEntryCancel(&a);puts("policy-ok");return 0;}
