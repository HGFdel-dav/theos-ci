// Local CleanStatus integration port: ba31k/ios26-27-anims v1.5.2.
// Upstream attribution: bazik1337 (@bazik1337), https://t.me/ba31k_tweaks
#pragma once
#include "LCSANativeProfiles.h"
#include <math.h>

static inline void LCSASampleTrack(int track, double t, double xy[18]) {
    const LCSANativeFrame *frames = LCSATracks[track];
    size_t count = LCSATrackCounts[track];
    size_t right = 1;
    while (right < count - 1 && frames[right].t < t) right++;
    double p = fmax(0, fmin(1, (t - frames[right-1].t) / (frames[right].t - frames[right-1].t)));
    for (int i = 0; i < 18; i++) xy[i] = frames[right-1].xy[i] + p * (frames[right].xy[i] - frames[right-1].xy[i]);
}

// Native recordings cover the upper-left icon and left dock icon. Preserve their
// complete coupled deformation, interpolate vertically and reflect horizontally.
static inline void LCSANativeMesh(double t, int opening, double iconX, double iconY,
                                  double width, double height, double xy[18]) {
    double top[18], dock[18];
    LCSASampleTrack(opening ? 0 : 1, t, top);
    LCSASampleTrack(opening ? 2 : 3, t, dock);
    double vertical = fmax(0, fmin(1, (iconY / height - 118.0/932) / ((865.0-118)/932)));
    double horizontal = fmax(0, fmin(1, (iconX / width - 67.0/430) / (1 - 134.0/430)));
    for (int row = 0; row < 3; row++) {
        for (int col = 0; col < 3; col++) {
            int i = 2 * (row * 3 + col), mirror = 2 * (row * 3 + 2 - col);
            double x = top[i] + vertical * (dock[i] - top[i]);
            double reflected = 1 - (top[mirror] + vertical * (dock[mirror] - top[mirror]));
            xy[i] = x + horizontal * (reflected - x);
            xy[i+1] = top[i+1] + vertical * (dock[i+1] - top[i+1]);
        }
    }
}
