#include "../Common/PXCloneURLPolicy.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr, "failed line %d\n", __LINE__); return 1; } } while (0)

int main(void) {
    CHECK(PXURLRoutePayment("https", "help.wechat.com", "/app/wxa1/pay/order", ""));
    CHECK(PXURLRoutePayment("https", "wx.tenpay.com", "/cgi-bin/mmpayweb-bin/checkmweb", ""));
    CHECK(PXURLRoutePayment("weixin", "wap", "/pay", ""));
    CHECK(PXURLRoutePayment("alipay", "platformapi", "/alipay.wap.create.direct.pay", ""));
    CHECK(PXURLRoutePayment("alipays", "platformapi", "/startapp", "alipay.trade.wap.pay"));
    CHECK(PXURLRoutePayment("unionpay", "pay", "/checkout", ""));
    CHECK(!PXURLRoutePayment("https", "help.wechat.com", "/profile/overview", ""));
    CHECK(!PXURLRoutePayment("https", "wechat.com.attacker.invalid", "/pay/order", ""));
    CHECK(!PXURLRoutePayment("https", "example.invalid", "/pay/order", ""));
    CHECK(!PXURLRoutePayment("https", "help.wechat.com", "/repayment/history", ""));
    CHECK(!PXURLRoutePayment("https", "help.wechat.com", "/app", ""));
    CHECK(!PXURLRoutePayment("alipays", "platformapi", "/startapp", ""));
    CHECK(!PXURLRoutePayment("https", "wechat.com", "/done", "returnURL=https://alipay.com/cashier"));
    CHECK(!PXURLRoutePayment("https", "x.wechat.com", "/xpaymaster", ""));
    CHECK(!PXURLRouteHost("wechat.com.attacker.invalid", "wechat.com"));
    CHECK(PXURLRouteHost("pay.wechat.com", "wechat.com"));

    for (uint64_t token = 1; token < 20000; token++) {
        PXURLRouteState s = {token, PXURLRouteNew};
        CHECK(PXURLRouteAdvance(&s, token, PXURLRouteNew, PXURLRouteChoosing));
        CHECK(!PXURLRouteMayForward(&s, token, true, true, true, true));
        CHECK(PXURLRouteAdvance(&s, token, PXURLRouteChoosing, PXURLRouteStopping));
        CHECK(PXURLRouteAdvance(&s, token, PXURLRouteStopping, PXURLRouteSwitching));
        CHECK(PXURLRouteAdvance(&s, token, PXURLRouteSwitching, PXURLRouteVerifying));
        PXURLRouteState stale = s;
        stale.token++;
        CHECK(!PXURLRouteMayForward(&stale, token, true, true, true, true));
        CHECK(!PXURLRouteMayForward(&s, token, false, true, true, true));
        PXURLRouteState mismatch = s;
        CHECK(!PXURLRouteMayForward(&mismatch, token, true, false, true, true));
        PXURLRouteState unknownProcess = s;
        CHECK(!PXURLRouteMayForward(&unknownProcess, token, true, true, false, true));
        PXURLRouteState stillRunning = s;
        CHECK(!PXURLRouteMayForward(&stillRunning, token, true, true, true, false));
        PXURLRouteState ok = s;
        CHECK(PXURLRouteMayForward(&ok, token, true, true, true, true));
        CHECK(ok.phase == PXURLRouteForwarded);
        CHECK(!PXURLRouteMayForward(&ok, token, true, true, true, true));
        PXURLRouteState cancel = {token, PXURLRouteChoosing};
        CHECK(PXURLRouteAbort(&cancel, token, true));
        CHECK(cancel.phase == PXURLRouteCancelled);
        CHECK(!PXURLRouteMayForward(&cancel, token, true, true, true, true));
        PXURLRouteState timeout = {token, PXURLRouteStopping};
        CHECK(PXURLRouteAbort(&timeout, token, false));
        CHECK(timeout.phase == PXURLRouteFailed);
    }
    printf("payment_route_policy_checks=%u\n", checks);
    return 0;
}
