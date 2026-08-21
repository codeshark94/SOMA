#include "SOMAOpenCV.h"

#include <chrono>
#include <cmath>
#include <algorithm>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

#include <opencv2/core.hpp>
#include <opencv2/core/ocl.hpp>
#include <opencv2/features.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/video/tracking.hpp>

namespace {

void configure_cpu_only_opencv() {
    static std::once_flag once;
    std::call_once(once, [] {
        // This process already owns camera IOSurfaces through AVFoundation.
        // Panorama work must stay in ordinary CPU memory, even on OpenCV
        // builds that opportunistically enable an accelerator backend.
        cv::ocl::setUseOpenCL(false);
        cv::setNumThreads(1);
    });
}

SOMALucasKanadeTranslationResult optical_flow_result(
    int success,
    int tracked_points,
    float translation_x,
    float translation_y,
    float confidence,
    const std::chrono::steady_clock::time_point started
) {
    const auto elapsed = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - started
    ).count();
    return SOMALucasKanadeTranslationResult{
        success,
        tracked_points,
        translation_x,
        translation_y,
        confidence,
        elapsed,
    };
}

float median(std::vector<float> values) {
    if (values.empty()) return 0;
    const auto middle = values.begin() + static_cast<std::ptrdiff_t>(values.size() / 2);
    std::nth_element(values.begin(), middle, values.end());
    float result = *middle;
    if (values.size() % 2 == 0) {
        const auto lower = std::max_element(values.begin(), middle);
        result = (result + *lower) * 0.5F;
    }
    return result;
}

} // namespace

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
        configure_cpu_only_opencv();
        const int pixel_count = width * height;
        int overlap = 0;
        double existing_totals[3] = {0, 0, 0};
        double incoming_totals[3] = {0, 0, 0};
        for (int index = 0; index < pixel_count; ++index) {
            const bool has_existing = std::isfinite(panorama_quality[index])
                && panorama_quality[index] > 0;
            const bool has_incoming = std::isfinite(incoming_quality[index])
                && incoming_quality[index] > 0;
            if (has_existing && has_incoming) {
                ++overlap;
                const int pixel_offset = index * 4;
                for (int channel = 0; channel < 3; ++channel) {
                    existing_totals[channel] += panorama_rgba[pixel_offset + channel];
                    incoming_totals[channel] += incoming_rgba[pixel_offset + channel];
                }
            }
        }

        float blue_gain = 1;
        float green_gain = 1;
        float red_gain = 1;
        int exposure_compensated = 0;
        if (overlap >= 512) {
            const auto relative_gain = [&](int channel) {
                const double denominator = incoming_totals[channel];
                if (!std::isfinite(denominator) || denominator < 1e-6
                    || !std::isfinite(existing_totals[channel])) {
                    return 1.0F;
                }
                return static_cast<float>(std::min(
                    1.5,
                    std::max(0.67, existing_totals[channel] / denominator)
                ));
            };
            red_gain = relative_gain(0);
            green_gain = relative_gain(1);
            blue_gain = relative_gain(2);
            exposure_compensated = 1;
        }

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
            // Incoming quality already encodes the gnomonic view weight and
            // the strip's smooth edge falloff. Quality-normalized blending is
            // therefore a feather without creating a second OpenCV mask or
            // accelerator-backed temporary image.
            const float existing_q = std::max(0.0F, panorama_quality[index]);
            const float alpha = incoming_q / std::max(1e-6F, existing_q + incoming_q);
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

