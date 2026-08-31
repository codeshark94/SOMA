#pragma once

#include "OpenOBSBOTUVCTransport.hpp"

#include <cmath>
#include <cstddef>
#include <optional>
#include <string>
#include <vector>

namespace soma {

struct OpenOBSBOTNativeTarget {
    float x;
    float y;
    float width;
    float height;
};

enum class OpenOBSBOTNativeStartError {
    none,
    invalidFieldCount,
    invalidNumber,
    invalidNormalizedBounds,
};

struct OpenOBSBOTNativeStartRequest {
    OpenOBSBOTNativeStartError error = OpenOBSBOTNativeStartError::none;
    std::optional<OpenOBSBOTNativeTarget> target;

    bool accepted() const noexcept {
        return error == OpenOBSBOTNativeStartError::none;
    }
};

inline bool openOBSBOTValidNormalizedTarget(
    const OpenOBSBOTNativeTarget &target
) noexcept {
    return std::isfinite(target.x) && std::isfinite(target.y)
        && std::isfinite(target.width) && std::isfinite(target.height)
        && target.x >= 0 && target.y >= 0
        && target.width > 0 && target.height > 0
        && target.x + target.width <= 1
        && target.y + target.height <= 1;
}

inline bool openOBSBOTParseFloat(const std::string &field, float &value) noexcept {
    try {
        size_t consumed = 0;
        value = std::stof(field, &consumed);
        return consumed == field.size() && std::isfinite(value);
    } catch (...) {
        return false;
    }
}

inline OpenOBSBOTNativeStartRequest openOBSBOTNativeStartRequest(
    OBSBOTOpenDeviceProfile profile,
    const std::vector<std::string> &fields
) noexcept {
    if (fields.size() == 2) return {};
    if (fields.size() != 6) {
        return {OpenOBSBOTNativeStartError::invalidFieldCount, std::nullopt};
    }

    OpenOBSBOTNativeTarget target {};
    if (!openOBSBOTParseFloat(fields[2], target.x)
        || !openOBSBOTParseFloat(fields[3], target.y)
        || !openOBSBOTParseFloat(fields[4], target.width)
        || !openOBSBOTParseFloat(fields[5], target.height)) {
        return {OpenOBSBOTNativeStartError::invalidNumber, std::nullopt};
    }
    if (!openOBSBOTValidNormalizedTarget(target)) {
        return {OpenOBSBOTNativeStartError::invalidNormalizedBounds, std::nullopt};
    }

    // Target selection is a Tiny 3 transport capability. Tiny 2 still accepts
    // the semantic target and maps it to its device-wide native human tracker.
    return {
        OpenOBSBOTNativeStartError::none,
        profile == OBSBOTOpenDeviceProfile::tiny3Lite
            ? std::optional<OpenOBSBOTNativeTarget>(target)
            : std::nullopt,
    };
}

inline const char *openOBSBOTNativeStartErrorID(
    OpenOBSBOTNativeStartError error
) noexcept {
    switch (error) {
    case OpenOBSBOTNativeStartError::none: return "none";
    case OpenOBSBOTNativeStartError::invalidFieldCount: return "invalid_field_count";
    case OpenOBSBOTNativeStartError::invalidNumber: return "invalid_number";
    case OpenOBSBOTNativeStartError::invalidNormalizedBounds:
        return "invalid_normalized_bounds";
    }
    return "unknown";
}

} // namespace soma
