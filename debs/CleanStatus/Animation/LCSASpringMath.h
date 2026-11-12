// Local CleanStatus integration port: ba31k/ios26-27-anims v1.5.2.
// Upstream attribution: bazik1337 (@bazik1337), https://t.me/ba31k_tweaks
#pragma once
#include <math.h>

static inline double LCSASpringProgress(double t, double response) {
    if (t <= 0) return 0;
    double w = 2.0 * M_PI / response;
    return 1.0 - (1.0 + w * t) * exp(-w * t);
}

// Measured iPhone row timing, before mapping to the iOS 16 container.
static inline double LCSARowResponse(double response, double iconY, double height,
                                    int row, int opening) {
    double raw = fmax(-1.0, fmin(1.0, 2.0 * iconY / height - 1.0));
    double g = raw >= 0 ? raw : 0.75 * raw;
    double r = row / 2.0;
    double weight = g >= 0 ? sqrt(r) : 1.0 - sqrt(1.0 - r);
    return response * (1.0 + 0.5 * (opening ? g : -g) * (1.0 - 2.0 * weight));
}
