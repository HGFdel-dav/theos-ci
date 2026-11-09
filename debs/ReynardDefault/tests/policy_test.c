#include <stdio.h>
#include <assert.h>
#include <string.h>
#include "../Common/RDLinkPolicy.h"
static unsigned total;
#define CHECK(x) do { total++; assert(x); } while(0)
int main(void) {
    CHECK(RDNativeClickAllowed(1,1,1,1,0,0));
    CHECK(!RDNativeClickAllowed(1,0,1,1,0,0));
    CHECK(!RDNativeClickAllowed(1,1,0,1,0,0));
    CHECK(!RDNativeClickAllowed(0,1,1,1,0,0));
    CHECK(!RDNativeClickAllowed(1,1,1,0,0,0));
    CHECK(!RDNativeClickAllowed(1,1,1,1,1,0));
    CHECK(!RDNativeClickAllowed(1,1,1,1,0,1));
    char out[256];
    const char *tg="tg:resolve?domain=moonup_chat&post=12&start=a%2Bb#c";
    CHECK(RDNormalizeAppURL(tg,out,sizeof(out)));
    CHECK(!strcmp(out,"tg://resolve?domain=moonup_chat&post=12&start=a%2Bb#c"));
    const char *tg2="tg://join?invite=AB-c+1";
    CHECK(RDNormalizeAppURL(tg2,out,sizeof(out)));CHECK(!strcmp(out,tg2));
    const char *other[]={"mailto:a@example.com?subject=x%26y","tel:+861234;ext=7","sms:+1?body=hello%20world","myapp://item/2?a=%2F#x","intent://resolve?domain=x#Intent;scheme=tg;end"};
    for(size_t i=0;i<sizeof(other)/sizeof(other[0]);i++){CHECK(RDNormalizeAppURL(other[i],out,sizeof(out)));CHECK(!strcmp(out,other[i]));}
    CHECK(!RDNormalizeAppURL("tg:",out,sizeof(out)));
    CHECK(!RDNormalizeAppURL("tg:resolve?domain=bad space",out,sizeof(out)));
    CHECK(!RDNormalizeAppURL("tg:resolve?domain=long",out,4));
    printf("NATIVE_POLICY_ASSERTIONS=%u\n",total);return 0;
}
