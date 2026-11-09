#ifndef RD_LINK_POLICY_H
#define RD_LINK_POLICY_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

#define RD_URL_CAP 16385
#define RD_FRAGMENT_CAP 131072
#define RD_REDIRECT_FLAG 0x800000u

typedef struct {
    char id[33];
    char app[RD_URL_CAP];
    char web[RD_URL_CAP];
    uint64_t time_ms;
} RDClickPayload;

/* Values come from Gecko, not from web-page attributes. */
static inline int RDClickEventAllowed(int is_request, int user_gesture,
                                      int top_level, uint32_t flags, int enabled) {
    return is_request && user_gesture && top_level && enabled &&
           !(flags & RD_REDIRECT_FLAG);
}
static inline int RDHex(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
/* Exactly one decode. '+' is a literal plus, never a space. */
static inline int RDDecodeComponent(const char *s, size_t n, char *out, size_t cap) {
    size_t j = 0;
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)s[i];
        if (c == '%') {
            if (i + 2 >= n) return 0;
            int a = RDHex(s[i + 1]), b = RDHex(s[i + 2]);
            if (a < 0 || b < 0) return 0;
            c = (unsigned char)((a << 4) | b); i += 2;
        }
        if (c < 0x20 || c == 0x7f || j + 1 >= cap) return 0;
        out[j++] = (char)c;
    }
    out[j] = 0; return 1;
}
static inline int RDParseClickPayload(const char *fragment, RDClickPayload *out) {
    if (!fragment || !out) return 0;
    size_t n = strlen(fragment);
    if (n == 0 || n > RD_FRAGMENT_CAP || strchr(fragment, '#')) return 0;
    memset(out, 0, sizeof(*out));
    unsigned seen = 0;
    const char *p = fragment;
    while (*p) {
        const char *end = strchr(p, '&');
        if (!end) end = p + strlen(p);
        const char *eq = (const char *)memchr(p, '=', (size_t)(end - p));
        if (!eq || eq == p) return 0;
        size_t keyn = (size_t)(eq - p), vn = (size_t)(end - eq - 1);
        unsigned bit = 0; char small[32] = {0};
        if (keyn == 1 && p[0] == 'v') {
            bit = 1;
            if (vn != 1 || eq[1] != '2') return 0;
        } else if (keyn == 2 && memcmp(p, "id", 2) == 0) {
            bit = 2;
            if (vn != 32) return 0;
            for (size_t i = 0; i < vn; ++i) if (RDHex(eq[1 + i]) < 0) return 0;
            memcpy(out->id, eq + 1, vn);
        } else if (keyn == 1 && p[0] == 'a') {
            bit = 4;
            if (!RDDecodeComponent(eq + 1, vn, out->app, sizeof(out->app))) return 0;
        } else if (keyn == 1 && p[0] == 'h') {
            bit = 8;
            if (!RDDecodeComponent(eq + 1, vn, out->web, sizeof(out->web))) return 0;
        } else if (keyn == 2 && memcmp(p, "ts", 2) == 0) {
            bit = 16;
            if (vn == 0 || vn >= sizeof(small)) return 0;
            for (size_t i = 0; i < vn; ++i) if (eq[1 + i] < '0' || eq[1 + i] > '9') return 0;
            memcpy(small, eq + 1, vn); errno = 0;
            unsigned long long value = strtoull(small, NULL, 10);
            if (errno == ERANGE) return 0;
            out->time_ms = (uint64_t)value;
        } else return 0;
        if (seen & bit) return 0;
        seen |= bit;
        if (!*end) break;
        p = end + 1;
        if (!*p) return 0;
    }
    return seen == 31 && (out->app[0] || out->web[0]);
}
static inline int RDPayloadFresh(uint64_t now, uint64_t stamp) {
    if (stamp > now) return stamp - now <= 1000;
    return now - stamp <= 5000;
}
/* Known Telegram opaque-URI spelling only. Never add slashes to mailto/tel/sms. */
static inline int RDNormalizeAppURL(const char *s, char *out, size_t cap) {
    if (!s || !out) return 0;
    size_t n = strlen(s), extra = 0;
    if (n >= 4 && (s[0] == 't' || s[0] == 'T') &&
        (s[1] == 'g' || s[1] == 'G') && s[2] == ':' && s[3] != '/') {
        const char *tail = s + 3;
        size_t action_n = strcspn(tail, "?/#");
        const char *actions[] = {"resolve", "join", "privatepost", "addstickers", "addemoji", "share", "proxy", "socks", "msg_url"};
        for (size_t i = 0; i < sizeof(actions) / sizeof(actions[0]); ++i) {
            if (strlen(actions[i]) == action_n && memcmp(tail, actions[i], action_n) == 0) { extra = 2; break; }
        }
    }
    if (n + extra + 1 > cap) return 0;
    if (extra) {
        memcpy(out, s, 3); out[3] = '/'; out[4] = '/';
        memcpy(out + 5, s + 3, n - 3 + 1);
    } else memcpy(out, s, n + 1);
    return 1;
}
#endif
