#ifndef RD_LINK_POLICY_H
#define RD_LINK_POLICY_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define RD_URL_CAP 16385
#define RD_REDIRECT_FLAG 0x800000u

/* These values come from GeckoView's OnPreNavigation payload. */
static inline int RDClickEventAllowed(int is_request, int user_gesture,
                                      int top_level, uint32_t flags,
                                      int foreground) {
    return is_request && user_gesture && top_level && foreground &&
           !(flags & RD_REDIRECT_FLAG);
}

static inline int RDHex(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
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
