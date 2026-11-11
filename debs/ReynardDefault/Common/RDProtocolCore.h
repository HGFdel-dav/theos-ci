#ifndef RD_PROTOCOL_CORE_H
#define RD_PROTOCOL_CORE_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include "RDLinkPolicy.h"

/* Candidate policy and host tests only; not integrated into an iOS hook.
   A Gecko activation flag is NOT proof of a direct DOM anchor click. */
#define RD_PROTOCOL_FAILURE ((int32_t)0x80004005u)
#define RD_PROTOCOL_OK ((int32_t)0)
#define RD_SCHEME_CAP 65

static inline int RDProtocolSchemeAllowed(const char *s, size_t n) {
    if (!s || !n || n >= RD_SCHEME_CAP || !RDValidScheme(s,n)) return 0;
    static const char *const denied[] = {
        "http","https","about","data","blob","javascript","file","resource",
        "jar","view-source","wyciwyg","ws","wss","ftp","intent","reynard",
        "chrome","chrome-extension","moz-extension"
    };
    for (size_t i=0;i<sizeof(denied)/sizeof(denied[0]);++i) {
        if (strlen(denied[i])!=n) continue;
        size_t j=0;
        for (;j<n;++j) {
            unsigned char c=(unsigned char)s[j];
            if (c>='A' && c<='Z') c=(unsigned char)(c+32);
            if (c!=(unsigned char)denied[i][j]) break;
        }
        if (j==n) return 0;
    }
    return 1;
}
static inline int RDProtocolCopyScheme(const char *url, size_t n, char out[RD_SCHEME_CAP]) {
    if (!url || !out || !n || n>=RD_URL_CAP) return 0;
    const char *p=(const char *)memchr(url,':',n);
    if (!p) return 0;
    size_t len=(size_t)(p-url);
    if (!RDProtocolSchemeAllowed(url,len)) return 0;
    for (size_t i=0;i<len;++i) {
        char c=url[i]; out[i]=(c>='A' && c<='Z')?(char)(c+32):c;
    }
    out[len]=0; return 1;
}
struct RDProtocolFacts {
    bool ready, enabled, mainThread, foreground, topLevel, contextActive;
    bool uriPresent, principalPresent, contextPresent;
    bool userActivation, triggeredExternally, redirected, reentrant;
    // Requires independent per-navigation evidence, not userActivation again.
    bool directClickProven;
};
static inline bool RDProtocolEligible(const RDProtocolFacts &f) {
    return f.ready && f.enabled && f.mainThread && f.foreground && f.topLevel &&
        f.contextActive && f.uriPresent && f.principalPresent && f.contextPresent &&
        f.userActivation && f.directClickProven && !f.triggeredExternally &&
        !f.redirected && !f.reentrant;
}
struct RDProtocolTrace {
    uintptr_t service;
    uintptr_t safeReturnPC;
    char scheme[RD_SCHEME_CAP];
    bool platformFailure;
};
static inline void RDProtocolObserveInfo(RDProtocolTrace *t, uintptr_t service,
    uintptr_t returnPC, const char *scheme, size_t n, int32_t rv,
    bool expectedPlatformStub, bool handlerIsNull) {
    if (!t || !scheme || !n || n>=RD_SCHEME_CAP) return;
    if (service!=t->service || returnPC!=t->safeReturnPC ||
        rv!=RD_PROTOCOL_FAILURE || !expectedPlatformStub || !handlerIsNull) return;
    if (strlen(t->scheme)!=n || memcmp(t->scheme,scheme,n)) return;
    t->platformFailure=true;
}
static inline bool RDProtocolMayOpen(const RDProtocolFacts &f,
    const RDProtocolTrace &t, int32_t originalResult) {
    return RDProtocolEligible(f) && t.platformFailure && originalResult==RD_PROTOCOL_FAILURE;
}
static inline int32_t RDProtocolResult(int32_t originalResult, bool accepted) {
    return accepted?RD_PROTOCOL_OK:originalResult;
}
/* A failed launch is never cached as handled. A duplicate only reuses a
   previous accepted result in the same context during a short burst. */
struct RDProtocolBurst {
    uintptr_t context;
    uint64_t urlHash;
    double at;
    bool accepted;
};
static inline bool RDProtocolDuplicate(const RDProtocolBurst &b, uintptr_t context,
    uint64_t urlHash, double now) {
    return b.accepted && context && b.context==context && b.urlHash==urlHash &&
        isfinite(now) && isfinite(b.at) && now>=b.at && now-b.at<0.35;
}
static inline uint64_t RDProtocolHash(const char *s, size_t n) {
    uint64_t h=UINT64_C(14695981039346656037);
    for (size_t i=0;i<n;++i) { h^=(unsigned char)s[i];h*=UINT64_C(1099511628211); }
    return h;
}
/* One OnLinkClickSync frame is proof that the navigation originated from an
   actual link/form action, not a redirect or a page-initiated load.
   UserNavigationInvolvement must be Activation (1); a mere activation flag on
   an arbitrary scripted load is insufficient. */
struct RDClickIntent {
    bool fromLinkClickSync;
    bool navigationAllowed;
    bool uriAllowed;
    bool contentPresent;
    bool contentEditable;
    bool loadStatePresent;
    bool sameDocument;
    bool fileReferenceVoid;
    bool hasPostData;
    bool hasHeaders;
    bool userNavigation;
    bool clickActivation;
    uint8_t userInvolvement;
};
static inline bool RDClickIntentEligible(const RDClickIntent &c) {
    return c.fromLinkClickSync && c.navigationAllowed && c.uriAllowed &&
        c.contentPresent && !c.contentEditable && c.loadStatePresent &&
        c.fileReferenceVoid && !c.hasPostData && !c.hasHeaders &&
        c.userNavigation && c.clickActivation && c.userInvolvement == 1;
}
static inline const char *RDClickIntentReason(const RDClickIntent &c) {
    if (!c.fromLinkClickSync) return "not-link-click";
    if (!c.navigationAllowed) return "navigation-blocked";
    if (!c.uriAllowed) return "uri-rejected";
    if (!c.contentPresent || !c.loadStatePresent) return "missing-object";
    if (c.contentEditable) return "editable";
    if (!c.fileReferenceVoid) return "download";
    if (c.hasPostData) return "post-data";
    if (c.hasHeaders) return "header-stream";
    if (!c.userNavigation) return "not-user-navigation";
    if (!c.clickActivation) return "no-click-activation";
    if (c.userInvolvement != 1) return "not-activation";
    return "eligible";
}
#endif
