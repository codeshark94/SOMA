#pragma once

#include "OBSBOTDeviceAdapter.hpp"

namespace soma {

inline bool supportsNativeBridge(ObsbotProductType type) noexcept {
    return obsbotDeviceAdapter(type).contract().nativeBridge;
}

} // namespace soma