SOMALucasKanadeTranslationResult soma_lucas_kanade_translation_bgra(
    const uint8_t *reference_bgra,
    const int32_t reference_bytes_per_row,
    const uint8_t *current_bgra,
    const int32_t current_bytes_per_row,
    const int32_t width,
    const int32_t height
) {
    const auto started = std::chrono::steady_clock::now();
    if (reference_bgra == nullptr || current_bgra == nullptr
        || reference_bytes_per_row < width * 4 || current_bytes_per_row < width * 4
        || width < 32 || height < 32) {
        return optical_flow_result(0, 0, 0, 0, 0, started);
    }

    try {
        configure_cpu_only_opencv();
        const cv::Mat reference_bgra_mat(
            height, width, CV_8UC4, const_cast<uint8_t *>(reference_bgra), reference_bytes_per_row
        );
        const cv::Mat current_bgra_mat(
            height, width, CV_8UC4, const_cast<uint8_t *>(current_bgra), current_bytes_per_row
        );
        cv::Mat reference_gray;
        cv::Mat current_gray;
        cv::cvtColor(reference_bgra_mat, reference_gray, cv::COLOR_BGRA2GRAY);
        cv::cvtColor(current_bgra_mat, current_gray, cv::COLOR_BGRA2GRAY);

        std::vector<cv::Point2f> reference_points;
        cv::goodFeaturesToTrack(
            reference_gray,
            reference_points,
            160,
            0.015,
            8.0,
            cv::noArray(),
            7,
            false,
            0.04
        );
        if (reference_points.size() < 12) {
            return optical_flow_result(0, static_cast<int>(reference_points.size()), 0, 0, 0, started);
        }

        std::vector<cv::Point2f> current_points;
        std::vector<unsigned char> status;
        std::vector<float> errors;
        cv::calcOpticalFlowPyrLK(
            reference_gray,
            current_gray,
            reference_points,
            current_points,
            status,
            errors,
            cv::Size(21, 21),
            3,
            cv::TermCriteria(cv::TermCriteria::COUNT | cv::TermCriteria::EPS, 20, 0.03),
            0,
            1e-4
        );

        std::vector<float> horizontal;
        std::vector<float> vertical;
        horizontal.reserve(reference_points.size());
        vertical.reserve(reference_points.size());
        const float maximumDisplacement = static_cast<float>(std::max(width, height)) * 0.30F;
        for (size_t index = 0; index < reference_points.size(); ++index) {
            if (index >= status.size() || index >= errors.size() || index >= current_points.size()
                || status[index] == 0 || !std::isfinite(errors[index]) || errors[index] > 20) {
                continue;
            }
            const float dx = current_points[index].x - reference_points[index].x;
            const float dy = current_points[index].y - reference_points[index].y;
            if (!std::isfinite(dx) || !std::isfinite(dy)
                || std::abs(dx) > maximumDisplacement || std::abs(dy) > maximumDisplacement) {
                continue;
            }
            horizontal.push_back(dx);
            vertical.push_back(dy);
        }
        if (horizontal.size() < 12) {
            return optical_flow_result(0, static_cast<int>(horizontal.size()), 0, 0, 0, started);
        }
        const float initial_x = median(horizontal);
        const float initial_y = median(vertical);
        std::vector<float> inlier_horizontal;
        std::vector<float> inlier_vertical;
        inlier_horizontal.reserve(horizontal.size());
        inlier_vertical.reserve(vertical.size());
        for (size_t index = 0; index < horizontal.size(); ++index) {
            if (std::hypot(horizontal[index] - initial_x, vertical[index] - initial_y) <= 3.0F) {
                inlier_horizontal.push_back(horizontal[index]);
                inlier_vertical.push_back(vertical[index]);
            }
        }
        const int inlier_count = static_cast<int>(inlier_horizontal.size());
        if (inlier_count < 12) {
            return optical_flow_result(0, inlier_count, initial_x, initial_y, 0, started);
        }
        const float translation_x = median(inlier_horizontal);
        const float translation_y = median(inlier_vertical);
        const float support = std::min(1.0F, static_cast<float>(inlier_count) / 48.0F);
        const float coherence = static_cast<float>(inlier_count) / static_cast<float>(horizontal.size());
        const float confidence = support * coherence;
        if (confidence < 0.55F) {
            return optical_flow_result(
                0,
                inlier_count,
                translation_x,
                translation_y,
                confidence,
                started
            );
        }
        return optical_flow_result(
            1,
            inlier_count,
            translation_x,
            translation_y,
            confidence,
            started
        );
    } catch (const cv::Exception &) {
        return optical_flow_result(0, 0, 0, 0, 0, started);
    } catch (...) {
        return optical_flow_result(0, 0, 0, 0, 0, started);
    }
}

int32_t soma_write_jpeg_4channel(
    const uint8_t *pixels,
    const int32_t bytes_per_row,
    const int32_t width,
    const int32_t height,
    const int32_t input_is_bgra,
    const int32_t maximum_dimension,
    const char *destination_path
) {
    if (pixels == nullptr || destination_path == nullptr || bytes_per_row < width * 4
        || width < 1 || height < 1 || maximum_dimension < 0
        || (input_is_bgra != 0 && input_is_bgra != 1)) {
        return 0;
    }
    try {
        configure_cpu_only_opencv();
        const cv::Mat input(
            height,
            width,
            CV_8UC4,
            const_cast<uint8_t *>(pixels),
            bytes_per_row
        );
        cv::Mat bgr;
        cv::cvtColor(
            input,
            bgr,
            input_is_bgra == 1 ? cv::COLOR_BGRA2BGR : cv::COLOR_RGBA2BGR
        );
        if (maximum_dimension > 0 && std::max(bgr.cols, bgr.rows) > maximum_dimension) {
            const double scale = static_cast<double>(maximum_dimension)
                / static_cast<double>(std::max(bgr.cols, bgr.rows));
            cv::resize(
                bgr,
                bgr,
                cv::Size(),
                scale,
                scale,
                cv::INTER_AREA
            );
        }
        std::vector<unsigned char> encoded;
        if (!cv::imencode(
                ".jpg",
                bgr,
                encoded,
                {cv::IMWRITE_JPEG_QUALITY, 90}
            )) {
            return 0;
        }
        const std::string destination(destination_path);
        const std::string temporary = destination + ".soma-tmp";
        FILE *file = std::fopen(temporary.c_str(), "wb");
        if (file == nullptr) return 0;
        const size_t written = std::fwrite(encoded.data(), 1, encoded.size(), file);
        const int close_result = std::fclose(file);
        if (written != encoded.size() || close_result != 0) {
            std::remove(temporary.c_str());
            return 0;
        }
        if (std::rename(temporary.c_str(), destination.c_str()) != 0) {
            std::remove(temporary.c_str());
            return 0;
        }
        return 1;
    } catch (const cv::Exception &) {
        return 0;
    } catch (...) {
        return 0;
    }
}

