#include "OBSBOTDeviceAdapter.hpp"

#include <dlfcn.h>

namespace soma {
namespace {

class UnknownAdapter final : public OBSBOTDeviceAdapter {
public:
    OBSBOTDeviceProfile profile() const noexcept override {
        return OBSBOTDeviceProfile::unknown;
    }

    const OBSBOTDeviceContract &contract() const noexcept override {
        static const OBSBOTDeviceContract value {
            "unknown", false, false, false, false,
            false, false, 0, false,
            false, 0, false, false,
            -1, -1, -1, -1, 0, 0, 0,
            OBSBOTNativeTrackingTransport::unavailable,
        };
        return value;
    }

    int disableNativeTracking(Device *) const noexcept override { return RM_RET_ERR; }
    int stopNativeMotion(Device *) const noexcept override { return RM_RET_ERR; }
    int setExternalVelocity(Device *, float, float) const noexcept override { return RM_RET_ERR; }
    int center(Device *) const noexcept override { return RM_RET_ERR; }
};

class Tiny2LiteAdapter final : public OBSBOTDeviceAdapter {
public:
    OBSBOTDeviceProfile profile() const noexcept override {
        return OBSBOTDeviceProfile::tiny2Lite;
    }

    const OBSBOTDeviceContract &contract() const noexcept override {
        static const OBSBOTDeviceContract value {
            "tiny_2_lite", true, true, false, true,
            true, false, 0, true,
            false, 0, false, false,
            -1, 16, 57, 54, 180, 90, 67.2,
            OBSBOTNativeTrackingTransport::legacyHumanMode,
        };
        return value;
    }

    int disableNativeTracking(Device *device) const noexcept override {
        if (!device) return RM_RET_ERR;
        try { return device->cameraSetAiModeU(Device::AiWorkModeNone); }
        catch (...) { return RM_RET_ERR; }
    }

    int stopNativeMotion(Device *device) const noexcept override {
        if (!device) return RM_RET_ERR;
        try { return device->aiSetGimbalStop(); }
        catch (...) { return RM_RET_ERR; }
    }

    int setExternalVelocity(Device *device, float pitch, float pan) const noexcept override {
        if (!device) return RM_RET_ERR;
        try { return device->aiSetGimbalSpeedCtrlR(pitch, pan); }
        catch (...) { return RM_RET_ERR; }
    }

    int center(Device *device) const noexcept override {
        if (!device) return RM_RET_ERR;
        try { return device->gimbalSetSpeedPositionR(0, 0, 0, 0, 60, 90); }
        catch (...) { return RM_RET_ERR; }
    }
};

class Tiny3LiteAdapter final : public OBSBOTDeviceAdapter {
public:
    OBSBOTDeviceProfile profile() const noexcept override {
        return OBSBOTDeviceProfile::tiny3Lite;
    }

    const OBSBOTDeviceContract &contract() const noexcept override {
        // Rear audio mode is deliberately absent: the connected firmware
        // accepts its setter but does not retain the requested state.
        constexpr uint8_t audioModes = (1u << Device::AudioModeOmni)
            | (1u << Device::AudioModeStereo)
            | (1u << Device::AudioModeFront)
            | (1u << Device::AudioModeDipol)
            | (1u << Device::AudioModeMusic);
        static const OBSBOTDeviceContract value {
            "tiny_3_lite", true, false, true, true,
            true, false, 0, true,
            true, audioModes, true, true,
            3, 16, 54, 57, 90, 45, 72,
            OBSBOTNativeTrackingTransport::selectedHumanPortrait,
        };
        return value;
    }

    int setAudioMode(Device *device, uint8_t source, uint8_t mode) const noexcept override {
        if (!device || !supportsAudioMode(mode)) return RM_RET_ERR;
        using SetAudioMode = int32_t (*)(Device *, Device::AudioMode);
        const auto set = reinterpret_cast<SetAudioMode>(
            dlsym(RTLD_DEFAULT, "_ZN6Device19cameraSetAudioModeUENS_9AudioModeE")
        );
        if (!set) return RM_RET_ERR;
        try { return set(device, Device::AudioMode {source, mode}); }
        catch (...) { return RM_RET_ERR; }
    }

    int setAudioInputGain(Device *device, int16_t percent) const noexcept override {
        if (!device || percent < 0 || percent > 100) return RM_RET_ERR;
        using SetAudioVolume = int (*)(Device *, int16_t);
        const auto set = reinterpret_cast<SetAudioVolume>(
            dlsym(RTLD_DEFAULT, "_ZN6Device21cameraSetAudioVolumeREs")
        );
        if (!set) return RM_RET_ERR;
        try { return set(device, percent); }
        catch (...) { return RM_RET_ERR; }
    }

