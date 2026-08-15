#ifndef SOMA_OPENCV_H
#define SOMA_OPENCV_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SOMAPhotometricBlendResult {
    int32_t success;
    int32_t exposure_compensated;
    int32_t overlap_pixels;
    float red_gain;
    float green_gain;
    float blue_gain;
    double elapsed_milliseconds;
} SOMAPhotometricBlendResult;

/// Applies OpenCV's channel exposure estimator and seam feather weights to a
/// pre-warped RGBA observation. A zero incoming quality means no observation.
SOMAPhotometricBlendResult soma_photometric_feather_rgba(
    uint8_t *panorama_rgba,
    float *panorama_quality,
    const uint8_t *incoming_rgba,
    const float *incoming_quality,
    int32_t width,
    int32_t height
);

#ifdef __cplusplus
}
#endif

#endif
