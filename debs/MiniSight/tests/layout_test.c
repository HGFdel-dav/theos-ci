// 宿主布局回归：随机尺寸/安全区/身体尺寸下，身体不越界、气泡只在头顶。
// 编译：cc -std=c11 -Wall -Wextra -O1 -o /tmp/layout_test tests/layout_test.c -lm
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "../MiniSightLayout.h"

static unsigned seed = 20261031u;
static double rnd(double lo, double hi) {
    seed = seed * 1103515245u + 12345u;
    double u = (double)((seed >> 8) & 0xFFFFFF) / (double)0x1000000;
    return lo + (hi - lo) * u;
}

static void fail(const char *what, MSLayout L, MSPoint a, MSRect b, long i) {
    printf("FAIL[%s] i=%ld screen-safe=(%.1f,%.1f,%.1f,%.1f) body=(%.1f,%.1f) "
           "anchor=(%.1f,%.1f) rect=(%.1f,%.1f,%.1f,%.1f)\n",
           what, i, L.safe.x, L.safe.y, L.safe.w, L.safe.h, L.body.w, L.body.h,
           a.x, a.y, b.x, b.y, b.w, b.h);
    exit(1);
}

int main(void) {
    long checks = 0;
    const double eps = 0.01;

    // 固定用例：0.3.2 记录里那个 390x844 / 56pt 宠物 / 窗口中心(130,230) 的越界算例
    {
        MSLayout L = MSLayoutMake(390, 844, 47, 34, 0, 0, 8, 56, 60.7, 7, 48);
        MSPoint a = MSLayoutClamp(L, (MSPoint){130, 230});
        MSRect body = MSLayoutBody(L, a);
        if (body.x < L.safe.x - eps || body.y < L.safe.y - eps ||
            body.x + body.w > L.safe.x + L.safe.w + eps ||
            body.y + body.h > L.safe.y + L.safe.h + eps) {
            fail("0.3.2 越界算例", L, a, body, 0);
        }
        checks++;
    }

    for (long i = 0; i < 400000; i++) {
        // 屏幕：竖屏/横屏、刘海/无刘海、极小屏都要覆盖
        int landscape = (seed & (1u << 3)) != 0;
        double w = landscape ? rnd(560, 932) : rnd(320, 440);
        double h = landscape ? rnd(320, 440) : rnd(568, 932);
        double top = rnd(0, 60), bottom = rnd(0, 40), left = rnd(0, 48), right = rnd(0, 48);
        double edge = rnd(0, 12);
        double bw = rnd(20, 160), bh = rnd(20, 180);
        double gap = rnd(0, 10), headroom = rnd(0, 200);

        MSLayout L = MSLayoutMake(w, h, top, bottom, left, right, edge, bw, bh, gap, headroom);

        // 任意（包括明显越界的）起点都要被夹回可用范围
        MSPoint want = (MSPoint){rnd(-400, w + 400), rnd(-400, h + 400)};
        MSPoint a = MSLayoutClamp(L, want);
        MSRect body = MSLayoutBody(L, a);

        // 不变量 1：身体完整落在 safe 内（除非身体本身比 safe 还大）
        if (bw <= L.safe.w + eps && (body.x < L.safe.x - eps || body.x + body.w > L.safe.x + L.safe.w + eps)) {
            fail("身体水平越界", L, a, body, i);
        }
        if (bh <= L.safe.h + eps && (body.y < L.safe.y - eps || body.y + body.h > L.safe.y + L.safe.h + eps)) {
            fail("身体垂直越界", L, a, body, i);
        }
        // 不变量 2：身体绝不跑出屏幕
        if (body.x < -eps || body.y < -eps || body.x + body.w > w + eps || body.y + body.h > h + eps) {
            fail("身体出屏", L, a, body, i);
        }

        // 不变量 3：气泡恒在身体正上方（永不翻到脚下）
        MSSize bubble = {rnd(60, 280), rnd(18, 130)};
        MSRect br = MSLayoutBubble(L, a, bubble);
        if (br.y + br.h > body.y - gap + eps) {
            fail("气泡不在头顶", L, a, br, i);
        }
        if (br.w > L.safe.w + eps || br.h > L.safe.h + eps) {
            fail("气泡超出可用区", L, a, br, i);
        }
        checks++;

        // 不变量 4：气泡让位后，身体仍合法，且气泡要么放得下要么贴住 safe 顶部
        MSPoint a2 = MSLayoutAnchorForBubble(L, a, bubble);
        MSRect body2 = MSLayoutBody(L, a2);
        if (body2.x < L.safe.x - eps || body2.x + body2.w > L.safe.x + L.safe.w + eps ||
            body2.y < L.safe.y - eps || body2.y + body2.h > L.safe.y + L.safe.h + eps) {
            fail("让位后身体越界", L, a2, body2, i);
        }
        MSRect br2 = MSLayoutBubble(L, a2, bubble);
        if (br2.y < L.safe.y - eps && br2.h + body2.h + gap + L.headroom <= L.safe.h + eps) {
            fail("本可放下的气泡仍在屏外", L, a2, br2, i);
        }
        checks++;

        // 不变量 5：跳跃顶点不越过上边界
        double jump = MSJumpHeight(L.centers, a, 26.0);
        if (a.y - jump < L.centers.y - eps) fail("跳跃越上边界", L, a, body, i);
        if (jump < -eps) fail("跳跃高度为负", L, a, body, i);
        checks += 2;
    }

    // 对照：旧实现（移动整屏 window + 只用 window.bounds 夹子视图）确实会越界
    {
        double winW = 390, winH = 844, pet = 56;
        // 窗口中心被拖到 (130,230) → 窗口原点 (-65,-192)
        double ox = 130 - winW / 2, oy = 230 - winH / 2;
        // 子视图在 56pt 宠物的局部坐标内“合法”落点
        double lx = 40, ly = 64.33;
        double screenX = ox + lx - pet / 2, screenY = oy + ly - pet / 2;
        if (!(screenX < 0 || screenY < 0)) {
            printf("FAIL 旧算法复现失败\n");
            return 1;
        }
        printf("旧算法复现：局部合法点映射到屏幕左上角 (%.1f, %.1f) → 越界\n", screenX, screenY);
    }

    printf("PASS：%ld 项布局不变量检查全部通过\n", checks);
    return 0;
}
