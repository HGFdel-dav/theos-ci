#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>

typedef enum { LCSCellularSIMManager=0, LCSCellularDataSwitch=1 } LCSCellularKind;
typedef enum { LCSCellularPending=0,LCSCellularVerified=1,LCSCellularRefused=2,LCSCellularExpired=3 } LCSCellularResult;

static inline bool LCSCellularKindValid(int kind) { return kind==0 || kind==1; }
static inline bool LCSCellularPresentPolicy(int kind,bool enabled,bool host,int os,
    bool unlocked,bool visible,bool uniqueButton,bool conflictingModal,bool transitioning) {
    return LCSCellularKindValid(kind)&&enabled&&host&&os==15&&unlocked&&visible&&
        uniqueButton&&!conflictingModal&&!transitioning;
}
static inline bool LCSCellularTapBindingSafe(bool hasPrimaryAction,bool hasEarlyAction,
                                            bool uniqueButton,bool imageIsSystem) {
    return hasPrimaryAction&&!hasEarlyAction&&uniqueButton&&imageIsSystem;
}
static inline bool LCSCellularIdentityEqual(const char *expected,const char *actual) {
    if(!expected||!actual)return false;
    size_t a=strlen(expected),b=strlen(actual);
    return a>0&&a<=256&&b==a&&!memcmp(expected,actual,a);
}
static inline bool LCSCellularCanWrite(int kind,bool enabled,bool unlocked,bool currentToken,
    bool available,bool stateKnown,bool identityPresent,bool identityEqual,bool busy,
    bool disabling,bool confirmed) {
    return LCSCellularKindValid(kind)&&enabled&&unlocked&&currentToken&&available&&stateKnown&&
        identityPresent&&identityEqual&&!busy&&(!(kind==0&&disabling)||confirmed);
}
static inline bool LCSCellularReadbackMatches(int kind,bool identityEqual,bool known,
    bool observed,bool requested) {
    return LCSCellularKindValid(kind)&&identityEqual&&known&&observed==requested;
}
static inline LCSCellularResult LCSCellularResolve(bool refused,bool verified,bool expired) {
    return refused?LCSCellularRefused:(verified?LCSCellularVerified:(expired?LCSCellularExpired:LCSCellularPending));
}
static inline bool LCSCellularExpiredAt(double now,double started,double timeout) {
    return !isfinite(now)||!isfinite(started)||!isfinite(timeout)||timeout<=0||now<started||now-started>=timeout;
}
static inline uint64_t LCSCellularNextGeneration(uint64_t old) { return old==UINT64_MAX?1:old+1; }
static inline bool LCSCellularGenerationCurrent(uint64_t expected,uint64_t current,bool active) {
    return expected!=0&&active&&expected==current;
}
static inline bool LCSCellularHelperArgumentValid(const char *identity,const char *state) {
    if(!identity||!state||!LCSCellularIdentityEqual(identity,identity))return false;
    if(!(state[0]=='0'||state[0]=='1')||state[1])return false;
    for(const unsigned char *p=(const unsigned char *)identity;*p;p++)if(*p<32||*p==127)return false;
    return true;
}
// Match ABI categories precisely; an Objective-C object is never a block or integer.
static inline const char *LCSCellularTrimType(const char *s) {
    while(s&&*s&&strchr("rnNoORV",*s))s++;
    return s;
}
static inline bool LCSCellularObjectEncoding(const char *s) {
    if(!s||s[0]!='@')return false;
    if(s[1]==0)return true;
    if(s[1]!='"')return false;
    const char *end=strchr(s+2,'"');
    return end&&end>s+2&&end[1]==0;
}
static inline bool LCSCellularTypeEqual(const char *a,const char *b) {
    a=LCSCellularTrimType(a);b=LCSCellularTrimType(b);
    if(!a||!b)return false;
    if(!strcmp(a,b))return true;
    if((!strcmp(a,"B")||!strcmp(a,"c"))&&(!strcmp(b,"B")||!strcmp(b,"c")))return true;
    if(LCSCellularObjectEncoding(a)&&LCSCellularObjectEncoding(b))return true;
    if(a[0]=='^'&&b[0]=='^'&&LCSCellularObjectEncoding(LCSCellularTrimType(a+1))&&LCSCellularObjectEncoding(LCSCellularTrimType(b+1)))return true;
    return false;
}
