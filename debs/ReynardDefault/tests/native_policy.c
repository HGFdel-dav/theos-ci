#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../Common/RDLinkPolicy.h"
int main(void) {
    unsigned n=0;
#define T(x) do { n++; assert(x); } while (0)
    T(RDClickEventAllowed(1,1,1,0,1));
    T(!RDClickEventAllowed(1,0,1,0,1));
    T(!RDClickEventAllowed(1,1,0,0,1));
    T(!RDClickEventAllowed(1,1,1,0x800000u,1));
    T(!RDClickEventAllowed(1,1,1,0,0));
    T(!RDClickEventAllowed(0,1,1,0,1));
    char out[256];
    T(RDNormalizeAppURL("tg:resolve?domain=moonup_chat&post=2&start=a%2Bb#x",out,sizeof(out)));
    T(!strcmp(out,"tg://resolve?domain=moonup_chat&post=2&start=a%2Bb#x"));
    T(RDNormalizeAppURL("tg://join?invite=AB-c+1",out,sizeof(out)));
    T(!strcmp(out,"tg://join?invite=AB-c+1"));
    T(RDNormalizeAppURL("mailto:a@example.com?subject=x%26y",out,sizeof(out)));
    T(!strcmp(out,"mailto:a@example.com?subject=x%26y"));
    T(RDNormalizeAppURL("tel:+861234;ext=7",out,sizeof(out)));
    T(!strcmp(out,"tel:+861234;ext=7"));
    T(RDNormalizeAppURL("intent://resolve?domain=x#Intent;scheme=tg;end",out,sizeof(out)));
    T(!strcmp(out,"intent://resolve?domain=x#Intent;scheme=tg;end"));
    T(!RDNormalizeAppURL("tg:",out,sizeof(out)));
    T(!RDNormalizeAppURL("tg:resolve?domain=bad space",out,sizeof(out)));
    char small[4]; T(!RDNormalizeAppURL("tg:resolve?domain=too-long",small,sizeof(small)));
    printf("NATIVE_POLICY_ASSERTIONS=%u\n",n); return 0;
}
