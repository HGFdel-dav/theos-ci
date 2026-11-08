#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

// Shared by production Objective-C and the host behavioral harness.
// No timer may decide that a payment succeeded or select another request.
typedef enum {
    PXURLRouteNew = 0, PXURLRouteChoosing, PXURLRouteStopping,
    PXURLRouteSwitching, PXURLRouteVerifying, PXURLRouteForwarded,
    PXURLRouteCancelled, PXURLRouteFailed
} PXURLRoutePhase;

typedef struct {
    uint64_t token;
    PXURLRoutePhase phase;
} PXURLRouteState;

static inline bool PXURLRouteTerminal(PXURLRoutePhase phase) {
    return phase == PXURLRouteForwarded || phase == PXURLRouteCancelled || phase == PXURLRouteFailed;
}
static inline bool PXURLRouteCurrent(const PXURLRouteState *state, uint64_t token) {
    return state && token && state->token == token && !PXURLRouteTerminal(state->phase);
}
static inline bool PXURLRouteAdvance(PXURLRouteState *state, uint64_t token,
                                     PXURLRoutePhase from, PXURLRoutePhase to) {
    if (!PXURLRouteCurrent(state, token) || state->phase != from) return false;
    bool legal = (from == PXURLRouteNew && to == PXURLRouteChoosing) ||
                 (from == PXURLRouteChoosing && to == PXURLRouteStopping) ||
                 (from == PXURLRouteStopping && to == PXURLRouteSwitching) ||
                 (from == PXURLRouteSwitching && to == PXURLRouteVerifying);
    if (!legal) return false;
    state->phase = to;
    return true;
}
static inline bool PXURLRouteAbort(PXURLRouteState *state, uint64_t token, bool cancelled) {
    if (!PXURLRouteCurrent(state, token)) return false;
    state->phase = cancelled ? PXURLRouteCancelled : PXURLRouteFailed;
    return true;
}
static inline bool PXURLRouteMayForward(PXURLRouteState *state, uint64_t token,
                                        bool selected, bool containerMatches,
                                        bool processStateKnown, bool oldProcessExited) {
    if (!PXURLRouteCurrent(state, token) || state->phase != PXURLRouteVerifying ||
        !selected || !containerMatches || !processStateKnown || !oldProcessExited) return false;
    state->phase = PXURLRouteForwarded;
    return true;
}
static inline bool PXURLRouteHost(const char *host, const char *suffix) {
    if (!host || !suffix) return false;
    size_t h = strlen(host), s = strlen(suffix);
    if (h < s || strcmp(host + h - s, suffix)) return false;
    return h == s || host[h - s - 1] == '.';
}
static inline bool PXURLRouteWord(const char *text, const char *word) {
    if (!text || !word || !word[0]) return false;
    size_t n = strlen(word);
    const char *found = text;
    while ((found = strstr(found, word))) {
        bool left = found == text || found[-1] == '/' || found[-1] == '_' || found[-1] == '-' || found[-1] == '.';
        char after = found[n];
        bool right = !after || after == '/' || after == '_' || after == '-' || after == '.';
        if (left && right) return true;
        found += n;
    }
    return false;
}
static inline bool PXURLRoutePayment(const char *scheme, const char *host,
                                     const char *path, const char *action) {
    if (!scheme || !host || !path) return false;
    bool web = !strcmp(scheme, "https") || !strcmp(scheme, "http");
    bool wechat = !strcmp(scheme, "weixin") || !strcmp(scheme, "wechat");
    bool alipay = !strcmp(scheme, "alipay") || !strcmp(scheme, "alipays") ||
                  !strcmp(scheme, "alipayqr") || !strcmp(scheme, "alipayobject");
    bool qq = !strcmp(scheme, "mqqapi") || !strcmp(scheme, "mqqwallet");
    bool dedicated = !strcmp(scheme, "wxpay") || !strcmp(scheme, "tenpay") ||
                     !strcmp(scheme, "uppay") || !strcmp(scheme, "upwallet") ||
                     !strcmp(scheme, "unionpay");
    bool trustedWeb = web && (PXURLRouteHost(host, "wechat.com") ||
        PXURLRouteHost(host, "weixin.qq.com") || PXURLRouteHost(host, "tenpay.com") ||
        PXURLRouteHost(host, "alipay.com") || PXURLRouteHost(host, "alipayobjects.com") ||
        PXURLRouteHost(host, "95516.com") || PXURLRouteHost(host, "unionpay.com"));
    if (!(wechat || alipay || qq || dedicated || trustedWeb)) return false;
    // A return/source URL or a provider's name in arbitrary text is not proof.
    bool marker = PXURLRouteWord(path, "pay") || PXURLRouteWord(path, "wappay") ||
        PXURLRouteWord(path, "prepay") || PXURLRouteWord(path, "cashier") ||
        PXURLRouteWord(path, "checkmweb") || PXURLRouteWord(path, "mmpayweb");
    bool verb = action && (!strcmp(action, "pay") || !strcmp(action, "prepay") ||
        !strcmp(action, "cashier") || !strcmp(action, "alipay.wap.create.direct.pay") ||
        !strcmp(action, "alipay.trade.wap.pay") || !strcmp(action, "alipay.trade.app.pay"));
    // For custom schemes the host is a routing component (weixin://pay/...).
    bool hostVerb = !web && (!strcmp(host, "pay") || !strcmp(host, "cashier") || !strcmp(host, "prepay"));
    return marker || verb || hostVerb;
}
