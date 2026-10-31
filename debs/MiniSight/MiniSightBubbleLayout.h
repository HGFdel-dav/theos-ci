// One content layout for both ordinary and approval bubbles. Pure C: tested
// without UIKit. The measured glyph height is never reduced by a second pass.
#ifndef MINISIGHT_BUBBLE_LAYOUT_H
#define MINISIGHT_BUBBLE_LAYOUT_H
#include "MiniSightGeometry.h"

typedef struct {
    MSSize size;
    MSRect text;
    MSRect buttons;
    MSRect expansion;
    double radius;
} MSBubbleContent;

static inline double MSBubbleTextWidth(double desired, double available, int approval) {
    const double horizontal = 12.0;
    double limit = fmax(1.0, MSFinite(available, 1.0) - horizontal * 2.0);
    double wanted = fmax(1.0, MSFinite(desired, limit));
    if (approval) wanted = fmax(wanted, 136.0); // two 64pt buttons + 8pt gap
    return fmin(limit, wanted);
}

static inline MSBubbleContent MSBubbleContentMake(double textWidth, double textHeight,
                                                   double availableWidth, int approval,
                                                   int expansion) {
    MSBubbleContent c;
    const double horizontal = 12.0, vertical = 8.0;
    double limit = fmax(1.0, MSFinite(availableWidth, 1.0));
    double minWidth = approval ? 160.0 : 44.0;
    double width = fmin(limit, fmax(minWidth, ceil(fmax(1., MSFinite(textWidth, 1.))) + 2. * horizontal));
    double th = ceil(fmax(1., MSFinite(textHeight, 1.)));
    double pad = fmin(horizontal, fmax(0., (width - 1.) * .5));
    c.text = (MSRect){pad, vertical, fmax(1., width - 2. * pad), th};
    double controlsY = vertical + th + 8.;
    c.expansion = approval && expansion ? (MSRect){pad, controlsY, c.text.w, 22.}
                                        : (MSRect){0., 0., 0., 0.};
    if (approval && expansion) controlsY += 28.;
    c.buttons = approval ? (MSRect){pad, controlsY, c.text.w, 44.}
                         : (MSRect){0., 0., 0., 0.};
    c.size = (MSSize){width, approval ? controlsY + 44. + vertical : th + 2. * vertical};
    c.radius = fmin(18., c.size.h * .5);
    return c;
}
#endif
