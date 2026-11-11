#include "../Common/RDProtocolCore.h"
#include <assert.h>
#include <stdio.h>
#include <string>
#include <limits>
static unsigned checks;
#define T(x) do { ++checks; if (!(x)) { fprintf(stderr,"failed line %d: %s\n",__LINE__,#x); return 1; } } while(0)
int main() {
    const char *good[]={"tg","mailto","tel","sms","weixin","alipays","foo+bar","TG"};
    for (const char *s:good) T(RDProtocolSchemeAllowed(s,strlen(s)));
    const char *bad[]={"","https","HTTP","about","data","blob","javascript","file","resource","jar","view-source","wyciwyg","ws","wss","ftp","intent","reynard","chrome","chrome-extension","moz-extension","3tg","tg/","tg:"};
    for (const char *s:bad) T(!RDProtocolSchemeAllowed(s,strlen(s)));
    T(!RDProtocolSchemeAllowed(nullptr,0));
    std::string huge(65,'a');T(!RDProtocolSchemeAllowed(huge.data(),huge.size()));
    char scheme[RD_SCHEME_CAP];
    const char *schemeURL="tg:resolve?domain=x";
    T(RDProtocolCopyScheme(schemeURL,strlen(schemeURL),scheme));T(!strcmp(scheme,"tg"));
    T(!RDProtocolCopyScheme("https://x",9,scheme));
    T(!RDProtocolCopyScheme(nullptr,1,scheme));
    RDProtocolFacts f={true,true,true,true,true,true,true,true,true,true,false,false,false,true};
    T(RDProtocolEligible(f));
    RDProtocolFacts residualActivation=f;
    residualActivation.directClickProven=false;
    T(!RDProtocolEligible(residualActivation));
    for (unsigned mask=0;mask<(1u<<14);++mask) {
        RDProtocolFacts q={bool(mask&1),bool(mask&2),bool(mask&4),bool(mask&8),bool(mask&16),bool(mask&32),bool(mask&64),bool(mask&128),bool(mask&256),bool(mask&512),bool(mask&1024),bool(mask&2048),bool(mask&4096),bool(mask&8192)};
        T(RDProtocolEligible(q)==(mask==(1023|8192)));
    }
    RDProtocolTrace trace={0x100,0x200,"tg",false};
    T(!RDProtocolMayOpen(f,trace,RD_PROTOCOL_FAILURE));
    for (unsigned mask=0;mask<128;++mask) {
        RDProtocolTrace t=trace;
        RDProtocolObserveInfo(&t,(mask&1)?0x100:0x101,(mask&2)?0x200:0x201,
            (mask&4)?"tg":"tel",(mask&4)?2:3,(mask&8)?RD_PROTOCOL_FAILURE:0,
            mask&16,mask&32);
        if (mask&64) t.platformFailure=false;
        T(t.platformFailure==(mask==63));
    }
    RDProtocolObserveInfo(&trace,0x100,0x200,"tg",2,RD_PROTOCOL_FAILURE,true,true);
    T(RDProtocolMayOpen(f,trace,RD_PROTOCOL_FAILURE));
    T(!RDProtocolMayOpen(residualActivation,trace,RD_PROTOCOL_FAILURE));
    T(!RDProtocolMayOpen(f,trace,0));
    T(!RDProtocolMayOpen(f,trace,(int32_t)0x80004003));
    T(RDProtocolResult(RD_PROTOCOL_FAILURE,false)==RD_PROTOCOL_FAILURE);
    T(RDProtocolResult(RD_PROTOCOL_FAILURE,true)==0);
    RDProtocolBurst b={0x55,7,100.0,true};
    T(RDProtocolDuplicate(b,0x55,7,100.1));
    T(!RDProtocolDuplicate(b,0x55,8,100.1));
    T(!RDProtocolDuplicate(b,0x56,7,100.1));
    T(!RDProtocolDuplicate(b,0x55,7,100.4));
    T(!RDProtocolDuplicate(b,0x55,7,99.0));
    T(!RDProtocolDuplicate(b,0x55,7,std::numeric_limits<double>::quiet_NaN()));
    b.accepted=false;T(!RDProtocolDuplicate(b,0x55,7,100.1));
    char out[RD_URL_CAP+2];
    const char *url="tg:resolve?domain=moonup_chat&post=2&start=a%2Bb#x";
    T(RDNormalizeAppURL(url,out,sizeof(out)));T(!strcmp(out,"tg://resolve?domain=moonup_chat&post=2&start=a%2Bb#x"));
    const char *untouched[]={"mailto:a@example.com?subject=x%26y","tel:+861234;ext=7","tg://join?invite=a-b+1","weixin://dl/scan"};
    for (const char *s:untouched) {T(RDNormalizeAppURL(s,out,sizeof(out)));T(!strcmp(s,out));}
    RDClickIntent click={true,true,true,true,false,true,false,true,false,false,true,true,1};
    T(RDClickIntentEligible(click));
    T(!strcmp(RDClickIntentReason(click),"eligible"));
    for (unsigned mask=0;mask<(1u<<12);++mask) {
        RDClickIntent c={bool(mask&1),bool(mask&2),bool(mask&4),bool(mask&8),false,bool(mask&32),false,bool(mask&128),bool(mask&256),bool(mask&512),bool(mask&1024),bool(mask&2048),1};
        T(RDClickIntentEligible(c)==((mask & ~(16u|64u))==3247u));
    }
    click.contentEditable=true;T(!RDClickIntentEligible(click));T(!strcmp(RDClickIntentReason(click),"editable"));click.contentEditable=false;
    click.fileReferenceVoid=false;T(!strcmp(RDClickIntentReason(click),"download"));click.fileReferenceVoid=true;
    click.hasPostData=true;T(!strcmp(RDClickIntentReason(click),"post-data"));click.hasPostData=false;
    click.hasHeaders=true;T(!strcmp(RDClickIntentReason(click),"header-stream"));click.hasHeaders=false;
    click.userInvolvement=0;T(!RDClickIntentEligible(click));T(!strcmp(RDClickIntentReason(click),"not-activation"));click.userInvolvement=1;
    click.userNavigation=false;T(!RDClickIntentEligible(click));click.userNavigation=true;
    click.clickActivation=false;T(!RDClickIntentEligible(click));click.clickActivation=true;
    click.loadStatePresent=false;T(!RDClickIntentEligible(click));T(!strcmp(RDClickIntentReason(click),"missing-object"));click.loadStatePresent=true;
    click.fromLinkClickSync=false;T(!RDClickIntentEligible(click));T(!strcmp(RDClickIntentReason(click),"not-link-click"));
    printf("PROTOCOL_CORE_CHECKS=%u (host logic only)\n",checks);
}
