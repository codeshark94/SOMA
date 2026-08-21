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

typedef struct SOMALucasKanadeTranslationResult {
    int32_t success;
    int32_t tracked_points;
    float translation_x;
    float translation_y;
    float confidence;
    double elapsed_milliseconds;
} SOMALucasKanadeTranslationResult;

typedef struct SOMAJPEGDecodeResult {
    int32_t success;
    int32_t width;
    int32_t height;
    int32_t bytes_per_row;
} SOMAJPEGDecodeResult;

typedef struct SOMAJPEGEncodeResult {
    int32_t success;
    int32_t encoded_length;
} SOMAJPEGEncodeResult;

/// Applies CPU channel exposure estimation and quality-weighted seam blending
/// to a pre-warped RGBA observation. A zero incoming quality means no
/// observation.
SOMAPhotometricBlendResult soma_photometric_feather_rgba(
    uint8_t *panorama_rgba,
    float *panorama_quality,
    const uint8_t *incoming_rgba,
    const float *incoming_quality,
    int32_t width,
    int32_t height
);

/// Estimates current-minus-reference image translation from BGRA frames using
/// sparse Lucas-Kanade optical flow. All working images remain CPU-local.
SOMALucasKanadeTranslationResult soma_lucas_kanade_translation_bgra(
    const uint8_t *reference_bgra,
    int32_t reference_bytes_per_row,
    const uint8_t *current_bgra,
    int32_t current_bytes_per_row,
    int32_t width,
    int32_t height
);

/// Writes a four-channel CPU bitmap as an atomic JPEG. `input_is_bgra` is 1
/// for camera frames and 0 for RGBA panorama pixels.
int32_t soma_write_jpeg_4channel(
    const uint8_t *pixels,
    int32_t bytes_per_row,
    int32_t width,
    int32_t height,
    int32_t input_is_bgra,
    int32_t maximum_dimension,
    const char *destination_path
);

/// Decodes a JPEG into caller-owned BGRA memory. No capture surface or GPU
/// resource crosses this boundary.
SOMAJPEGDecodeResult soma_decode_jpeg_bgra(
    const uint8_t *jpeg_bytes,
    int32_t jpeg_length,
    uint8_t *destination_bgra,
    int32_t destination_capacity
);

/// Encodes a four-channel CPU bitmap into caller-owned JPEG storage. This
/// avoids routing high-rate current frames through a file or camera surface.
SOMAJPEGEncodeResult soma_encode_jpeg_4channel(
    const uint8_t *pixels,
    int32_t bytes_per_row,
    int32_t width,
    int32_t height,
    int32_t input_is_bgra,
    int32_t maximum_dimension,
    uint8_t *destination_jpeg,
    int32_t destination_capacity
);

#ifdef __cplusplus
}
#endif

#endif
