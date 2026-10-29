#ifndef PO_FAN_LAYOUT_H
#define PO_FAN_LAYOUT_H
/* Pure C geometry, shared by the UIKit menu and host regression tests.
 * No icon rescaling: a crowded page becomes another page, not overlapping tiles.
 */
#include <math.h>
#include <string.h>
#define PO_FAN_LIMIT 40
#define PO_FAN_PI 3.14159265358979323846

typedef struct { double x, y, angle, radius; int ring; } POFanPoint;
typedef struct {
    int count, rings;
    double side, reserve, minX, minY, maxX, maxY;
    POFanPoint points[PO_FAN_LIMIT];
} POFanLayout;

static inline double POFanClamp(double v, double lo, double hi) {
    return fmax(lo, fmin(hi, v));
}
static inline int POFanSeparated(POFanPoint a, POFanPoint b, double distance) {
    /* Axis-aligned tile footprints: no square-icon corner overlap. */
    return fabs(a.x - b.x) + 0.0001 >= distance ||
           fabs(a.y - b.y) + 0.0001 >= distance;
}

static inline POFanLayout POFanBuild(double minX, double minY, double maxX, double maxY,
                                    double anchorX, double anchorY, int expandsRight,
                                    double requestedRadius, double spanDegrees,
                                    double side, double spacing, double ringGap,
                                    const int inputCaps[4]) {
    POFanLayout out;
    memset(&out, 0, sizeof(out));
    if (!isfinite(minX) || !isfinite(minY) || !isfinite(maxX) || !isfinite(maxY) ||
        !isfinite(anchorX) || !isfinite(anchorY) || !isfinite(requestedRadius) ||
        !isfinite(spanDegrees) || !isfinite(side) || !isfinite(spacing) || !isfinite(ringGap) ||
        !inputCaps || side <= 0 || maxX <= minX || maxY <= minY)
        return out;
    out.side = side;
    /* Reserve the selected 1.38 scale and 12pt outward lift at screen edges. */
    out.reserve = side * 1.38 / 2.0 + 12.0;
    double xLo = minX + out.reserve, xHi = maxX - out.reserve;
    double yLo = minY + out.reserve, yHi = maxY - out.reserve;
    if (xLo >= xHi || yLo >= yHi) return out;
    double inward = expandsRight ? 1.0 : -1.0;
    double room = expandsRight ? xHi - anchorX : anchorX - xLo;
    /* Requested radius still moves the first ring outward, but only by half its
     * value so inner space is not wasted and big icons keep their rings. */
    double radiusLimit = room;
    double inner = fmax(fmax(side * 1.38, 64.0), requestedRadius * 0.5);
    if (inner > radiusLimit) inner = radiusLimit;
    if (inner < side * 0.75) return out;
    double pitch = side * 1.28 + fmax(spacing, 0.0) + fmax(ringGap, 0.0);
    double desiredSpan = POFanClamp(spanDegrees, 10.0, 180.0) * PO_FAN_PI / 180.0;
    double separation = side * 1.20 + fmax(spacing, 0.0);
    int caps[4], capSum = 0;
    for (int r = 0; r < 4; r++) { caps[r] = inputCaps[r] > 0 ? inputCaps[r] : 0; capSum += caps[r]; }
    if (capSum == 0) { caps[0] = 7; caps[1] = 10; caps[2] = 13; caps[3] = 16; }
    out.minX = out.maxX = anchorX;
    out.minY = out.maxY = anchorY;
    for (int ring = 0; ring < 4 && out.count < PO_FAN_LIMIT; ring++) {
        double radius = inner + ring * pitch;
        if (radius > radiusLimit + 0.0001) break;
        if (!caps[ring]) continue;
        /* Near-edge clearance constrains |theta|. RadiusLimit handles the far edge. */
        double nearGap = expandsRight ? xLo - anchorX : anchorX - xHi;
        double angleLimit = nearGap > 0 ? acos(POFanClamp(nearGap / radius, 0.0, 1.0)) : PO_FAN_PI / 2.0;
        if (nearGap > radius) continue;
        double lo = fmax(-angleLimit, asin(POFanClamp((yLo - anchorY) / radius, -1.0, 1.0)));
        double hi = fmin(angleLimit, asin(POFanClamp((yHi - anchorY) / radius, -1.0, 1.0)));
        if (lo > hi) continue;
        double span = fmin(desiredSpan, hi - lo);
        int desired = caps[ring];
        if (desired > PO_FAN_LIMIT - out.count) desired = PO_FAN_LIMIT - out.count;
        POFanPoint batch[PO_FAN_LIMIT];
        int accepted = 0;
        for (int n = desired; n >= 1 && !accepted; n--) {
            /* Uniform arc first, then smaller/shifted arcs for cross-ring clearance. */
            for (int scale = 0; scale < 4 && !accepted; scale++) {
                double usedSpan = span * (1.0 - scale * 0.15);
                double firstCenter = lo + usedSpan / 2.0;
                double lastCenter = hi - usedSpan / 2.0;
                for (int shift = 0; shift < 13 && !accepted; shift++) {
                    double midpoint = shift == 0 ? POFanClamp(0.0, firstCenter, lastCenter)
                        : firstCenter + (lastCenter - firstCenter) * (shift - 1) / 11.0;
                    double start = midpoint - usedSpan / 2.0;
                    int ok = 1;
                    for (int j = 0; j < n && ok; j++) {
                        double theta = n == 1 ? midpoint : start + usedSpan * j / (n - 1);
                        POFanPoint p = {anchorX + inward * cos(theta) * radius,
                                       anchorY + sin(theta) * radius,
                                       expandsRight ? theta : PO_FAN_PI - theta, radius, ring};
                        if (p.x < xLo - 0.0001 || p.x > xHi + 0.0001 || p.y < yLo - 0.0001 || p.y > yHi + 0.0001) { ok = 0; break; }
                        for (int k = 0; k < out.count && ok; k++) ok = POFanSeparated(p, out.points[k], separation);
                        for (int k = 0; k < j && ok; k++) ok = POFanSeparated(p, batch[k], separation);
                        batch[j] = p;
                    }
                    if (ok) accepted = n;
                }
            }
        }
        for (int j = 0; j < accepted; j++) {
            POFanPoint p = batch[j];
            out.points[out.count++] = p;
            out.minX = fmin(out.minX, p.x - out.reserve);
            out.maxX = fmax(out.maxX, p.x + out.reserve);
            out.minY = fmin(out.minY, p.y - out.reserve);
            out.maxY = fmax(out.maxY, p.y + out.reserve);
        }
        if (accepted) out.rings++;
    }
    return out;
}
#endif
