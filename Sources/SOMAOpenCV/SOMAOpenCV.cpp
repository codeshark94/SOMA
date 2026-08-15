#include "SOMAOpenCV.h"

#include <chrono>
#include <cmath>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/stitching/detail/blenders.hpp>
#include <opencv2/stitching/detail/exposure_compensate.hpp>

SOMAPhotometricBlendResult soma_photometric_feather_rgba(
    uint8_t *panorama_rgba,
    float *panorama_quality,
    const uint8_t *incoming_rgba,
    const float *incoming_quality,
    const int32_t width,
    const int32_t height
) {
    const auto started = std::chrono::steady_clock::now();
    const auto result = [&](int success, int compensated, int overlap,
                            float red, float green, float blue) {
        const auto elapsed = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started
        ).count();
        return SOMAPhotometricBlendResult{
            success, compensated, overlap, red, green, blue, elapsed
        };
    };
    if (panorama_rgba == nullptr || panorama_quality == nullptr
        || incoming_rgba == nullptr || incoming_quality == nullptr
        || width < 1 || height < 1) {
        return result(0, 0, 0, 1, 1, 1);
    }

    try {
        const int pixel_count = width * height;
        cv::Mat existing_mask(height, width, CV_8UC1, cv::Scalar(0));
        cv::Mat incoming_mask(height, width, CV_8UC1, cv::Scalar(0));
        int overlap = 0;
        for (int index = 0; index < pixel_count; ++index) {
            const bool has_existing = std::isfinite(panorama_quality[index])
                && panorama_quality[index] > 0;
            const bool has_incoming = std::isfinite(incoming_quality[index])
                && incoming_quality[index] > 0;
            existing_mask.data[index] = has_existing ? 255 : 0;
            incoming_mask.data[index] = has_incoming ? 255 : 0;
            if (has_existing && has_incoming) ++overlap;
        }

        cv::Mat existing_rgba(height, width, CV_8UC4, panorama_rgba);
        cv::Mat incoming_rgba_mat(
            height,
            width,
            CV_8UC4,
            const_cast<uint8_t *>(incoming_rgba)
        );
        cv::Mat existing_bgr;
        cv::Mat incoming_bgr;
        cv::cvtColor(existing_rgba, existing_bgr, cv::COLOR_RGBA2BGR);
        cv::cvtColor(incoming_rgba_mat, incoming_bgr, cv::COLOR_RGBA2BGR);

        float blue_gain = 1;
        float green_gain = 1;
        float red_gain = 1;
        int exposure_compensated = 0;
        if (overlap >= 512) {
            cv::detail::ChannelsCompensator compensator(1);
            compensator.setSimilarityThreshold(0.35);
            const std::vector<cv::Point> corners{{0, 0}, {0, 0}};
            const std::vector<cv::UMat> images{
                existing_bgr.getUMat(cv::ACCESS_READ),
                incoming_bgr.getUMat(cv::ACCESS_READ),
            };
            const std::vector<std::pair<cv::UMat, uchar>> masks{
                {existing_mask.getUMat(cv::ACCESS_READ), 255},
                {incoming_mask.getUMat(cv::ACCESS_READ), 255},
            };
            compensator.feed(corners, images, masks);
            const auto gains = compensator.gains();
            if (gains.size() == 2) {
                const auto relative_gain = [&](int channel) {
                    const double denominator = gains[0][channel];
                    if (!std::isfinite(denominator) || std::abs(denominator) < 1e-6
                        || !std::isfinite(gains[1][channel])) {
                        return 1.0F;
                    }
                    return static_cast<float>(std::min(
                        1.5,
                        std::max(0.67, gains[1][channel] / denominator)
                    ));
                };
                blue_gain = relative_gain(0);
                green_gain = relative_gain(1);
                red_gain = relative_gain(2);
                exposure_compensated = 1;
            }
        }

        cv::Mat feather_weights;
        cv::detail::createWeightMap(incoming_mask, 0.04F, feather_weights);
        for (int index = 0; index < pixel_count; ++index) {
            const float incoming_q = incoming_quality[index];
            if (!std::isfinite(incoming_q) || incoming_q <= 0) continue;
            const int pixel_offset = index * 4;
            const auto compensated_channel = [&](int channel, float gain) {
                return static_cast<float>(std::min(
                    255.0,
                    std::max(0.0, static_cast<double>(incoming_rgba[pixel_offset + channel]) * gain)
                ));
            };
            const float incoming_red = compensated_channel(0, red_gain);
            const float incoming_green = compensated_channel(1, green_gain);
            const float incoming_blue = compensated_channel(2, blue_gain);
            const bool has_existing = std::isfinite(panorama_quality[index])
                && panorama_quality[index] > 0;
            if (!has_existing) {
                panorama_rgba[pixel_offset] = static_cast<uint8_t>(std::lround(incoming_red));
                panorama_rgba[pixel_offset + 1] = static_cast<uint8_t>(std::lround(incoming_green));
                panorama_rgba[pixel_offset + 2] = static_cast<uint8_t>(std::lround(incoming_blue));
                panorama_rgba[pixel_offset + 3] = 255;
                panorama_quality[index] = incoming_q;
                continue;
            }
            const float alpha = std::min(
                1.0F,
                std::max(
                    0.0F,
                    feather_weights.ptr<float>(index / width)[index % width]
                )
            );
            const auto blend_channel = [&](int channel, float incoming_value) {
                const float existing_value = panorama_rgba[pixel_offset + channel];
                return static_cast<uint8_t>(std::lround(
                    existing_value * (1 - alpha) + incoming_value * alpha
                ));
            };
            panorama_rgba[pixel_offset] = blend_channel(0, incoming_red);
            panorama_rgba[pixel_offset + 1] = blend_channel(1, incoming_green);
            panorama_rgba[pixel_offset + 2] = blend_channel(2, incoming_blue);
            panorama_rgba[pixel_offset + 3] = 255;
            panorama_quality[index] = std::max(
                panorama_quality[index],
                incoming_q * alpha
            );
        }
        return result(
            1,
            exposure_compensated,
            overlap,
            red_gain,
            green_gain,
            blue_gain
        );
    } catch (const cv::Exception &) {
        return result(0, 0, 0, 1, 1, 1);
    } catch (...) {
        return result(0, 0, 0, 1, 1, 1);
    }
}