SOMAJPEGEncodeResult soma_encode_jpeg_4channel(
    const uint8_t *pixels,
    const int32_t bytes_per_row,
    const int32_t width,
    const int32_t height,
    const int32_t input_is_bgra,
    const int32_t maximum_dimension,
    uint8_t *destination_jpeg,
    const int32_t destination_capacity
) {
    if (pixels == nullptr || destination_jpeg == nullptr
        || bytes_per_row < width * 4 || width < 1 || height < 1
        || maximum_dimension < 0 || destination_capacity < 1
        || (input_is_bgra != 0 && input_is_bgra != 1)) {
        return SOMAJPEGEncodeResult{0, 0};
    }
    try {
        configure_cpu_only_opencv();
        const cv::Mat input(
            height,
            width,
            CV_8UC4,
            const_cast<uint8_t *>(pixels),
            bytes_per_row
        );
        cv::Mat bgr;
        cv::cvtColor(
            input,
            bgr,
            input_is_bgra == 1 ? cv::COLOR_BGRA2BGR : cv::COLOR_RGBA2BGR
        );
        if (maximum_dimension > 0 && std::max(bgr.cols, bgr.rows) > maximum_dimension) {
            const double scale = static_cast<double>(maximum_dimension)
                / static_cast<double>(std::max(bgr.cols, bgr.rows));
            cv::resize(bgr, bgr, cv::Size(), scale, scale, cv::INTER_AREA);
        }
        std::vector<unsigned char> encoded;
        if (!cv::imencode(
                ".jpg",
                bgr,
                encoded,
                {cv::IMWRITE_JPEG_QUALITY, 90}
            ) || encoded.empty() || encoded.size() > static_cast<size_t>(destination_capacity)) {
            return SOMAJPEGEncodeResult{0, 0};
        }
        std::copy(encoded.begin(), encoded.end(), destination_jpeg);
        return SOMAJPEGEncodeResult{1, static_cast<int32_t>(encoded.size())};
    } catch (const cv::Exception &) {
        return SOMAJPEGEncodeResult{0, 0};
    } catch (...) {
        return SOMAJPEGEncodeResult{0, 0};
    }
}

SOMAJPEGDecodeResult soma_decode_jpeg_bgra(
    const uint8_t *jpeg_bytes,
    const int32_t jpeg_length,
    uint8_t *destination_bgra,
    const int32_t destination_capacity
) {
    if (jpeg_bytes == nullptr || destination_bgra == nullptr
        || jpeg_length < 1 || destination_capacity < 4) {
        return SOMAJPEGDecodeResult{0, 0, 0, 0};
    }
    try {
        configure_cpu_only_opencv();
        const cv::Mat encoded(1, jpeg_length, CV_8UC1, const_cast<uint8_t *>(jpeg_bytes));
        const cv::Mat decoded = cv::imdecode(encoded, cv::IMREAD_COLOR);
        if (decoded.empty() || decoded.cols < 1 || decoded.rows < 1) {
            return SOMAJPEGDecodeResult{0, 0, 0, 0};
        }
        const int bytes_per_row = decoded.cols * 4;
        const int required = bytes_per_row * decoded.rows;
        if (required > destination_capacity) {
            return SOMAJPEGDecodeResult{0, decoded.cols, decoded.rows, bytes_per_row};
        }
        cv::Mat destination(decoded.rows, decoded.cols, CV_8UC4, destination_bgra, bytes_per_row);
        cv::cvtColor(decoded, destination, cv::COLOR_BGR2BGRA);
        return SOMAJPEGDecodeResult{1, decoded.cols, decoded.rows, bytes_per_row};
    } catch (const cv::Exception &) {
        return SOMAJPEGDecodeResult{0, 0, 0, 0};
    } catch (...) {
        return SOMAJPEGDecodeResult{0, 0, 0, 0};
    }
}
