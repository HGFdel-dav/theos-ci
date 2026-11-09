#include <stdio.h>
#include <assert.h>
#include <string.h>
#include "../Common/RDLinkPolicy.h"
#include "../Common/RDReplyGate.h"
static unsigned total;
#define CHECK(x) do { total++; assert(x); } while(0)
int main(int argc, char **argv) {
    if (argc == 2) {
        RDClickPayload data;
        if (!RDParseClickPayload(argv[1], &data)) return 2;
        printf("%s\n%s\n%s\n%llu\n", data.id, data.app, data.web, (unsigned long long)data.time_ms);
        return 0;
    }
    const char *good="v=2&id=00112233445566778899aabbccddeeff&ts=1794217455000&a=tg%3Aresolve%3Fdomain%3Dmoonup_chat&h=";
    RDClickPayload data;
    CHECK(RDParseClickPayload(good,&data));
    CHECK(!strcmp(data.app,"tg:resolve?domain=moonup_chat"));
    CHECK(!data.web[0]);
    CHECK(data.time_ms == 1794217455000ull);
    CHECK(!RDParseClickPayload("h=https%3A%2F%2Ft.me%2Fmoonup_chat#a=tg%3Aresolve",&data));
    CHECK(!RDParseClickPayload("a=tg%3Aresolve&h=",&data));
    char s[RD_FRAGMENT_CAP+4];
    snprintf(s,sizeof(s),"%s&a=x",good); CHECK(!RDParseClickPayload(s,&data));
    snprintf(s,sizeof(s),"%s&extra=x",good); CHECK(!RDParseClickPayload(s,&data));
    snprintf(s,sizeof(s),"%s&",good); CHECK(!RDParseClickPayload(s,&data));
    CHECK(!RDParseClickPayload("",&data));
    CHECK(!RDParseClickPayload(NULL,&data));
    CHECK(!RDParseClickPayload(good,NULL));
    memset(s,'x',sizeof(s)-1); s[sizeof(s)-1]=0; CHECK(!RDParseClickPayload(s,&data));
    char out[128];
    CHECK(RDDecodeComponent("tg%3Aresolve%3Fx%3Da%252Fb%26p%3D%2B%23z",strlen("tg%3Aresolve%3Fx%3Da%252Fb%26p%3D%2B%23z"),out,sizeof(out)));
    CHECK(!strcmp(out,"tg:resolve?x=a%2Fb&p=+#z"));
    CHECK(RDDecodeComponent("a+b",3,out,sizeof(out))); CHECK(!strcmp(out,"a+b"));
    CHECK(!RDDecodeComponent("%00",3,out,sizeof(out)));
    CHECK(!RDDecodeComponent("%0A",3,out,sizeof(out)));
    CHECK(!RDDecodeComponent("%7f",3,out,sizeof(out)));
    CHECK(!RDDecodeComponent("%GG",3,out,sizeof(out)));
    CHECK(!RDDecodeComponent("%",1,out,sizeof(out)));
    CHECK(!RDDecodeComponent("%A",2,out,sizeof(out)));
    CHECK(!RDDecodeComponent("long",4,out,4));
    CHECK(RDPayloadFresh(10000,10000)); CHECK(RDPayloadFresh(10000,5000));
    CHECK(!RDPayloadFresh(10000,4999)); CHECK(RDPayloadFresh(10000,11000));
    CHECK(!RDPayloadFresh(10000,11001));
    for (int request=0;request<2;request++) for(int gesture=0;gesture<2;gesture++)
    for(int top=0;top<2;top++) for(int enabled=0;enabled<2;enabled++) for(int redirect=0;redirect<2;redirect++) {
        CHECK(RDClickEventAllowed(request,gesture,top,redirect?RD_REDIRECT_FLAG:0,enabled) ==
              (request && gesture && top && enabled && !redirect));
    }
    const char *input[]={"tg:resolve?domain=moonup_chat&post=12&start=a%2Bb#c","tg://resolve?domain=moonup_chat","tel:+861234","mailto:a@b.com?subject=hello%26world","myapp:opaque?x=%2F","tg:unknown?action=resolve","tg:join?invite=Ab-c+1"};
    const char *want[]={"tg://resolve?domain=moonup_chat&post=12&start=a%2Bb#c","tg://resolve?domain=moonup_chat","tel:+861234","mailto:a@b.com?subject=hello%26world","myapp:opaque?x=%2F","tg:unknown?action=resolve","tg://join?invite=Ab-c+1"};
    for(size_t i=0;i<sizeof(input)/sizeof(input[0]);i++) {
        CHECK(RDNormalizeAppURL(input[i],out,sizeof(out)));
        CHECK(!strcmp(out,want[i]));
    }
    CHECK(!RDNormalizeAppURL(input[0],out,4));
    CHECK(RDNormalizeAppURL("tg:",out,sizeof(out))); CHECK(!strcmp(out,"tg:"));
    CHECK(RDNormalizeAppURL("",out,sizeof(out))); CHECK(!strcmp(out,""));
    // success/failure/timeout order: first final result wins, once only.
    for(int first=0;first<2;first++) for(int second=0;second<2;second++) {
        RDReplyGate gate={0,0};CHECK(RDReplyFinish(&gate,first));
        CHECK(!RDReplyFinish(&gate,second));CHECK(gate.result==first);
    }
    printf("POLICY_ASSERTIONS=%u\n",total);
    return 0;
}
