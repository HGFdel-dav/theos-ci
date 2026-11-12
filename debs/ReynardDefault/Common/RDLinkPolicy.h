#ifndef RD_LINK_POLICY_H
#define RD_LINK_POLICY_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define RD_URL_CAP 16385
#define RD_NATIVE_CLICK_ACTIVATION 1u

/* nsExternalHelperAppService::LoadURI receives const MaybeDiscarded<BC>&.
   It is {uint64_t id; RefPtr<BC> ptr}, not a BrowsingContext pointer. */
struct RDMaybeDiscardedContext { uint64_t id; uintptr_t context; };
static inline int RDUnwrapMaybeDiscardedContext(const void *raw, uint64_t *id,
                                                uintptr_t *context) {
    if (!raw || !id || !context) return 0;
    struct RDMaybeDiscardedContext value;
    memcpy(&value, raw, sizeof(value));
    if (!value.id || !value.context) return 0;
    *id=value.id; *context=value.context; return 1;
}

/* GeckoView load flags are not a redirect detector. Verified tapped-link
   requests can carry 0x800000; gesture/top-level/foreground gate the handoff. */
static inline int RDClickEventAllowed(int isRequest, int userGesture,
                                      int topLevel, uint32_t flags,
                                      int foreground) {
    (void)flags;
    return isRequest && userGesture && topLevel && foreground;
}

static inline int RDNativeClickAllowed(int enabled, int userTriggered,
                                       uint8_t userNavigationInvolvement,
                                       int fileNameIsVoid, int hasPostData,
                                       int hasHeaderStream) {
    return enabled && userTriggered &&
           userNavigationInvolvement == RD_NATIVE_CLICK_ACTIVATION &&
           fileNameIsVoid && !hasPostData && !hasHeaderStream;
}

static inline int RDValidScheme(const char *s, size_t n) {
    if (!s || n == 0 || !((s[0] >= 'a' && s[0] <= 'z') ||
                           (s[0] >= 'A' && s[0] <= 'Z'))) return 0;
    for (size_t i = 1; i < n; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '+' || c == '.' || c == '-')) return 0;
    }
    return 1;
}

/* Only known opaque Telegram spellings receive the missing //. Every byte
   after the scheme is copied unchanged, including query and fragment data. */
static inline int RDNormalizeAppURL(const char *input, char *out, size_t cap) {
    if (!input || !out) return 0;
    size_t n = strlen(input);
    if (n == 0 || n >= cap) return 0;
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)input[i];
        if (c <= 0x20 || c == 0x7f) return 0;
    }
    const char *separator = (const char *)memchr(input, ':', n);
    if (!separator) return 0;
    size_t colon = (size_t)(separator - input);
    if (!RDValidScheme(input, colon) || colon + 1 >= n) return 0;

    size_t extra = 0;
    if (colon == 2 && (input[0] == 't' || input[0] == 'T') &&
        (input[1] == 'g' || input[1] == 'G') && input[colon + 1] != '/') {
        const char *action = separator + 1;
        size_t actionLength = strcspn(action, "?/#");
        const char *known[] = {
            "resolve", "join", "privatepost", "addstickers", "addemoji",
            "share", "proxy", "socks", "msg_url", "passport", "login",
            "confirmphone"
        };
        for (size_t i = 0; i < sizeof(known) / sizeof(known[0]); ++i) {
            if (strlen(known[i]) == actionLength &&
                memcmp(action, known[i], actionLength) == 0) {
                extra = 2;
                break;
            }
        }
    }
    if (n + extra + 1 > cap) return 0;
    memcpy(out, input, colon + 1);
    if (extra) {
        out[colon + 1] = '/';
        out[colon + 2] = '/';
    }
    memcpy(out + colon + 1 + extra, input + colon + 1, n - colon - 1);
    out[n + extra] = 0;
    return 1;
}
#endif