    int setSoundFollowing(Device *device, bool enabled) const noexcept override {
        if (!device) return RM_RET_ERR;
        using SetDoaFindBack = int (*)(Device *, uint8_t);
        const auto set = reinterpret_cast<SetDoaFindBack>(
            dlsym(RTLD_DEFAULT, "_ZN6Device20cameraSetDoaFindBackEh")
        );
        if (!set) return RM_RET_ERR;
        try { return set(device, enabled ? 1 : 0); }
        catch (...) { return RM_RET_ERR; }
    }

    int disableNativeTracking(Device *device) const noexcept override {
        if (!device) return RM_RET_ERR;
        try {
            Device::DevTargetSelection target {};
            target.selection_type = static_cast<int16_t>(Device::DevTargetSelectionTypeDelete);
            target.class_type = static_cast<int16_t>(Device::DevTargetClassTypeIgnored);
            target.zoom_type = static_cast<int16_t>(Device::DevTargetZoomTypeIgnored);
            target.view_type = static_cast<int16_t>(Device::DevTargetViewTypeIgnored);
            const int deleteResult = device->aiSetSelectedTargetR(target);
            const int modeResult = device->cameraSetAiModeU(Device::AiWorkModeNone, 0);
            return deleteResult == RM_RET_OK && modeResult == RM_RET_OK
                ? RM_RET_OK
                : RM_RET_ERR;
        } catch (...) { return RM_RET_ERR; }
    }

    int stopNativeMotion(Device *device) const noexcept override {
        if (!device) return RM_RET_ERR;
        try { return device->gimbalSpeedCtrlR(0, 0, 0); }
        catch (...) { return RM_RET_ERR; }
    }

    int setExternalVelocity(Device *device, float pitch, float pan) const noexcept override {
        if (!device) return RM_RET_ERR;
        try { return device->gimbalSpeedCtrlR(pitch, pan); }
        catch (...) { return RM_RET_ERR; }
    }

