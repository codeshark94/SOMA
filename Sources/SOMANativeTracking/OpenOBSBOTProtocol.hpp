#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace soma {

enum class OBSBOTOpenDeviceProfile {
    tiny2Lite,
    tiny3Lite,
};

struct OpenOBSBOTDeviceIdentity {
    OBSBOTOpenDeviceProfile profile;
    uint16_t productID;
    std::string serial;
};

struct OpenOBSBOTFramedCommand {
    uint16_t command;
    uint8_t receiver;
    std::vector<uint8_t> payload;
};

namespace open_obsbot_protocol {

constexpr uint16_t vendorID = 0x3564;

constexpr uint16_t productID(OBSBOTOpenDeviceProfile profile) noexcept {
    switch (profile) {
    case OBSBOTOpenDeviceProfile::tiny2Lite: return 0xFEF9;
    case OBSBOTOpenDeviceProfile::tiny3Lite: return 0xFF04;
    }
    return 0;
}

inline bool isRestPose(double pitchDegrees) noexcept {
    return std::isfinite(pitchDegrees) && std::abs(pitchDegrees) >= 70.0;
}

inline bool isRunPose(double pitchDegrees) noexcept {
    return std::isfinite(pitchDegrees) && std::abs(pitchDegrees) <= 2.5;
}

inline void appendI16LE(std::vector<uint8_t> &payload, int16_t value) {
    const uint16_t bits = static_cast<uint16_t>(value);
    payload.push_back(static_cast<uint8_t>(bits & 0xFF));
    payload.push_back(static_cast<uint8_t>((bits >> 8) & 0xFF));
}

inline void appendU32LE(std::vector<uint8_t> &payload, uint32_t value) {
    payload.push_back(static_cast<uint8_t>(value & 0xFF));
    payload.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    payload.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    payload.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
}

inline void appendFloatLE(std::vector<uint8_t> &payload, float value) {
    static_assert(sizeof(float) == sizeof(uint32_t));
    uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    appendU32LE(payload, bits);
}

inline std::optional<OpenOBSBOTFramedCommand> externalVelocity(
    OBSBOTOpenDeviceProfile profile,
    float pitch,
    float pan
) {
    if (!std::isfinite(pitch) || !std::isfinite(pan)) return std::nullopt;
    if (profile == OBSBOTOpenDeviceProfile::tiny3Lite) {
        const auto scaled = [](float value) {
            return static_cast<int16_t>(std::lround(
                std::clamp(value, -327.67f, 327.67f) * 100.0f
            ));
        };
        std::vector<uint8_t> payload;
        payload.reserve(6);
        appendI16LE(payload, 0);
        appendI16LE(payload, scaled(pitch));
        appendI16LE(payload, scaled(pan));
        return OpenOBSBOTFramedCommand {0x0103, 0x03, std::move(payload)};
    }
    std::vector<uint8_t> payload;
    payload.reserve(12);
    appendFloatLE(payload, 0);
    appendFloatLE(payload, pitch);
    // Tiny 2's raw yaw-speed sign is opposite its UVC attitude axis.
    appendFloatLE(payload, -pan);
    return OpenOBSBOTFramedCommand {0x6484, 0x04, std::move(payload)};
}

inline OpenOBSBOTFramedCommand wakeState(
    OBSBOTOpenDeviceProfile profile,
    bool awake
) {
    std::vector<uint8_t> payload;
    if (profile == OBSBOTOpenDeviceProfile::tiny3Lite) {
        payload.reserve(4);
        appendU32LE(payload, awake ? 0u : 1u);
    } else {
        payload.push_back(awake ? 0 : 1);
    }
    return OpenOBSBOTFramedCommand {0xA0C2, 0x02, std::move(payload)};
}

inline std::optional<OpenOBSBOTFramedCommand> firmwareRecenter(
    OBSBOTOpenDeviceProfile profile
) {
    if (profile != OBSBOTOpenDeviceProfile::tiny3Lite) return std::nullopt;
    return OpenOBSBOTFramedCommand {0x00C3, 0x03, std::vector<uint8_t>(6)};
}

inline std::array<uint8_t, 60> trackingModeControl(
    uint8_t mode,
    uint8_t submode = 0
) {
    std::array<uint8_t, 60> control {};
    control[0] = 0x16;
    control[1] = 0x02;
    control[2] = mode;
    control[3] = submode;
    return control;
}

inline std::optional<OpenOBSBOTFramedCommand> selectHumanTarget(
    OBSBOTOpenDeviceProfile profile,
    float x,
    float y,
    float width,
    float height
) {
    if (profile != OBSBOTOpenDeviceProfile::tiny3Lite
        || !std::isfinite(x) || !std::isfinite(y)
        || !std::isfinite(width) || !std::isfinite(height)
        || x < 0 || y < 0 || width <= 0 || height <= 0
        || x + width > 1 || y + height > 1) {
        return std::nullopt;
    }
    std::vector<uint8_t> payload;
    payload.reserve(24);
    appendI16LE(payload, 3);
    appendI16LE(payload, 0);
    appendI16LE(payload, 99);
    appendI16LE(payload, -2);
    const std::array<float, 4> bounds {x, y, x + width, y + height};
    for (const float bound : bounds) appendFloatLE(payload, bound);
    return OpenOBSBOTFramedCommand {0x0684, 0x04, std::move(payload)};
}

inline OpenOBSBOTFramedCommand clearTiny3HumanTarget() {
    std::vector<uint8_t> payload;
    payload.reserve(24);
    appendI16LE(payload, -1);
    appendI16LE(payload, -1);
    appendI16LE(payload, -1);
    appendI16LE(payload, -2);
    payload.resize(24, 0);
    return OpenOBSBOTFramedCommand {0x0684, 0x04, std::move(payload)};
}

} // namespace open_obsbot_protocol
} // namespace soma
