#ifndef VPHONE_FOLD_DISPLAY_SURFACE_SAMPLES_H
#define VPHONE_FOLD_DISPLAY_SURFACE_SAMPLES_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    bool valid;
    uint8_t maxRGB, minAlpha, maxAlpha;
    unsigned count;
} VPhoneFoldSurfaceSamples;

// Diagnostic grid only; this does not classify pixels between the 64 points.
static inline VPhoneFoldSurfaceSamples vpFoldSampleBGRA(const uint8_t *base, size_t width,
                                                       size_t height, size_t stride, size_t bytes) {
    VPhoneFoldSurfaceSamples result = {0};
    if (!base || !width || !height || width > SIZE_MAX / 4 || stride < width * 4 ||
        stride > bytes / height) return result;
    result.valid = true;
    result.minAlpha = 255;
    for (size_t y = 0; y < 8; y++) {
        // Avoid multiplying the full dimension by up to 15 before division.
        size_t row = (height / 16) * (2 * y + 1) + (height % 16) * (2 * y + 1) / 16;
        for (size_t x = 0; x < 8; x++) {
            size_t column = (width / 16) * (2 * x + 1) + (width % 16) * (2 * x + 1) / 16;
            const uint8_t *pixel = base + row * stride + column * 4;
            for (size_t channel = 0; channel < 3; channel++)
                if (pixel[channel] > result.maxRGB) result.maxRGB = pixel[channel];
            if (pixel[3] < result.minAlpha) result.minAlpha = pixel[3];
            if (pixel[3] > result.maxAlpha) result.maxAlpha = pixel[3];
            result.count++;
        }
    }
    return result;
}

#endif