    int center(Device *device) const noexcept override {
        if (!device) return RM_RET_ERR;
        try { return device->gimbalRstPosR(); }
        catch (...) { return RM_RET_ERR; }
    }
};

} // namespace

bool OBSBOTDeviceAdapter::supportsIndicatorStateID(int stateID) const noexcept {
    const auto &value = contract();
    return stateID >= 0
        && (stateID == value.yellowIndicatorStateID
            || stateID == value.greenIndicatorStateID
            || stateID == value.blueIndicatorStateID);
}

bool OBSBOTDeviceAdapter::supportsIndicatorColor(OBSBOTIndicatorColor color) const noexcept {
    const auto bit = static_cast<uint8_t>(1u << static_cast<uint8_t>(color));
    return (contract().directIndicatorColorMask & bit) != 0;
}

bool OBSBOTDeviceAdapter::supportsAudioMode(int mode) const noexcept {
    const auto &value = contract();
    return value.selectableAudioModes && mode >= 0 && mode < 8
        && (value.supportedAudioModeMask & (1u << mode)) != 0;
}

int OBSBOTDeviceAdapter::setIndicatorState(Device *device, uint8_t stateID) const noexcept {
    if (!device || !contract().firmwareIndicatorPalette || !supportsIndicatorStateID(stateID)) {
        return RM_RET_ERR;
    }
    try {
        const auto &value = contract();
        const int presentationStates[] = {
            value.yellowIndicatorStateID,
            value.greenIndicatorStateID,
            value.blueIndicatorStateID,
        };
        bool cleared = true;
        for (const int otherStateID : presentationStates) {
            if (otherStateID < 0 || otherStateID == stateID) continue;
            if (device->sysMgClearIndicatorStateR(static_cast<uint8_t>(otherStateID)) != RM_RET_OK) {
                cleared = false;
            }
        }
        const int setResult = device->sysMgSetIndicatorStateR(stateID);
        return cleared && setResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR;
    } catch (...) { return RM_RET_ERR; }
}

int OBSBOTDeviceAdapter::clearIndicatorState(Device *device, uint8_t stateID) const noexcept {
    if (!device || !contract().firmwareIndicatorPalette || !supportsIndicatorStateID(stateID)) {
        return RM_RET_ERR;
    }
    try { return device->sysMgClearIndicatorStateR(stateID); }
    catch (...) { return RM_RET_ERR; }
}

int OBSBOTDeviceAdapter::establishIndicatorBaseline(Device *device) const noexcept {
    const auto &value = contract();
    if (!device || !value.firmwareIndicatorPalette || value.indicatorBaseStateID < 0) {
        return RM_RET_OK;
    }
    try {
        const int baseResult = device->sysMgSetIndicatorStateR(
            static_cast<uint8_t>(value.indicatorBaseStateID)
        );
        const int idleResult = value.greenIndicatorStateID >= 0
            ? setIndicatorState(device, static_cast<uint8_t>(value.greenIndicatorStateID))
            : RM_RET_OK;
        return baseResult == RM_RET_OK && idleResult == RM_RET_OK
            ? RM_RET_OK
            : RM_RET_ERR;
    } catch (...) { return RM_RET_ERR; }
}

int OBSBOTDeviceAdapter::getIndicatorEnabled(Device *device, bool &enabled) const noexcept {
    if (!device || !contract().indicatorEnableAndBrightness) return RM_RET_ERR;
    using Function = int (*)(Device *, bool &);
    const auto function = reinterpret_cast<Function>(
        dlsym(RTLD_DEFAULT, "_ZN6Device19sysMgGetLedEnabledRERb")
    );
    if (!function) return RM_RET_ERR;
    try { return function(device, enabled); }
    catch (...) { return RM_RET_ERR; }
}

int OBSBOTDeviceAdapter::setIndicatorEnabled(Device *device, bool enabled) const noexcept {
    if (!device || !contract().indicatorEnableAndBrightness) return RM_RET_ERR;
    using Function = int (*)(Device *, bool);
    const auto function = reinterpret_cast<Function>(
        dlsym(RTLD_DEFAULT, "_ZN6Device19sysMgSetLedEnabledREb")
    );
    if (!function) return RM_RET_ERR;
    try { return function(device, enabled); }
    catch (...) { return RM_RET_ERR; }
}

int OBSBOTDeviceAdapter::getIndicatorBrightness(Device *device, uint8_t &brightness) const noexcept {
    if (!device || !contract().indicatorEnableAndBrightness) return RM_RET_ERR;
    using Function = int (*)(Device *, uint8_t &);
    const auto function = reinterpret_cast<Function>(
        dlsym(RTLD_DEFAULT, "_ZN6Device22sysMgGetLedBrightnessRERh")
    );
    if (!function) return RM_RET_ERR;
    try { return function(device, brightness); }
    catch (...) { return RM_RET_ERR; }
}

int OBSBOTDeviceAdapter::setIndicatorBrightness(Device *device, uint8_t brightness) const noexcept {
    if (!device || !contract().indicatorEnableAndBrightness || brightness > 3) return RM_RET_ERR;
    using Function = int (*)(Device *, uint8_t);
    const auto function = reinterpret_cast<Function>(
        dlsym(RTLD_DEFAULT, "_ZN6Device22sysMgSetLedBrightnessREh")
    );
    if (!function) return RM_RET_ERR;
    try { return function(device, brightness); }
    catch (...) { return RM_RET_ERR; }
}

int OBSBOTDeviceAdapter::setIndicatorColor(Device *, OBSBOTIndicatorColor) const noexcept {
    return RM_RET_ERR;
}

int OBSBOTDeviceAdapter::setIndicatorDark(Device *) const noexcept {
    return RM_RET_ERR;
}

int OBSBOTDeviceAdapter::setAudioMode(Device *, uint8_t, uint8_t) const noexcept {
    return RM_RET_ERR;
}

int OBSBOTDeviceAdapter::setAudioInputGain(Device *, int16_t) const noexcept {
    return RM_RET_ERR;
}

int OBSBOTDeviceAdapter::setSoundFollowing(Device *, bool) const noexcept {
    return RM_RET_ERR;
}

const OBSBOTDeviceAdapter &obsbotDeviceAdapter(ObsbotProductType type) noexcept {
    static const UnknownAdapter unknown;
    static const Tiny2LiteAdapter tiny2Lite;
    static const Tiny3LiteAdapter tiny3Lite;
    switch (type) {
    case ObsbotProdTiny2Lite: return tiny2Lite;
    case ObsbotProdTiny3Lite: return tiny3Lite;
    default: return unknown;
    }
}

const OBSBOTDeviceContract &obsbotDeviceContract(ObsbotProductType type) noexcept {
    return obsbotDeviceAdapter(type).contract();
}

const char *obsbotProfileID(ObsbotProductType type) noexcept {
    return obsbotDeviceAdapter(type).contract().identifier;
}

} // namespace soma
