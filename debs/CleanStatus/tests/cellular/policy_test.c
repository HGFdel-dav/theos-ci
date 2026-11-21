#include "LCSCellularPolicy.h"
#include <assert.h>
#include <stdio.h>
static unsigned checks;
#define CHECK(x) do { assert(x);checks++; } while(0)
int main(void) {
    for(int kind=-1;kind<=2;kind++)for(int os=14;os<=17;os++)for(unsigned m=0;m<128;m++) {
        bool enabled=m&1,host=m&2,unlocked=m&4,visible=m&8,unique=m&16,modal=m&32,transition=m&64;
        bool expected=(kind==0||kind==1)&&os==15&&enabled&&host&&unlocked&&visible&&unique&&!modal&&!transition;
        CHECK(LCSCellularPresentPolicy(kind,enabled,host,os,unlocked,visible,unique,modal,transition)==expected);
    }
    for(unsigned m=0;m<16;m++)CHECK(LCSCellularTapBindingSafe(m&1,m&2,m&4,m&8)==((m&1)&&!(m&2)&&(m&4)&&(m&8)));
    for(int kind=-1;kind<=2;kind++)for(unsigned m=0;m<1024;m++) {
        bool enabled=m&1,unlocked=m&2,token=m&4,available=m&8,known=m&16,identity=m&32,equal=m&64,busy=m&128,disabling=m&256,confirmed=m&512;
        bool expected=(kind==0||kind==1)&&enabled&&unlocked&&token&&available&&known&&identity&&equal&&!busy&&(kind!=0||!disabling||confirmed);
        CHECK(LCSCellularCanWrite(kind,enabled,unlocked,token,available,known,identity,equal,busy,disabling,confirmed)==expected);
    }
    for(int kind=-1;kind<=2;kind++)for(unsigned m=0;m<16;m++) {
        bool equal=m&1,known=m&2,observed=m&4,desired=m&8;
        CHECK(LCSCellularReadbackMatches(kind,equal,known,observed,desired)==((kind==0||kind==1)&&equal&&known&&observed==desired));
    }
    CHECK(!LCSCellularIdentityEqual(NULL,"id"));CHECK(!LCSCellularIdentityEqual("id",NULL));
    CHECK(!LCSCellularIdentityEqual("",""));CHECK(LCSCellularIdentityEqual("identity-a","identity-a"));
    CHECK(!LCSCellularIdentityEqual("identity-a","identity-b"));CHECK(!LCSCellularIdentityEqual("abc","abcd"));
    char max[258];memset(max,'x',sizeof(max));max[256]=0;CHECK(LCSCellularIdentityEqual(max,max));max[256]='x';max[257]=0;CHECK(!LCSCellularIdentityEqual(max,max));
    CHECK(LCSCellularHelperArgumentValid("opaque-id","0"));CHECK(LCSCellularHelperArgumentValid("opaque-id","1"));
    CHECK(!LCSCellularHelperArgumentValid("opaque-id","2"));CHECK(!LCSCellularHelperArgumentValid("opaque-id","10"));
    CHECK(!LCSCellularHelperArgumentValid("opaque-id",""));CHECK(!LCSCellularHelperArgumentValid("opaque\n-id","1"));
    CHECK(!LCSCellularHelperArgumentValid("opaque\177-id","1"));CHECK(!LCSCellularHelperArgumentValid(NULL,"1"));
    for(unsigned m=0;m<8;m++)CHECK(LCSCellularResolve(m&1,m&2,m&4)==((m&1)?LCSCellularRefused:((m&2)?LCSCellularVerified:((m&4)?LCSCellularExpired:LCSCellularPending))));
    CHECK(LCSCellularExpiredAt(NAN,0,8));CHECK(LCSCellularExpiredAt(1,NAN,8));CHECK(LCSCellularExpiredAt(1,0,NAN));
    CHECK(LCSCellularExpiredAt(1,0,0));CHECK(LCSCellularExpiredAt(0,1,8));CHECK(!LCSCellularExpiredAt(7.9,0,8));CHECK(LCSCellularExpiredAt(8,0,8));
    CHECK(LCSCellularNextGeneration(UINT64_MAX)==1);CHECK(LCSCellularNextGeneration(0)==1);
    CHECK(!LCSCellularGenerationCurrent(0,0,true));CHECK(!LCSCellularGenerationCurrent(1,1,false));
    CHECK(!LCSCellularGenerationCurrent(1,2,true));CHECK(LCSCellularGenerationCurrent(1,1,true));
    const char *positive[][2]={{"@","@"},{"@\"NSUUID\"","@"},{"r@","@"},{"^@\"NSError\"","^@"},{"B","c"},{"q","q"},{"v","v"},{"@?","@?"}};
    const char *negative[][2]={{"@?","@"},{"@","@?"},{"q","@"},{"@","q"},{"B","v"},{"B","q"},{"Q","q"},{"^@?","^@"},{"^v","^@"},{"^q","^@"},{"^@","@"},{"q","d"},{"@garbage","@"},{"@\"NSUUID","@"}};
    for(unsigned i=0;i<sizeof(positive)/sizeof(positive[0]);i++)CHECK(LCSCellularTypeEqual(positive[i][0],positive[i][1]));
    for(unsigned i=0;i<sizeof(negative)/sizeof(negative[0]);i++)CHECK(!LCSCellularTypeEqual(negative[i][0],negative[i][1]));
    // Cancellation/lock/no-identity failures must not authorize either backend.
    for(int kind=0;kind<2;kind++) {
        CHECK(!LCSCellularCanWrite(kind,true,true,false,true,true,true,true,false,false,true));
        CHECK(!LCSCellularCanWrite(kind,true,false,true,true,true,true,true,false,false,true));
        CHECK(!LCSCellularCanWrite(kind,true,true,true,true,true,false,true,false,false,true));
        CHECK(!LCSCellularReadbackMatches(kind,false,true,true,true));
    }
    printf("PASS cellular production policy: %u assertions; no UIKit, device, SIM or network operations.\n",checks);
    return 0;
}
