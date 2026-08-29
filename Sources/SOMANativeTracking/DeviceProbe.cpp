#include <chrono>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <dev/devs.hpp>

#include "OBSBOTDeviceContract.hpp"

namespace {

std::mutex callbackMutex;
std::string connectedSerial;

void deviceChanged(std::string serial, bool connected, void *) {
    std::lock_guard<std::mutex> lock(callbackMutex);
    if (connected) {
        connectedSerial = std::move(serial);
    }
}

using SetTallyLight = int32_t (*)(Device *, bool);
using GetTallyAndBatteryLight = int32_t (*)(Device *, bool &, int32_t &, bool &);
struct NativeHumanTrackingPolicy {
    int speedMode = Device::DevGimCtrlSpeedModeFast;
    bool motionTracking = true;
    bool foreTarget = true;
    bool adaptiveComposition = false;
};

struct AbsoluteFocusRequest {
    int32_t position = 0;
    bool automatic = true;
};

struct AbsoluteExposureRequest {
    int32_t shutter = 0;
    bool automatic = true;
};

struct TallyLightRequest {
    bool enabled = false;
    std::chrono::milliseconds hold {0};
};

bool validNativeHumanTrackingSpeedMode(int speedMode) {
    return speedMode >= Device::DevGimCtrlSpeedModeSuperLazy
        && speedMode <= Device::DevGimCtrlSpeedModeCrazy;
}

}  // namespace

int main(int argc, char *argv[]) {
    std::optional<bool> requestedLedEnabled;
    std::optional<uint8_t> requestedIndicatorState;
    std::vector<uint8_t> requestedIndicatorSets;
    std::vector<uint8_t> requestedIndicatorClears;
    std::optional<float> requestedZoomVerification;
    std::optional<uint8_t> requestedAudioModeVerification;
    std::optional<Device::DevAudioVQEType> requestedAudioVQEVerification;
    std::optional<int16_t> requestedAudioVolumeVerification;
    std::optional<uint8_t> requestedAudioDistanceVerification;
    std::optional<uint8_t> requestedDoaRangeVerification;
    std::optional<int32_t> requestedManualWhiteBalanceVerification;
    std::optional<bool> requestedExposureLockVerification;
    std::optional<Device::DevAutoFocusType> requestedAutoFocusVerification;
    std::optional<AbsoluteFocusRequest> requestedAbsoluteFocusVerification;
    std::optional<AbsoluteExposureRequest> requestedAbsoluteExposureVerification;
    std::optional<NativeHumanTrackingPolicy> requestedNativeTrackingPolicyVerification;
    std::optional<std::array<bool, 2>> requestedNativeTrackingAdaptiveGainVerification;
    std::optional<std::array<float, 2>> requestedNativeTrackingManualGainVerification;
    std::optional<bool> requestedFacePriorityVerification;
    std::optional<int32_t> requestedAntiFlickerVerification;
    std::optional<Device::FovType> requestedFOVVerification;
    std::optional<bool> requestedDoaFindBackVerification;
    std::optional<TallyLightRequest> requestedTallyLight;
    std::chrono::milliseconds indicatorStateHold {1200};
    std::chrono::milliseconds nativeTrackingDisabledHold {0};
    bool disableNativeTracking = false;
    bool inspectOptics = false;
    bool inspectGimbalTracking = false;
    bool inspectNativeTrackingTuning = false;
    if (argc == 2 && std::string(argv[1]) == "--disable-native-tracking") {
        disableNativeTracking = true;
    } else if (argc == 3 && std::string(argv[1]) == "--disable-native-tracking-for") {
        try {
            size_t consumed = 0;
            const int holdMilliseconds = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || holdMilliseconds < 1'000 || holdMilliseconds > 60'000) {
                throw std::out_of_range("hold duration");
            }
            disableNativeTracking = true;
            nativeTrackingDisabledHold = std::chrono::milliseconds(holdMilliseconds);
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --disable-native-tracking-for HOLD_MS(1000..60000)\n";
            return 64;
        }
    } else if (argc >= 3 && std::string(argv[1]) == "--set-indicator-states") {
        try {
            for (int index = 2; index < argc; ++index) {
                size_t consumed = 0;
                const int state = std::stoi(argv[index], &consumed);
                if (consumed != std::string(argv[index]).size() || state < 0 || state > 255) {
                    throw std::out_of_range("indicator state");
                }
                requestedIndicatorSets.push_back(static_cast<uint8_t>(state));
            }
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --set-indicator-states STATE...\n";
            return 64;
        }
    } else if (argc >= 3 && std::string(argv[1]) == "--clear-indicator-states") {
        try {
            for (int index = 2; index < argc; ++index) {
                size_t consumed = 0;
                const int state = std::stoi(argv[index], &consumed);
                if (consumed != std::string(argv[index]).size() || state < 0 || state > 255) {
                    throw std::out_of_range("indicator state");
                }
                requestedIndicatorClears.push_back(static_cast<uint8_t>(state));
            }
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --clear-indicator-states STATE...\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--set-led-enabled") {
        const std::string value = argv[2];
        if (value == "0") {
            requestedLedEnabled = false;
        } else if (value == "1") {
            requestedLedEnabled = true;
        } else {
            std::cerr << "Usage: soma-obsbot-probe [--set-led-enabled 0|1 | --verify-indicator-state 0..255]\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-indicator-state") {
        try {
            size_t consumed = 0;
            const int state = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || state < 0 || state > 255) throw std::out_of_range("state");
            requestedIndicatorState = static_cast<uint8_t>(state);
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe [--set-led-enabled 0|1 | --verify-indicator-state 0..255]\n";
            return 64;
        }
    } else if (argc == 4 && std::string(argv[1]) == "--verify-indicator-state-for") {
        try {
            size_t consumed = 0;
            const int state = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || state < 0 || state > 255) throw std::out_of_range("state");
            consumed = 0;
            const int holdMilliseconds = std::stoi(argv[3], &consumed);
            if (consumed != std::string(argv[3]).size() || holdMilliseconds < 250 || holdMilliseconds > 10'000) {
                throw std::out_of_range("hold duration");
            }
            requestedIndicatorState = static_cast<uint8_t>(state);
            indicatorStateHold = std::chrono::milliseconds(holdMilliseconds);
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-indicator-state-for STATE(0..255) HOLD_MS(250..10000)\n";
            return 64;
        }
    } else if (argc == 4 && std::string(argv[1]) == "--verify-tally-light-for") {
        try {
            size_t consumed = 0;
            const int enabled = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || (enabled != 0 && enabled != 1)) {
                throw std::out_of_range("tally enabled");
            }
            consumed = 0;
            const int holdMilliseconds = std::stoi(argv[3], &consumed);
            if (consumed != std::string(argv[3]).size() || holdMilliseconds < 250 || holdMilliseconds > 10'000) {
                throw std::out_of_range("tally hold duration");
            }
            requestedTallyLight = TallyLightRequest {enabled == 1, std::chrono::milliseconds(holdMilliseconds)};
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-tally-light-for ENABLED(0|1) HOLD_MS(250..10000)\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-zoom") {
        try {
            size_t consumed = 0;
            const float zoom = std::stof(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || !std::isfinite(zoom)
                || zoom < 1.0f || zoom > 2.0f) {
                throw std::out_of_range("zoom");
            }
            requestedZoomVerification = zoom;
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe [--set-led-enabled 0|1 | --verify-indicator-state 0..255 | --verify-zoom 1.0..2.0]\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-audio-mode") {
        try {
            size_t consumed = 0;
            const int mode = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || mode < Device::AudioModeOmni
                || mode >= Device::AudioModeButt) {
                throw std::out_of_range("audio mode");
            }
            requestedAudioModeVerification = static_cast<uint8_t>(mode);
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-audio-mode 0..5\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-audio-vqe") {
        try {
            size_t consumed = 0;
            const int mode = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size()
                || mode < Device::DevAudioVQENone || mode > Device::DevAudioVQEVlog) {
                throw std::out_of_range("audio vqe mode");
            }
            requestedAudioVQEVerification = static_cast<Device::DevAudioVQEType>(mode);
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-audio-vqe 0|1|2\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-audio-volume") {
        try {
            size_t consumed = 0;
            const int volume = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || volume < 0 || volume > 100) {
                throw std::out_of_range("audio volume");
            }
            requestedAudioVolumeVerification = static_cast<int16_t>(volume);
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-audio-volume 0..100\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-audio-distance") {
        try {
            size_t consumed = 0;
            const int distance = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || distance < 0 || distance > 15) {
                throw std::out_of_range("audio distance");
            }
            requestedAudioDistanceVerification = static_cast<uint8_t>(distance);
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-audio-distance 0..15\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-doa-range") {
        try {
            size_t consumed = 0;
            const int range = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || range < 0 || range > 3) {
                throw std::out_of_range("doa range");
            }
            requestedDoaRangeVerification = static_cast<uint8_t>(range);
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-doa-range 0..3\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-manual-white-balance") {
        try {
            size_t consumed = 0;
            const int temperature = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || temperature < 2'000 || temperature > 9'000) {
                throw std::out_of_range("white balance temperature");
            }
            requestedManualWhiteBalanceVerification = temperature;
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-manual-white-balance 2000..9000\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-ae-lock") {
        const std::string value = argv[2];
        if (value == "0") requestedExposureLockVerification = false;
        else if (value == "1") requestedExposureLockVerification = true;
        else {
            std::cerr << "Usage: soma-obsbot-probe --verify-ae-lock 0|1\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-autofocus") {
        try {
            size_t consumed = 0;
            const int mode = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size()
                || mode < Device::DevAutoFocusAutoSelect || mode > Device::DevAutoFocusMF) {
                throw std::out_of_range("autofocus mode");
            }
            requestedAutoFocusVerification = static_cast<Device::DevAutoFocusType>(mode);
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-autofocus 0|1|2|3\n";
            return 64;
        }
    } else if (argc == 4 && std::string(argv[1]) == "--verify-focus-absolute") {
        try {
            size_t consumed = 0;
            const int position = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || position < 0 || position > 100) {
                throw std::out_of_range("focus position");
            }
            consumed = 0;
            const int automatic = std::stoi(argv[3], &consumed);
            if (consumed != std::string(argv[3]).size() || (automatic != 0 && automatic != 1)) {
                throw std::out_of_range("focus automatic");
            }
            requestedAbsoluteFocusVerification = AbsoluteFocusRequest {
                static_cast<int32_t>(position), automatic == 1
            };
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-focus-absolute POSITION(0..100) AUTOMATIC(0|1)\n";
            return 64;
        }
    } else if (argc == 4 && std::string(argv[1]) == "--verify-exposure-absolute") {
        try {
            size_t consumed = 0;
            const int shutter = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || shutter < 0 || shutter > 100) {
                throw std::out_of_range("exposure shutter");
            }
            consumed = 0;
            const int automatic = std::stoi(argv[3], &consumed);
            if (consumed != std::string(argv[3]).size() || (automatic != 0 && automatic != 1)) {
                throw std::out_of_range("exposure automatic");
            }
            requestedAbsoluteExposureVerification = AbsoluteExposureRequest {
                static_cast<int32_t>(shutter), automatic == 1
            };
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-exposure-absolute SHUTTER(0..100) AUTOMATIC(0|1)\n";
            return 64;
        }
    } else if (argc == 6 && std::string(argv[1]) == "--verify-native-tracking-policy") {
        try {
            size_t consumed = 0;
            const int speedMode = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size() || !validNativeHumanTrackingSpeedMode(speedMode)) {
                throw std::out_of_range("speed mode");
            }
            std::array<int, 3> flags {};
            for (size_t index = 0; index < flags.size(); ++index) {
                consumed = 0;
                flags[index] = std::stoi(argv[index + 3], &consumed);
                if (consumed != std::string(argv[index + 3]).size()
                    || (flags[index] != 0 && flags[index] != 1)) {
                    throw std::out_of_range("tracking flag");
                }
            }
            requestedNativeTrackingPolicyVerification = NativeHumanTrackingPolicy {
                speedMode,
                flags[0] == 1,
                flags[1] == 1,
                flags[2] == 1,
            };
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-native-tracking-policy SPEED_MODE MOTION FORE_TARGET ADAPTIVE_COMPOSITION\n";
            return 64;
        }
    } else if (argc == 4 && std::string(argv[1]) == "--verify-native-tracking-adaptive-gain") {
        std::array<bool, 2> values {};
        for (size_t index = 0; index < values.size(); ++index) {
            const std::string value = argv[index + 2];
            if (value == "0") values[index] = false;
            else if (value == "1") values[index] = true;
            else {
                std::cerr << "Usage: soma-obsbot-probe --verify-native-tracking-adaptive-gain PAN_ADAPTIVE PITCH_ADAPTIVE\\n";
                return 64;
            }
        }
        requestedNativeTrackingAdaptiveGainVerification = values;
    } else if (argc == 4 && std::string(argv[1]) == "--verify-native-tracking-manual-gain") {
        std::array<float, 2> values {};
        try {
            for (size_t index = 0; index < values.size(); ++index) {
                size_t consumed = 0;
                const float value = std::stof(argv[index + 2], &consumed);
                if (consumed != std::string(argv[index + 2]).size()
                    || !std::isfinite(value) || value <= 0.f || value > 2.f) {
                    throw std::out_of_range("manual gain");
                }
                values[index] = value;
            }
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-native-tracking-manual-gain PAN_GAIN PITCH_GAIN (0,2]\n";
            return 64;
        }
        requestedNativeTrackingManualGainVerification = values;
    } else if (argc == 3 && std::string(argv[1]) == "--verify-face-priority") {
        const std::string value = argv[2];
        if (value == "0") requestedFacePriorityVerification = false;
        else if (value == "1") requestedFacePriorityVerification = true;
        else {
            std::cerr << "Usage: soma-obsbot-probe --verify-face-priority 0|1\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-anti-flicker") {
        try {
            size_t consumed = 0;
            const int32_t value = std::stoi(argv[2], &consumed);
            if (consumed != std::string(argv[2]).size()
                || value < Device::PowerLineFreqOff || value > Device::PowerLineFreqAuto) {
                throw std::out_of_range("anti flicker");
            }
            requestedAntiFlickerVerification = value;
        } catch (...) {
            std::cerr << "Usage: soma-obsbot-probe --verify-anti-flicker 0|1|2|3\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-fov") {
        const std::string value = argv[2];
        if (value == "86") requestedFOVVerification = Device::FovType86;
        else if (value == "78") requestedFOVVerification = Device::FovType78;
        else if (value == "65") requestedFOVVerification = Device::FovType65;
        else {
            std::cerr << "Usage: soma-obsbot-probe --verify-fov 65|78|86\n";
            return 64;
        }
    } else if (argc == 3 && std::string(argv[1]) == "--verify-doa-find-back") {
        const std::string value = argv[2];
        if (value == "0") requestedDoaFindBackVerification = false;
        else if (value == "1") requestedDoaFindBackVerification = true;
        else {
            std::cerr << "Usage: soma-obsbot-probe --verify-doa-find-back 0|1\n";
            return 64;
        }
    } else if (argc == 2 && std::string(argv[1]) == "--inspect-optics") {
        inspectOptics = true;
    } else if (argc == 2 && std::string(argv[1]) == "--inspect-gimbal-tracking") {
        inspectGimbalTracking = true;
    } else if (argc == 2 && std::string(argv[1]) == "--inspect-native-tracking-tuning") {
        inspectNativeTrackingTuning = true;
    } else if (argc != 1) {
        std::cerr << "Usage: soma-obsbot-probe [--set-led-enabled 0|1 | --verify-indicator-state 0..255]\n";
        return 64;
    }

    auto &devices = Devices::get();
    devices.setEnableMdnsScan(false);
    devices.setDevChangedCallback(deviceChanged, nullptr);

    std::shared_ptr<Device> device;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline) {
        std::string serial;
        {
            std::lock_guard<std::mutex> lock(callbackMutex);
            serial = connectedSerial;
        }
        if (!serial.empty()) {
            device = devices.getDevBySn(serial);
            if (device) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    if (!device) {
        std::cerr << "SOMA_OBSBOT_CAPABILITY contract=2 profile=unknown native_bridge=false unavailable=true reason=device_unavailable\n";
        return 2;
    }
    const auto &adapter = soma::obsbotDeviceAdapter(device->productType());
    const int disableNativeTrackingResult = disableNativeTracking
        ? adapter.disableNativeTracking(device.get())
        : RM_RET_OK;
    if (disableNativeTrackingResult == RM_RET_OK && nativeTrackingDisabledHold.count() > 0) {
        std::this_thread::sleep_for(nativeTrackingDisabledHold);
    }

    Device::CameraStatus status{};
    const int statusResult = device->cameraGetCameraStatusU(status);
    Device::DevAutoFocusType autoFocus = Device::DevAutoFocusAutoSelect;
    int32_t focusPosition = 0;
    int32_t exposureMode = Device::DevExposureUnknown;
    uint32_t minimumISO = 0;
    uint32_t maximumISO = 0;
    int32_t exposureBias = 0;
    Device::UvcParamRange exposureBiasRange;
    int32_t mirrorFlip = 0;
    int autoFocusResult = RM_RET_ERR;
    int focusPositionResult = RM_RET_ERR;
    int exposureModeResult = RM_RET_ERR;
    int isoLimitResult = RM_RET_ERR;
    int exposureBiasResult = RM_RET_ERR;
    int exposureBiasRangeResult = RM_RET_ERR;
    int mirrorFlipResult = RM_RET_ERR;
    if (inspectOptics) {
        try { autoFocusResult = device->cameraGetAutoFocusModeR(autoFocus); } catch (...) {}
        try { focusPositionResult = device->cameraGetFocusPosR(focusPosition); } catch (...) {}
        try { exposureModeResult = device->cameraGetExposureModeR(exposureMode); } catch (...) {}
        try { isoLimitResult = device->cameraGetISOLimitR(minimumISO, maximumISO); } catch (...) {}
        try { exposureBiasResult = device->cameraGetPAEEvBiasR(exposureBias); } catch (...) {}
        try { exposureBiasRangeResult = device->cameraGetRangePAEEvBiasR(exposureBiasRange); } catch (...) {}
        try { mirrorFlipResult = device->cameraGetMirrorFlipR(mirrorFlip); } catch (...) {}
    }
    float baselineZoom = 0;
    float verifiedZoom = 0;
    float restoredZoom = 0;
    int baselineZoomResult = device->cameraGetZoomAbsoluteR(baselineZoom);
    int zoomSetResult = RM_RET_OK;
    int verifiedZoomResult = RM_RET_OK;
    int zoomRestoreResult = RM_RET_OK;
    int restoredZoomResult = RM_RET_OK;
    if (requestedZoomVerification) {
        const bool restoringWideView = *requestedZoomVerification <= 1.01f;
        const float requestedZoomTolerance = restoringWideView ? 0.015f : 0.04f;
        const auto requestedZoomTimeout = restoringWideView
            ? std::chrono::milliseconds(6'000)
            : std::chrono::milliseconds(1'800);
        try {
            zoomSetResult = device->cameraSetZoomAbsoluteR(*requestedZoomVerification);
        } catch (...) {
            zoomSetResult = RM_RET_ERR;
        }
        if (zoomSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + requestedZoomTimeout;
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try {
                    verifiedZoomResult = device->cameraGetZoomAbsoluteR(verifiedZoom);
                } catch (...) {
                    verifiedZoomResult = RM_RET_ERR;
                }
                if (verifiedZoomResult == RM_RET_OK
                    && std::abs(verifiedZoom - *requestedZoomVerification) <= requestedZoomTolerance) {
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        if (baselineZoomResult == RM_RET_OK && std::isfinite(baselineZoom)) {
            const bool restoringBaselineWideView = baselineZoom <= 1.01f;
            const float restoreZoomTolerance = restoringBaselineWideView ? 0.015f : 0.04f;
            const auto restoreZoomTimeout = restoringBaselineWideView
                ? std::chrono::milliseconds(6'000)
                : std::chrono::milliseconds(1'800);
            try {
                zoomRestoreResult = device->cameraSetZoomAbsoluteR(baselineZoom);
            } catch (...) {
                zoomRestoreResult = RM_RET_ERR;
            }
            if (zoomRestoreResult == RM_RET_OK) {
                const auto deadline = std::chrono::steady_clock::now() + restoreZoomTimeout;
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    try {
                        restoredZoomResult = device->cameraGetZoomAbsoluteR(restoredZoom);
                    } catch (...) {
                        restoredZoomResult = RM_RET_ERR;
                    }
                    if (restoredZoomResult == RM_RET_OK && std::abs(restoredZoom - baselineZoom) <= restoreZoomTolerance) {
                        break;
                    }
                } while (std::chrono::steady_clock::now() < deadline);
            }
        } else {
            zoomRestoreResult = RM_RET_ERR;
            restoredZoomResult = RM_RET_ERR;
        }
    }
    using SetAudioMode = int32_t (*)(Device *, Device::AudioMode);
    const auto setAudioMode = reinterpret_cast<SetAudioMode>(
        dlsym(RTLD_DEFAULT, "_ZN6Device19cameraSetAudioModeUENS_9AudioModeE")
    );
    const uint8_t baselineAudioSource = statusResult == RM_RET_OK ? status.tiny.audio_mode.source : 0;
    const uint8_t baselineAudioMode = statusResult == RM_RET_OK ? status.tiny.audio_mode.mode : 0;
    uint8_t verifiedAudioMode = 0;
    uint8_t restoredAudioMode = 0;
    int audioModeSetResult = RM_RET_OK;
    int audioModeVerifyResult = RM_RET_OK;
    int audioModeRestoreResult = RM_RET_OK;
    int audioModeRestoredResult = RM_RET_OK;
    if (requestedAudioModeVerification) {
        Device::AudioMode requestedAudioMode {baselineAudioSource, *requestedAudioModeVerification};
        if (setAudioMode) {
            try { audioModeSetResult = setAudioMode(device.get(), requestedAudioMode); } catch (...) {
                audioModeSetResult = RM_RET_ERR;
            }
        } else {
            audioModeSetResult = RM_RET_ERR;
        }
        if (audioModeSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            Device::CameraStatus verifiedStatus {};
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { audioModeVerifyResult = device->cameraGetCameraStatusU(verifiedStatus); } catch (...) {
                    audioModeVerifyResult = RM_RET_ERR;
                }
                if (audioModeVerifyResult == RM_RET_OK) {
                    verifiedAudioMode = verifiedStatus.tiny.audio_mode.mode;
                    if (verifiedAudioMode == *requestedAudioModeVerification) break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        if (statusResult == RM_RET_OK && setAudioMode) {
            Device::AudioMode restoreAudioMode {baselineAudioSource, baselineAudioMode};
            try { audioModeRestoreResult = setAudioMode(device.get(), restoreAudioMode); } catch (...) {
                audioModeRestoreResult = RM_RET_ERR;
            }
            if (audioModeRestoreResult == RM_RET_OK) {
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
                Device::CameraStatus restoredStatus {};
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    try { audioModeRestoredResult = device->cameraGetCameraStatusU(restoredStatus); } catch (...) {
                        audioModeRestoredResult = RM_RET_ERR;
                    }
                    if (audioModeRestoredResult == RM_RET_OK) {
                        restoredAudioMode = restoredStatus.tiny.audio_mode.mode;
                        if (restoredAudioMode == baselineAudioMode) break;
                    }
                } while (std::chrono::steady_clock::now() < deadline);
            }
        } else {
            audioModeRestoreResult = RM_RET_ERR;
            audioModeRestoredResult = RM_RET_ERR;
        }
    }
    using GetAudioVQEType = int32_t (*)(Device *, Device::DevAudioVQEType &);
    using SetAudioVQEType = int32_t (*)(Device *, Device::DevAudioVQEType);
    const auto getAudioVQEType = reinterpret_cast<GetAudioVQEType>(
        dlsym(RTLD_DEFAULT, "_ZN6Device22cameraGetAudioVQETypeRERNS_15DevAudioVQETypeE")
    );
    const auto setAudioVQEType = reinterpret_cast<SetAudioVQEType>(
        dlsym(RTLD_DEFAULT, "_ZN6Device22cameraSetAudioVQETypeRENS_15DevAudioVQETypeE")
    );
    Device::DevAudioVQEType baselineAudioVQE = Device::DevAudioVQENone;
    Device::DevAudioVQEType verifiedAudioVQE = Device::DevAudioVQENone;
    Device::DevAudioVQEType restoredAudioVQE = Device::DevAudioVQENone;
    const int audioVQEBaselineResult = getAudioVQEType
        ? getAudioVQEType(device.get(), baselineAudioVQE)
        : RM_RET_ERR;
    int audioVQESetResult = RM_RET_OK;
    int audioVQEVerifyResult = RM_RET_OK;
    int audioVQERestoreResult = RM_RET_OK;
    int audioVQERestoredResult = RM_RET_OK;
    bool audioVQEVerified = false;
    bool audioVQERestored = false;
    if (requestedAudioVQEVerification && audioVQEBaselineResult == RM_RET_OK && setAudioVQEType) {
        try { audioVQESetResult = setAudioVQEType(device.get(), *requestedAudioVQEVerification); } catch (...) {
            audioVQESetResult = RM_RET_ERR;
        }
        if (audioVQESetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { audioVQEVerifyResult = getAudioVQEType(device.get(), verifiedAudioVQE); } catch (...) {
                    audioVQEVerifyResult = RM_RET_ERR;
                }
                if (audioVQEVerifyResult == RM_RET_OK && verifiedAudioVQE == *requestedAudioVQEVerification) {
                    audioVQEVerified = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        try { audioVQERestoreResult = setAudioVQEType(device.get(), baselineAudioVQE); } catch (...) {
            audioVQERestoreResult = RM_RET_ERR;
        }
        if (audioVQERestoreResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { audioVQERestoredResult = getAudioVQEType(device.get(), restoredAudioVQE); } catch (...) {
                    audioVQERestoredResult = RM_RET_ERR;
                }
                if (audioVQERestoredResult == RM_RET_OK && restoredAudioVQE == baselineAudioVQE) {
                    audioVQERestored = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
    } else if (requestedAudioVQEVerification) {
        audioVQESetResult = RM_RET_ERR;
        audioVQEVerifyResult = RM_RET_ERR;
        audioVQERestoreResult = RM_RET_ERR;
        audioVQERestoredResult = RM_RET_ERR;
    }
    using GetAudioVolume = int32_t (*)(Device *, int16_t &);
    using SetAudioVolume = int32_t (*)(Device *, int16_t);
    const auto getAudioVolume = reinterpret_cast<GetAudioVolume>(
        dlsym(RTLD_DEFAULT, "_ZN6Device21cameraGetAudioVolumeRERs")
    );
    const auto setAudioVolume = reinterpret_cast<SetAudioVolume>(
        dlsym(RTLD_DEFAULT, "_ZN6Device21cameraSetAudioVolumeREs")
    );
    int16_t baselineAudioVolume = 0;
    int16_t verifiedAudioVolume = 0;
    int16_t restoredAudioVolume = 0;
    const int audioVolumeBaselineResult = getAudioVolume
        ? getAudioVolume(device.get(), baselineAudioVolume)
        : RM_RET_ERR;
    int audioVolumeSetResult = RM_RET_OK;
    int audioVolumeVerifyResult = RM_RET_OK;
    int audioVolumeRestoreResult = RM_RET_OK;
    int audioVolumeRestoredResult = RM_RET_OK;
    bool audioVolumeVerified = false;
    bool audioVolumeRestored = false;
    if (requestedAudioVolumeVerification && audioVolumeBaselineResult == RM_RET_OK && setAudioVolume) {
        try { audioVolumeSetResult = setAudioVolume(device.get(), *requestedAudioVolumeVerification); } catch (...) {
            audioVolumeSetResult = RM_RET_ERR;
        }
        if (audioVolumeSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { audioVolumeVerifyResult = getAudioVolume(device.get(), verifiedAudioVolume); } catch (...) {
                    audioVolumeVerifyResult = RM_RET_ERR;
                }
                if (audioVolumeVerifyResult == RM_RET_OK
                    && verifiedAudioVolume == *requestedAudioVolumeVerification) {
                    audioVolumeVerified = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        try { audioVolumeRestoreResult = setAudioVolume(device.get(), baselineAudioVolume); } catch (...) {
            audioVolumeRestoreResult = RM_RET_ERR;
        }
        if (audioVolumeRestoreResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { audioVolumeRestoredResult = getAudioVolume(device.get(), restoredAudioVolume); } catch (...) {
                    audioVolumeRestoredResult = RM_RET_ERR;
                }
                if (audioVolumeRestoredResult == RM_RET_OK && restoredAudioVolume == baselineAudioVolume) {
                    audioVolumeRestored = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
    } else if (requestedAudioVolumeVerification) {
        audioVolumeSetResult = RM_RET_ERR;
        audioVolumeVerifyResult = RM_RET_ERR;
        audioVolumeRestoreResult = RM_RET_ERR;
        audioVolumeRestoredResult = RM_RET_ERR;
    }
    using SetDoaRange = int32_t (*)(Device *, uint8_t);
    const auto setDoaRange = reinterpret_cast<SetDoaRange>(
        dlsym(RTLD_DEFAULT, "_ZN6Device17cameraSetDoaRangeEh")
    );
    const uint8_t baselineDoaRange = statusResult == RM_RET_OK ? status.tiny.doa_set.doa_range : 0;
    uint8_t verifiedDoaRange = 0;
    uint8_t restoredDoaRange = 0;
    int doaRangeSetResult = RM_RET_OK;
    int doaRangeVerifyResult = RM_RET_OK;
    int doaRangeRestoreResult = RM_RET_OK;
    int doaRangeRestoredResult = RM_RET_OK;
    if (requestedDoaRangeVerification) {
        if (setDoaRange) {
            try { doaRangeSetResult = setDoaRange(device.get(), *requestedDoaRangeVerification); } catch (...) {
                doaRangeSetResult = RM_RET_ERR;
            }
        } else {
            doaRangeSetResult = RM_RET_ERR;
        }
        if (doaRangeSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            Device::CameraStatus verifiedStatus {};
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { doaRangeVerifyResult = device->cameraGetCameraStatusU(verifiedStatus); } catch (...) {
                    doaRangeVerifyResult = RM_RET_ERR;
                }
                if (doaRangeVerifyResult == RM_RET_OK) {
                    verifiedDoaRange = verifiedStatus.tiny.doa_set.doa_range;
                    if (verifiedDoaRange == *requestedDoaRangeVerification) break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        if (statusResult == RM_RET_OK && setDoaRange) {
            try { doaRangeRestoreResult = setDoaRange(device.get(), baselineDoaRange); } catch (...) {
                doaRangeRestoreResult = RM_RET_ERR;
            }
            if (doaRangeRestoreResult == RM_RET_OK) {
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
                Device::CameraStatus restoredStatus {};
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    try { doaRangeRestoredResult = device->cameraGetCameraStatusU(restoredStatus); } catch (...) {
                        doaRangeRestoredResult = RM_RET_ERR;
                    }
                    if (doaRangeRestoredResult == RM_RET_OK) {
                        restoredDoaRange = restoredStatus.tiny.doa_set.doa_range;
                        if (restoredDoaRange == baselineDoaRange) break;
                    }
                } while (std::chrono::steady_clock::now() < deadline);
            }
        } else {
            doaRangeRestoreResult = RM_RET_ERR;
            doaRangeRestoredResult = RM_RET_ERR;
        }
    }
    using SetAudioDistance = int32_t (*)(Device *, uint8_t);
    const auto setAudioDistance = reinterpret_cast<SetAudioDistance>(
        dlsym(RTLD_DEFAULT, "_ZN6Device23cameraSetAudioDistanceUEh")
    );
    const uint8_t baselineAudioDistance = statusResult == RM_RET_OK ? status.tiny.audio_opt.distance : 0;
    uint8_t verifiedAudioDistance = 0;
    uint8_t restoredAudioDistance = 0;
    int audioDistanceSetResult = RM_RET_OK;
    int audioDistanceVerifyResult = RM_RET_OK;
    int audioDistanceRestoreResult = RM_RET_OK;
    int audioDistanceRestoredResult = RM_RET_OK;
    if (requestedAudioDistanceVerification) {
        if (setAudioDistance) {
            try { audioDistanceSetResult = setAudioDistance(device.get(), *requestedAudioDistanceVerification); } catch (...) {
                audioDistanceSetResult = RM_RET_ERR;
            }
        } else {
            audioDistanceSetResult = RM_RET_ERR;
        }
        if (audioDistanceSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            Device::CameraStatus verifiedStatus {};
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { audioDistanceVerifyResult = device->cameraGetCameraStatusU(verifiedStatus); } catch (...) {
                    audioDistanceVerifyResult = RM_RET_ERR;
                }
                if (audioDistanceVerifyResult == RM_RET_OK) {
                    verifiedAudioDistance = verifiedStatus.tiny.audio_opt.distance;
                    if (verifiedAudioDistance == *requestedAudioDistanceVerification) break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        if (statusResult == RM_RET_OK && setAudioDistance) {
            try { audioDistanceRestoreResult = setAudioDistance(device.get(), baselineAudioDistance); } catch (...) {
                audioDistanceRestoreResult = RM_RET_ERR;
            }
            if (audioDistanceRestoreResult == RM_RET_OK) {
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
                Device::CameraStatus restoredStatus {};
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    try { audioDistanceRestoredResult = device->cameraGetCameraStatusU(restoredStatus); } catch (...) {
                        audioDistanceRestoredResult = RM_RET_ERR;
                    }
                    if (audioDistanceRestoredResult == RM_RET_OK) {
                        restoredAudioDistance = restoredStatus.tiny.audio_opt.distance;
                        if (restoredAudioDistance == baselineAudioDistance) break;
                    }
                } while (std::chrono::steady_clock::now() < deadline);
            }
        } else {
            audioDistanceRestoreResult = RM_RET_ERR;
            audioDistanceRestoredResult = RM_RET_ERR;
        }
    }
    Device::DevWhiteBalanceType baselineWhiteBalance = Device::DevWhiteBalanceAuto;
    int32_t baselineWhiteBalanceParameter = 0;
    const int baselineWhiteBalanceResult = device->cameraGetWhiteBalanceR(
        baselineWhiteBalance,
        baselineWhiteBalanceParameter
    );
    Device::DevWhiteBalanceType verifiedWhiteBalance = Device::DevWhiteBalanceAuto;
    int32_t verifiedWhiteBalanceParameter = 0;
    Device::DevWhiteBalanceType restoredWhiteBalance = Device::DevWhiteBalanceAuto;
    int32_t restoredWhiteBalanceParameter = 0;
    int manualWhiteBalanceSetResult = RM_RET_OK;
    int manualWhiteBalanceVerifyResult = RM_RET_OK;
    int manualWhiteBalanceRestoreResult = RM_RET_OK;
    int manualWhiteBalanceRestoredResult = RM_RET_OK;
    bool manualWhiteBalanceVerified = false;
    bool manualWhiteBalanceRestored = false;
    if (requestedManualWhiteBalanceVerification) {
        try {
            manualWhiteBalanceSetResult = device->cameraSetWhiteBalanceR(
                Device::DevWhiteBalanceManual,
                *requestedManualWhiteBalanceVerification
            );
        } catch (...) {
            manualWhiteBalanceSetResult = RM_RET_ERR;
        }
        if (manualWhiteBalanceSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try {
                    manualWhiteBalanceVerifyResult = device->cameraGetWhiteBalanceR(
                        verifiedWhiteBalance,
                        verifiedWhiteBalanceParameter
                    );
                } catch (...) {
                    manualWhiteBalanceVerifyResult = RM_RET_ERR;
                }
                if (manualWhiteBalanceVerifyResult == RM_RET_OK
                    && verifiedWhiteBalance == Device::DevWhiteBalanceManual
                    && verifiedWhiteBalanceParameter == *requestedManualWhiteBalanceVerification) {
                    manualWhiteBalanceVerified = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        if (baselineWhiteBalanceResult == RM_RET_OK) {
            try {
                manualWhiteBalanceRestoreResult = device->cameraSetWhiteBalanceR(
                    baselineWhiteBalance,
                    baselineWhiteBalanceParameter
                );
            } catch (...) {
                manualWhiteBalanceRestoreResult = RM_RET_ERR;
            }
            if (manualWhiteBalanceRestoreResult == RM_RET_OK) {
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    try {
                        manualWhiteBalanceRestoredResult = device->cameraGetWhiteBalanceR(
                            restoredWhiteBalance,
                            restoredWhiteBalanceParameter
                        );
                    } catch (...) {
                        manualWhiteBalanceRestoredResult = RM_RET_ERR;
                    }
                    if (manualWhiteBalanceRestoredResult == RM_RET_OK
                        && restoredWhiteBalance == baselineWhiteBalance
                        && (baselineWhiteBalance != Device::DevWhiteBalanceManual
                            || restoredWhiteBalanceParameter == baselineWhiteBalanceParameter)) {
                        manualWhiteBalanceRestored = true;
                        break;
                    }
                } while (std::chrono::steady_clock::now() < deadline);
            }
        } else {
            manualWhiteBalanceRestoreResult = RM_RET_ERR;
            manualWhiteBalanceRestoredResult = RM_RET_ERR;
        }
    }
    bool baselineExposureLock = false;
    bool verifiedExposureLock = false;
    bool restoredExposureLock = false;
    const int baselineExposureLockResult = device->cameraGetAELockR(baselineExposureLock);
    int exposureLockSetResult = RM_RET_OK;
    int exposureLockVerifyResult = RM_RET_OK;
    int exposureLockRestoreResult = RM_RET_OK;
    int exposureLockRestoredResult = RM_RET_OK;
    bool exposureLockVerified = false;
    bool exposureLockRestored = false;
    if (requestedExposureLockVerification) {
        try { exposureLockSetResult = device->cameraSetAELockR(*requestedExposureLockVerification); } catch (...) {
            exposureLockSetResult = RM_RET_ERR;
        }
        if (exposureLockSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { exposureLockVerifyResult = device->cameraGetAELockR(verifiedExposureLock); } catch (...) {
                    exposureLockVerifyResult = RM_RET_ERR;
                }
                if (exposureLockVerifyResult == RM_RET_OK
                    && verifiedExposureLock == *requestedExposureLockVerification) {
                    exposureLockVerified = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        if (baselineExposureLockResult == RM_RET_OK) {
            try { exposureLockRestoreResult = device->cameraSetAELockR(baselineExposureLock); } catch (...) {
                exposureLockRestoreResult = RM_RET_ERR;
            }
            if (exposureLockRestoreResult == RM_RET_OK) {
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    try { exposureLockRestoredResult = device->cameraGetAELockR(restoredExposureLock); } catch (...) {
                        exposureLockRestoredResult = RM_RET_ERR;
                    }
                    if (exposureLockRestoredResult == RM_RET_OK
                        && restoredExposureLock == baselineExposureLock) {
                        exposureLockRestored = true;
                        break;
                    }
                } while (std::chrono::steady_clock::now() < deadline);
            }
        } else {
            exposureLockRestoreResult = RM_RET_ERR;
            exposureLockRestoredResult = RM_RET_ERR;
        }
    }
    Device::DevAutoFocusType baselineAutoFocus = Device::DevAutoFocusAutoSelect;
    Device::DevAutoFocusType verifiedAutoFocus = Device::DevAutoFocusAutoSelect;
    Device::DevAutoFocusType restoredAutoFocus = Device::DevAutoFocusAutoSelect;
    const int baselineAutoFocusResult = device->cameraGetAutoFocusModeR(baselineAutoFocus);
    int autoFocusSetResult = RM_RET_OK;
    int autoFocusVerifyResult = RM_RET_OK;
    int autoFocusRestoreResult = RM_RET_OK;
    int autoFocusRestoredResult = RM_RET_OK;
    bool autoFocusVerified = false;
    bool autoFocusRestored = false;
    if (requestedAutoFocusVerification && baselineAutoFocusResult == RM_RET_OK) {
        try { autoFocusSetResult = device->cameraSetAutoFocusModeR(*requestedAutoFocusVerification); } catch (...) {
            autoFocusSetResult = RM_RET_ERR;
        }
        if (autoFocusSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { autoFocusVerifyResult = device->cameraGetAutoFocusModeR(verifiedAutoFocus); } catch (...) {
                    autoFocusVerifyResult = RM_RET_ERR;
                }
                if (autoFocusVerifyResult == RM_RET_OK && verifiedAutoFocus == *requestedAutoFocusVerification) {
                    autoFocusVerified = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        try { autoFocusRestoreResult = device->cameraSetAutoFocusModeR(baselineAutoFocus); } catch (...) {
            autoFocusRestoreResult = RM_RET_ERR;
        }
        if (autoFocusRestoreResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { autoFocusRestoredResult = device->cameraGetAutoFocusModeR(restoredAutoFocus); } catch (...) {
                    autoFocusRestoredResult = RM_RET_ERR;
                }
                if (autoFocusRestoredResult == RM_RET_OK && restoredAutoFocus == baselineAutoFocus) {
                    autoFocusRestored = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
    } else if (requestedAutoFocusVerification) {
        autoFocusSetResult = RM_RET_ERR;
        autoFocusVerifyResult = RM_RET_ERR;
        autoFocusRestoreResult = RM_RET_ERR;
        autoFocusRestoredResult = RM_RET_ERR;
    }
    int32_t baselineAbsoluteFocus = 0;
    int32_t verifiedAbsoluteFocus = 0;
    int32_t restoredAbsoluteFocus = 0;
    bool baselineAbsoluteFocusAutomatic = false;
    bool verifiedAbsoluteFocusAutomatic = false;
    bool restoredAbsoluteFocusAutomatic = false;
    const int baselineAbsoluteFocusResult = device->cameraGetFocusAbsolute(
        baselineAbsoluteFocus, baselineAbsoluteFocusAutomatic
    );
    int absoluteFocusSetResult = RM_RET_OK;
    int absoluteFocusVerifyResult = RM_RET_OK;
    int absoluteFocusRestoreResult = RM_RET_OK;
    int absoluteFocusRestoredResult = RM_RET_OK;
    bool absoluteFocusVerified = false;
    bool absoluteFocusRestored = false;
    if (requestedAbsoluteFocusVerification && baselineAbsoluteFocusResult == RM_RET_OK) {
        try {
            absoluteFocusSetResult = device->cameraSetFocusAbsolute(
                requestedAbsoluteFocusVerification->position,
                requestedAbsoluteFocusVerification->automatic
            );
        } catch (...) {
            absoluteFocusSetResult = RM_RET_ERR;
        }
        if (absoluteFocusSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try {
                    absoluteFocusVerifyResult = device->cameraGetFocusAbsolute(
                        verifiedAbsoluteFocus, verifiedAbsoluteFocusAutomatic
                    );
                } catch (...) {
                    absoluteFocusVerifyResult = RM_RET_ERR;
                }
                if (absoluteFocusVerifyResult == RM_RET_OK
                    && verifiedAbsoluteFocusAutomatic == requestedAbsoluteFocusVerification->automatic
                    && (requestedAbsoluteFocusVerification->automatic
                        || verifiedAbsoluteFocus == requestedAbsoluteFocusVerification->position)) {
                    absoluteFocusVerified = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        try {
            absoluteFocusRestoreResult = device->cameraSetFocusAbsolute(
                baselineAbsoluteFocus, baselineAbsoluteFocusAutomatic
            );
        } catch (...) {
            absoluteFocusRestoreResult = RM_RET_ERR;
        }
        if (absoluteFocusRestoreResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try {
                    absoluteFocusRestoredResult = device->cameraGetFocusAbsolute(
                        restoredAbsoluteFocus, restoredAbsoluteFocusAutomatic
                    );
                } catch (...) {
                    absoluteFocusRestoredResult = RM_RET_ERR;
                }
                if (absoluteFocusRestoredResult == RM_RET_OK
                    && restoredAbsoluteFocusAutomatic == baselineAbsoluteFocusAutomatic
                    && (baselineAbsoluteFocusAutomatic || restoredAbsoluteFocus == baselineAbsoluteFocus)) {
                    absoluteFocusRestored = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
    } else if (requestedAbsoluteFocusVerification) {
        absoluteFocusSetResult = RM_RET_ERR;
        absoluteFocusVerifyResult = RM_RET_ERR;
        absoluteFocusRestoreResult = RM_RET_ERR;
        absoluteFocusRestoredResult = RM_RET_ERR;
    }
    int32_t baselineAbsoluteExposure = 0;
    int32_t verifiedAbsoluteExposure = 0;
    int32_t restoredAbsoluteExposure = 0;
    bool baselineAbsoluteExposureAutomatic = false;
    bool verifiedAbsoluteExposureAutomatic = false;
    bool restoredAbsoluteExposureAutomatic = false;
    const int baselineAbsoluteExposureResult = device->cameraGetExposureAbsolute(
        baselineAbsoluteExposure, baselineAbsoluteExposureAutomatic
    );
    int absoluteExposureSetResult = RM_RET_OK;
    int absoluteExposureVerifyResult = RM_RET_OK;
    int absoluteExposureRestoreResult = RM_RET_OK;
    int absoluteExposureRestoredResult = RM_RET_OK;
    bool absoluteExposureVerified = false;
    bool absoluteExposureRestored = false;
    if (requestedAbsoluteExposureVerification && baselineAbsoluteExposureResult == RM_RET_OK) {
        try {
            absoluteExposureSetResult = device->cameraSetExposureAbsolute(
                requestedAbsoluteExposureVerification->shutter,
                requestedAbsoluteExposureVerification->automatic
            );
        } catch (...) {
            absoluteExposureSetResult = RM_RET_ERR;
        }
        if (absoluteExposureSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try {
                    absoluteExposureVerifyResult = device->cameraGetExposureAbsolute(
                        verifiedAbsoluteExposure, verifiedAbsoluteExposureAutomatic
                    );
                } catch (...) {
                    absoluteExposureVerifyResult = RM_RET_ERR;
                }
                if (absoluteExposureVerifyResult == RM_RET_OK
                    && verifiedAbsoluteExposureAutomatic == requestedAbsoluteExposureVerification->automatic
                    && (requestedAbsoluteExposureVerification->automatic
                        || verifiedAbsoluteExposure == requestedAbsoluteExposureVerification->shutter)) {
                    absoluteExposureVerified = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        try {
            absoluteExposureRestoreResult = device->cameraSetExposureAbsolute(
                baselineAbsoluteExposure, baselineAbsoluteExposureAutomatic
            );
        } catch (...) {
            absoluteExposureRestoreResult = RM_RET_ERR;
        }
        if (absoluteExposureRestoreResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try {
                    absoluteExposureRestoredResult = device->cameraGetExposureAbsolute(
                        restoredAbsoluteExposure, restoredAbsoluteExposureAutomatic
                    );
                } catch (...) {
                    absoluteExposureRestoredResult = RM_RET_ERR;
                }
                if (absoluteExposureRestoredResult == RM_RET_OK
                    && restoredAbsoluteExposureAutomatic == baselineAbsoluteExposureAutomatic
                    && (baselineAbsoluteExposureAutomatic || restoredAbsoluteExposure == baselineAbsoluteExposure)) {
                    absoluteExposureRestored = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
    } else if (requestedAbsoluteExposureVerification) {
        absoluteExposureSetResult = RM_RET_ERR;
        absoluteExposureVerifyResult = RM_RET_ERR;
        absoluteExposureRestoreResult = RM_RET_ERR;
        absoluteExposureRestoredResult = RM_RET_ERR;
    }
    auto readNativeTrackingPolicy = [&](NativeHumanTrackingPolicy &policy,
                                        int &speedResult,
                                        int &motionResult,
                                        int &foreResult,
                                        int &compositionResult) {
        try {
            speedResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeGimCtrlSpeedMode,
                policy.speedMode
            );
            motionResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeMotion,
                policy.motionTracking
            );
            foreResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeForeTrack,
                policy.foreTarget
            );
            compositionResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeComposition,
                policy.adaptiveComposition
            );
        } catch (...) {
            speedResult = RM_RET_ERR;
            motionResult = RM_RET_ERR;
            foreResult = RM_RET_ERR;
            compositionResult = RM_RET_ERR;
        }
        return speedResult == RM_RET_OK && motionResult == RM_RET_OK
            && foreResult == RM_RET_OK && compositionResult == RM_RET_OK;
    };
    auto setNativeTrackingPolicy = [&](const NativeHumanTrackingPolicy &policy,
                                       int &speedResult,
                                       int &motionResult,
                                       int &foreResult,
                                       int &compositionResult) {
        try {
            speedResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeGimCtrlSpeedMode,
                policy.speedMode
            );
            motionResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeMotion,
                policy.motionTracking
            );
            foreResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeForeTrack,
                policy.foreTarget
            );
            compositionResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeComposition,
                policy.adaptiveComposition
            );
        } catch (...) {
            speedResult = RM_RET_ERR;
            motionResult = RM_RET_ERR;
            foreResult = RM_RET_ERR;
            compositionResult = RM_RET_ERR;
        }
        return speedResult == RM_RET_OK && motionResult == RM_RET_OK
            && foreResult == RM_RET_OK && compositionResult == RM_RET_OK;
    };
    auto readNativeTrackingAdaptiveGains = [&](bool &panAdaptive,
                                                bool &pitchAdaptive,
                                                int &panResult,
                                                int &pitchResult) {
        try {
            panResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePanGainAdaptive,
                panAdaptive
            );
            pitchResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePitchGainAdaptive,
                pitchAdaptive
            );
        } catch (...) {
            panResult = RM_RET_ERR;
            pitchResult = RM_RET_ERR;
        }
        return panResult == RM_RET_OK && pitchResult == RM_RET_OK;
    };
    auto setNativeTrackingAdaptiveGains = [&](bool panAdaptive,
                                               bool pitchAdaptive,
                                               int &panResult,
                                               int &pitchResult) {
        try {
            panResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePanGainAdaptive,
                panAdaptive
            );
            pitchResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePitchGainAdaptive,
                pitchAdaptive
            );
        } catch (...) {
            panResult = RM_RET_ERR;
            pitchResult = RM_RET_ERR;
        }
        return panResult == RM_RET_OK && pitchResult == RM_RET_OK;
    };
    auto readNativeTrackingManualGains = [&](float &panGain,
                                              float &pitchGain,
                                              int &panResult,
                                              int &pitchResult) {
        try {
            panResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePanGainValue,
                panGain
            );
            pitchResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePitchGainValue,
                pitchGain
            );
        } catch (...) {
            panResult = RM_RET_ERR;
            pitchResult = RM_RET_ERR;
        }
        return panResult == RM_RET_OK && pitchResult == RM_RET_OK;
    };
    auto setNativeTrackingManualGains = [&](float panGain,
                                             float pitchGain,
                                             int &panResult,
                                             int &pitchResult) {
        try {
            panResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePanGainValue,
                panGain
            );
            pitchResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePitchGainValue,
                pitchGain
            );
        } catch (...) {
            panResult = RM_RET_ERR;
            pitchResult = RM_RET_ERR;
        }
        return panResult == RM_RET_OK && pitchResult == RM_RET_OK;
    };
    NativeHumanTrackingPolicy baselineNativeTrackingPolicy;
    NativeHumanTrackingPolicy verifiedNativeTrackingPolicy;
    NativeHumanTrackingPolicy restoredNativeTrackingPolicy;
    int nativeTrackingBaselineSpeedResult = RM_RET_ERR;
    int nativeTrackingBaselineMotionResult = RM_RET_ERR;
    int nativeTrackingBaselineForeResult = RM_RET_ERR;
    int nativeTrackingBaselineCompositionResult = RM_RET_ERR;
    const bool nativeTrackingBaselineReadable = readNativeTrackingPolicy(
        baselineNativeTrackingPolicy,
        nativeTrackingBaselineSpeedResult,
        nativeTrackingBaselineMotionResult,
        nativeTrackingBaselineForeResult,
        nativeTrackingBaselineCompositionResult
    );
    bool baselinePanGainAdaptive = false;
    bool baselinePitchGainAdaptive = false;
    int baselinePanGainAdaptiveResult = RM_RET_ERR;
    int baselinePitchGainAdaptiveResult = RM_RET_ERR;
    const bool nativeTrackingAdaptiveGainBaselineReadable = readNativeTrackingAdaptiveGains(
        baselinePanGainAdaptive,
        baselinePitchGainAdaptive,
        baselinePanGainAdaptiveResult,
        baselinePitchGainAdaptiveResult
    );
    float baselineNativePanGain = 0;
    float baselineNativePitchGain = 0;
    int baselineNativePanGainResult = RM_RET_ERR;
    int baselineNativePitchGainResult = RM_RET_ERR;
    const bool nativeTrackingManualGainBaselineReadable = readNativeTrackingManualGains(
        baselineNativePanGain,
        baselineNativePitchGain,
        baselineNativePanGainResult,
        baselineNativePitchGainResult
    );
    bool verifiedPanGainAdaptive = false;
    bool verifiedPitchGainAdaptive = false;
    bool restoredPanGainAdaptive = false;
    bool restoredPitchGainAdaptive = false;
    int adaptiveGainSetPanResult = RM_RET_OK;
    int adaptiveGainSetPitchResult = RM_RET_OK;
    int adaptiveGainVerifyPanResult = RM_RET_OK;
    int adaptiveGainVerifyPitchResult = RM_RET_OK;
    int adaptiveGainRestorePanResult = RM_RET_OK;
    int adaptiveGainRestorePitchResult = RM_RET_OK;
    int adaptiveGainRestoredPanResult = RM_RET_OK;
    int adaptiveGainRestoredPitchResult = RM_RET_OK;
    bool nativeTrackingAdaptiveGainVerified = false;
    bool nativeTrackingAdaptiveGainRestored = false;
    if (requestedNativeTrackingAdaptiveGainVerification && nativeTrackingAdaptiveGainBaselineReadable) {
        const bool set = setNativeTrackingAdaptiveGains(
            (*requestedNativeTrackingAdaptiveGainVerification)[0],
            (*requestedNativeTrackingAdaptiveGainVerification)[1],
            adaptiveGainSetPanResult,
            adaptiveGainSetPitchResult
        );
        if (set) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            const bool read = readNativeTrackingAdaptiveGains(
                verifiedPanGainAdaptive,
                verifiedPitchGainAdaptive,
                adaptiveGainVerifyPanResult,
                adaptiveGainVerifyPitchResult
            );
            nativeTrackingAdaptiveGainVerified = read
                && verifiedPanGainAdaptive == (*requestedNativeTrackingAdaptiveGainVerification)[0]
                && verifiedPitchGainAdaptive == (*requestedNativeTrackingAdaptiveGainVerification)[1];
        }
        const bool restoredSet = setNativeTrackingAdaptiveGains(
            baselinePanGainAdaptive,
            baselinePitchGainAdaptive,
            adaptiveGainRestorePanResult,
            adaptiveGainRestorePitchResult
        );
        if (restoredSet) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            const bool restoredRead = readNativeTrackingAdaptiveGains(
                restoredPanGainAdaptive,
                restoredPitchGainAdaptive,
                adaptiveGainRestoredPanResult,
                adaptiveGainRestoredPitchResult
            );
            nativeTrackingAdaptiveGainRestored = restoredRead
                && restoredPanGainAdaptive == baselinePanGainAdaptive
                && restoredPitchGainAdaptive == baselinePitchGainAdaptive;
        }
    }
    float verifiedNativePanGain = 0;
    float verifiedNativePitchGain = 0;
    float restoredNativePanGain = 0;
    float restoredNativePitchGain = 0;
    int manualGainSetPanResult = RM_RET_OK;
    int manualGainSetPitchResult = RM_RET_OK;
    int manualGainVerifyPanResult = RM_RET_OK;
    int manualGainVerifyPitchResult = RM_RET_OK;
    int manualGainRestorePanResult = RM_RET_OK;
    int manualGainRestorePitchResult = RM_RET_OK;
    int manualGainRestoredPanResult = RM_RET_OK;
    int manualGainRestoredPitchResult = RM_RET_OK;
    bool nativeTrackingManualGainVerified = false;
    bool nativeTrackingManualGainRestored = false;
    if (requestedNativeTrackingManualGainVerification && nativeTrackingManualGainBaselineReadable) {
        const bool set = setNativeTrackingManualGains(
            (*requestedNativeTrackingManualGainVerification)[0],
            (*requestedNativeTrackingManualGainVerification)[1],
            manualGainSetPanResult,
            manualGainSetPitchResult
        );
        if (set) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            const bool read = readNativeTrackingManualGains(
                verifiedNativePanGain,
                verifiedNativePitchGain,
                manualGainVerifyPanResult,
                manualGainVerifyPitchResult
            );
            nativeTrackingManualGainVerified = read
                && std::fabs(verifiedNativePanGain - (*requestedNativeTrackingManualGainVerification)[0]) < 0.0001f
                && std::fabs(verifiedNativePitchGain - (*requestedNativeTrackingManualGainVerification)[1]) < 0.0001f;
        }
        const bool restoredSet = setNativeTrackingManualGains(
            baselineNativePanGain,
            baselineNativePitchGain,
            manualGainRestorePanResult,
            manualGainRestorePitchResult
        );
        if (restoredSet) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            const bool restoredRead = readNativeTrackingManualGains(
                restoredNativePanGain,
                restoredNativePitchGain,
                manualGainRestoredPanResult,
                manualGainRestoredPitchResult
            );
            nativeTrackingManualGainRestored = restoredRead
                && std::fabs(restoredNativePanGain - baselineNativePanGain) < 0.0001f
                && std::fabs(restoredNativePitchGain - baselineNativePitchGain) < 0.0001f;
        }
    }
    int nativeTrackingSetSpeedResult = RM_RET_OK;
    int nativeTrackingSetMotionResult = RM_RET_OK;
    int nativeTrackingSetForeResult = RM_RET_OK;
    int nativeTrackingSetCompositionResult = RM_RET_OK;
    int nativeTrackingVerifySpeedResult = RM_RET_OK;
    int nativeTrackingVerifyMotionResult = RM_RET_OK;
    int nativeTrackingVerifyForeResult = RM_RET_OK;
    int nativeTrackingVerifyCompositionResult = RM_RET_OK;
    int nativeTrackingRestoreSpeedResult = RM_RET_OK;
    int nativeTrackingRestoreMotionResult = RM_RET_OK;
    int nativeTrackingRestoreForeResult = RM_RET_OK;
    int nativeTrackingRestoreCompositionResult = RM_RET_OK;
    int nativeTrackingRestoredSpeedResult = RM_RET_OK;
    int nativeTrackingRestoredMotionResult = RM_RET_OK;
    int nativeTrackingRestoredForeResult = RM_RET_OK;
    int nativeTrackingRestoredCompositionResult = RM_RET_OK;
    bool nativeTrackingPolicyVerified = false;
    bool nativeTrackingPolicyRestored = false;
    if (requestedNativeTrackingPolicyVerification && nativeTrackingBaselineReadable) {
        const bool set = setNativeTrackingPolicy(
            *requestedNativeTrackingPolicyVerification,
            nativeTrackingSetSpeedResult,
            nativeTrackingSetMotionResult,
            nativeTrackingSetForeResult,
            nativeTrackingSetCompositionResult
        );
        if (set) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            const bool read = readNativeTrackingPolicy(
                verifiedNativeTrackingPolicy,
                nativeTrackingVerifySpeedResult,
                nativeTrackingVerifyMotionResult,
                nativeTrackingVerifyForeResult,
                nativeTrackingVerifyCompositionResult
            );
            nativeTrackingPolicyVerified = read
                && verifiedNativeTrackingPolicy.speedMode == requestedNativeTrackingPolicyVerification->speedMode
                && verifiedNativeTrackingPolicy.motionTracking == requestedNativeTrackingPolicyVerification->motionTracking
                && verifiedNativeTrackingPolicy.foreTarget == requestedNativeTrackingPolicyVerification->foreTarget
                && verifiedNativeTrackingPolicy.adaptiveComposition == requestedNativeTrackingPolicyVerification->adaptiveComposition;
        }
        const bool restoredSet = setNativeTrackingPolicy(
            baselineNativeTrackingPolicy,
            nativeTrackingRestoreSpeedResult,
            nativeTrackingRestoreMotionResult,
            nativeTrackingRestoreForeResult,
            nativeTrackingRestoreCompositionResult
        );
        if (restoredSet) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            const bool restoredRead = readNativeTrackingPolicy(
                restoredNativeTrackingPolicy,
                nativeTrackingRestoredSpeedResult,
                nativeTrackingRestoredMotionResult,
                nativeTrackingRestoredForeResult,
                nativeTrackingRestoredCompositionResult
            );
            nativeTrackingPolicyRestored = restoredRead
                && restoredNativeTrackingPolicy.speedMode == baselineNativeTrackingPolicy.speedMode
                && restoredNativeTrackingPolicy.motionTracking == baselineNativeTrackingPolicy.motionTracking
                && restoredNativeTrackingPolicy.foreTarget == baselineNativeTrackingPolicy.foreTarget
                && restoredNativeTrackingPolicy.adaptiveComposition == baselineNativeTrackingPolicy.adaptiveComposition;
        }
    } else if (requestedNativeTrackingPolicyVerification) {
        nativeTrackingSetSpeedResult = RM_RET_ERR;
        nativeTrackingSetMotionResult = RM_RET_ERR;
        nativeTrackingSetForeResult = RM_RET_ERR;
        nativeTrackingSetCompositionResult = RM_RET_ERR;
        nativeTrackingVerifySpeedResult = RM_RET_ERR;
        nativeTrackingVerifyMotionResult = RM_RET_ERR;
        nativeTrackingVerifyForeResult = RM_RET_ERR;
        nativeTrackingVerifyCompositionResult = RM_RET_ERR;
        nativeTrackingRestoreSpeedResult = RM_RET_ERR;
        nativeTrackingRestoreMotionResult = RM_RET_ERR;
        nativeTrackingRestoreForeResult = RM_RET_ERR;
        nativeTrackingRestoreCompositionResult = RM_RET_ERR;
        nativeTrackingRestoredSpeedResult = RM_RET_ERR;
        nativeTrackingRestoredMotionResult = RM_RET_ERR;
        nativeTrackingRestoredForeResult = RM_RET_ERR;
        nativeTrackingRestoredCompositionResult = RM_RET_ERR;
    }
    const uint8_t baselineFaceAutoFocus = statusResult == RM_RET_OK ? status.tiny.face_auto_focus : 0;
    const uint8_t baselineFaceAE = statusResult == RM_RET_OK ? status.tiny.face_ae : 0;
    int faceFocusSetResult = RM_RET_OK;
    int faceAESetResult = RM_RET_OK;
    int facePriorityVerifyResult = RM_RET_OK;
    int faceFocusRestoreResult = RM_RET_OK;
    int faceAERestoreResult = RM_RET_OK;
    int facePriorityRestoredResult = RM_RET_OK;
    bool facePriorityVerified = false;
    bool facePriorityRestored = false;
    uint8_t verifiedFaceAutoFocus = 0;
    uint8_t verifiedFaceAE = 0;
    uint8_t restoredFaceAutoFocus = 0;
    uint8_t restoredFaceAE = 0;
    if (requestedFacePriorityVerification) {
        try { faceFocusSetResult = device->cameraSetFaceFocusR(*requestedFacePriorityVerification); } catch (...) {
            faceFocusSetResult = RM_RET_ERR;
        }
        try { faceAESetResult = device->cameraSetFaceAER(*requestedFacePriorityVerification ? 1 : 0); } catch (...) {
            faceAESetResult = RM_RET_ERR;
        }
        if (faceFocusSetResult == RM_RET_OK && faceAESetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            Device::CameraStatus verifiedStatus {};
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { facePriorityVerifyResult = device->cameraGetCameraStatusU(verifiedStatus); } catch (...) {
                    facePriorityVerifyResult = RM_RET_ERR;
                }
                if (facePriorityVerifyResult == RM_RET_OK) {
                    verifiedFaceAutoFocus = verifiedStatus.tiny.face_auto_focus;
                    verifiedFaceAE = verifiedStatus.tiny.face_ae;
                    if (verifiedFaceAutoFocus == (*requestedFacePriorityVerification ? 1 : 0)
                        && verifiedFaceAE == (*requestedFacePriorityVerification ? 1 : 0)) {
                        facePriorityVerified = true;
                        break;
                    }
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        if (statusResult == RM_RET_OK) {
            try { faceFocusRestoreResult = device->cameraSetFaceFocusR(baselineFaceAutoFocus != 0); } catch (...) {
                faceFocusRestoreResult = RM_RET_ERR;
            }
            try { faceAERestoreResult = device->cameraSetFaceAER(baselineFaceAE != 0 ? 1 : 0); } catch (...) {
                faceAERestoreResult = RM_RET_ERR;
            }
            if (faceFocusRestoreResult == RM_RET_OK && faceAERestoreResult == RM_RET_OK) {
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
                Device::CameraStatus restoredStatus {};
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    try { facePriorityRestoredResult = device->cameraGetCameraStatusU(restoredStatus); } catch (...) {
                        facePriorityRestoredResult = RM_RET_ERR;
                    }
                    if (facePriorityRestoredResult == RM_RET_OK) {
                        restoredFaceAutoFocus = restoredStatus.tiny.face_auto_focus;
                        restoredFaceAE = restoredStatus.tiny.face_ae;
                        if (restoredFaceAutoFocus == baselineFaceAutoFocus && restoredFaceAE == baselineFaceAE) {
                            facePriorityRestored = true;
                            break;
                        }
                    }
                } while (std::chrono::steady_clock::now() < deadline);
            }
        } else {
            faceFocusRestoreResult = RM_RET_ERR;
            faceAERestoreResult = RM_RET_ERR;
            facePriorityRestoredResult = RM_RET_ERR;
        }
    }
    int32_t baselineAntiFlicker = -1;
    int baselineAntiFlickerResult = RM_RET_ERR;
    try { baselineAntiFlickerResult = device->cameraGetAntiFlickR(baselineAntiFlicker); } catch (...) {
        baselineAntiFlickerResult = RM_RET_ERR;
    }
    int antiFlickerSetResult = RM_RET_OK;
    int antiFlickerVerifyResult = RM_RET_OK;
    int antiFlickerRestoreResult = RM_RET_OK;
    int antiFlickerRestoredResult = RM_RET_OK;
    int32_t verifiedAntiFlicker = -1;
    int32_t restoredAntiFlicker = -1;
    bool antiFlickerVerified = false;
    bool antiFlickerRestored = false;
    if (requestedAntiFlickerVerification) {
        try { antiFlickerSetResult = device->cameraSetAntiFlickR(*requestedAntiFlickerVerification); } catch (...) {
            antiFlickerSetResult = RM_RET_ERR;
        }
        if (antiFlickerSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { antiFlickerVerifyResult = device->cameraGetAntiFlickR(verifiedAntiFlicker); } catch (...) {
                    antiFlickerVerifyResult = RM_RET_ERR;
                }
                if (antiFlickerVerifyResult == RM_RET_OK
                    && verifiedAntiFlicker == *requestedAntiFlickerVerification) {
                    antiFlickerVerified = true;
                    break;
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        if (baselineAntiFlickerResult == RM_RET_OK) {
            try { antiFlickerRestoreResult = device->cameraSetAntiFlickR(baselineAntiFlicker); } catch (...) {
                antiFlickerRestoreResult = RM_RET_ERR;
            }
            if (antiFlickerRestoreResult == RM_RET_OK) {
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    try { antiFlickerRestoredResult = device->cameraGetAntiFlickR(restoredAntiFlicker); } catch (...) {
                        antiFlickerRestoredResult = RM_RET_ERR;
                    }
                    if (antiFlickerRestoredResult == RM_RET_OK && restoredAntiFlicker == baselineAntiFlicker) {
                        antiFlickerRestored = true;
                        break;
                    }
                } while (std::chrono::steady_clock::now() < deadline);
            }
        } else {
            antiFlickerRestoreResult = RM_RET_ERR;
            antiFlickerRestoredResult = RM_RET_ERR;
        }
    }
    const Device::FovType baselineFOV = statusResult == RM_RET_OK
        ? static_cast<Device::FovType>(status.tiny.fov)
        : Device::FovTypeNull;
    Device::FovType verifiedFOV = Device::FovTypeNull;
    Device::FovType restoredFOV = Device::FovTypeNull;
    int fovSetResult = RM_RET_OK;
    int fovVerifyResult = RM_RET_OK;
    int fovRestoreResult = RM_RET_OK;
    int fovRestoredResult = RM_RET_OK;
    bool fovVerified = false;
    bool fovRestored = false;
    if (requestedFOVVerification) {
        try { fovSetResult = device->cameraSetFovU(*requestedFOVVerification); } catch (...) {
            fovSetResult = RM_RET_ERR;
        }
        if (fovSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            Device::CameraStatus verifiedStatus {};
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { fovVerifyResult = device->cameraGetCameraStatusU(verifiedStatus); } catch (...) {
                    fovVerifyResult = RM_RET_ERR;
                }
                if (fovVerifyResult == RM_RET_OK) {
                    verifiedFOV = static_cast<Device::FovType>(verifiedStatus.tiny.fov);
                    if (verifiedFOV == *requestedFOVVerification) {
                        fovVerified = true;
                        break;
                    }
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        if (statusResult == RM_RET_OK && baselineFOV != Device::FovTypeNull) {
            try { fovRestoreResult = device->cameraSetFovU(baselineFOV); } catch (...) {
                fovRestoreResult = RM_RET_ERR;
            }
            if (fovRestoreResult == RM_RET_OK) {
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
                Device::CameraStatus restoredStatus {};
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    try { fovRestoredResult = device->cameraGetCameraStatusU(restoredStatus); } catch (...) {
                        fovRestoredResult = RM_RET_ERR;
                    }
                    if (fovRestoredResult == RM_RET_OK) {
                        restoredFOV = static_cast<Device::FovType>(restoredStatus.tiny.fov);
                        if (restoredFOV == baselineFOV) {
                            fovRestored = true;
                            break;
                        }
                    }
                } while (std::chrono::steady_clock::now() < deadline);
            }
        } else {
            fovRestoreResult = RM_RET_ERR;
            fovRestoredResult = RM_RET_ERR;
        }
    }
    using SetDoaFindBack = int32_t (*)(Device *, uint8_t);
    const auto setDoaFindBack = reinterpret_cast<SetDoaFindBack>(
        dlsym(RTLD_DEFAULT, "_ZN6Device20cameraSetDoaFindBackEh")
    );
    const bool baselineDoaFindBack = statusResult == RM_RET_OK && status.tiny.doa_set.doa_find_back != 0;
    bool verifiedDoaFindBack = false;
    bool restoredDoaFindBack = false;
    int doaFindBackSetResult = RM_RET_OK;
    int doaFindBackVerifyResult = RM_RET_OK;
    int doaFindBackRestoreResult = RM_RET_OK;
    int doaFindBackRestoredResult = RM_RET_OK;
    bool doaFindBackVerified = false;
    bool doaFindBackRestored = false;
    if (requestedDoaFindBackVerification) {
        if (setDoaFindBack) {
            try { doaFindBackSetResult = setDoaFindBack(device.get(), *requestedDoaFindBackVerification ? 1 : 0); } catch (...) {
                doaFindBackSetResult = RM_RET_ERR;
            }
        } else {
            doaFindBackSetResult = RM_RET_ERR;
        }
        if (doaFindBackSetResult == RM_RET_OK) {
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
            Device::CameraStatus verifiedStatus {};
            do {
                std::this_thread::sleep_for(std::chrono::milliseconds(50));
                try { doaFindBackVerifyResult = device->cameraGetCameraStatusU(verifiedStatus); } catch (...) {
                    doaFindBackVerifyResult = RM_RET_ERR;
                }
                if (doaFindBackVerifyResult == RM_RET_OK) {
                    verifiedDoaFindBack = verifiedStatus.tiny.doa_set.doa_find_back != 0;
                    if (verifiedDoaFindBack == *requestedDoaFindBackVerification) {
                        doaFindBackVerified = true;
                        break;
                    }
                }
            } while (std::chrono::steady_clock::now() < deadline);
        }
        if (statusResult == RM_RET_OK && setDoaFindBack) {
            try { doaFindBackRestoreResult = setDoaFindBack(device.get(), baselineDoaFindBack ? 1 : 0); } catch (...) {
                doaFindBackRestoreResult = RM_RET_ERR;
            }
            if (doaFindBackRestoreResult == RM_RET_OK) {
                const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(1'500);
                Device::CameraStatus restoredStatus {};
                do {
                    std::this_thread::sleep_for(std::chrono::milliseconds(50));
                    try { doaFindBackRestoredResult = device->cameraGetCameraStatusU(restoredStatus); } catch (...) {
                        doaFindBackRestoredResult = RM_RET_ERR;
                    }
                    if (doaFindBackRestoredResult == RM_RET_OK) {
                        restoredDoaFindBack = restoredStatus.tiny.doa_set.doa_find_back != 0;
                        if (restoredDoaFindBack == baselineDoaFindBack) {
                            doaFindBackRestored = true;
                            break;
                        }
                    }
                } while (std::chrono::steady_clock::now() < deadline);
            }
        } else {
            doaFindBackRestoreResult = RM_RET_ERR;
            doaFindBackRestoredResult = RM_RET_ERR;
        }
    }
    float attitudeXYZ[3] = {};
    const int attitudeResult = device->gimbalGetAttitudeInfoR(attitudeXYZ);
    using GetLedEnabled = int32_t (*)(Device *, bool &);
    using GetLedBrightness = int32_t (*)(Device *, uint8_t &);
    using SetLedEnabled = int32_t (*)(Device *, bool);
    using GetGimbalAllInfo = int32_t (*)(Device *, Device::AiGimbalStatus &);
    using GetGimbalInfo = int32_t (*)(Device *, Device::GimbalInfo &, Device::GimbalInfo &);
    const auto getLedEnabled = reinterpret_cast<GetLedEnabled>(
        dlsym(RTLD_DEFAULT, "_ZN6Device19sysMgGetLedEnabledRERb")
    );
    const auto getLedBrightness = reinterpret_cast<GetLedBrightness>(
        dlsym(RTLD_DEFAULT, "_ZN6Device22sysMgGetLedBrightnessRERh")
    );
    const auto setLedEnabled = reinterpret_cast<SetLedEnabled>(
        dlsym(RTLD_DEFAULT, "_ZN6Device19sysMgSetLedEnabledREb")
    );
    const auto getGimbalAllInfo = reinterpret_cast<GetGimbalAllInfo>(
        dlsym(RTLD_DEFAULT, "_ZN6Device16gimbalGetAllInfoERNS_14AiGimbalStatusE")
    );
    const auto getGimbalInfo = reinterpret_cast<GetGimbalInfo>(
        dlsym(RTLD_DEFAULT, "_ZN6Device14gimbalGetInfoRERNS_10GimbalInfoES1_")
    );
    Device::GimbalInfo gimbalTrackingRequest {};
    Device::GimbalInfo gimbalTrackingResponse {};
    int gimbalTrackingInfoResult = RM_RET_ERR;
    if (inspectGimbalTracking && getGimbalInfo) {
        try {
            gimbalTrackingInfoResult = getGimbalInfo(
                device.get(), gimbalTrackingRequest, gimbalTrackingResponse
            );
        } catch (...) {
            gimbalTrackingInfoResult = RM_RET_ERR;
        }
    }
    bool panGainAdaptive = false;
    float panGain = 0;
    bool pitchGainAdaptive = false;
    float pitchGain = 0;
    int autoZoomSpeed = 0;
    int panGainAdaptiveResult = RM_RET_ERR;
    int panGainResult = RM_RET_ERR;
    int pitchGainAdaptiveResult = RM_RET_ERR;
    int pitchGainResult = RM_RET_ERR;
    int autoZoomSpeedResult = RM_RET_ERR;
    if (inspectNativeTrackingTuning) {
        try {
            panGainAdaptiveResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePanGainAdaptive,
                panGainAdaptive
            );
            panGainResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePanGainValue,
                panGain
            );
            pitchGainAdaptiveResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePitchGainAdaptive,
                pitchGainAdaptive
            );
            pitchGainResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePitchGainValue,
                pitchGain
            );
            autoZoomSpeedResult = device->aiGetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeAutoZoomSpeed,
                autoZoomSpeed
            );
        } catch (...) {
            panGainAdaptiveResult = RM_RET_ERR;
            panGainResult = RM_RET_ERR;
            pitchGainAdaptiveResult = RM_RET_ERR;
            pitchGainResult = RM_RET_ERR;
            autoZoomSpeedResult = RM_RET_ERR;
        }
    }
    bool ledEnabled = false;
    uint8_t ledBrightness = 0;
    const int ledEnabledResult = getLedEnabled ? getLedEnabled(device.get(), ledEnabled) : RM_RET_ERR;
    const int ledBrightnessResult = getLedBrightness ? getLedBrightness(device.get(), ledBrightness) : RM_RET_ERR;
    const bool baselineLedEnabled = ledEnabled;
    int ledSetResult = RM_RET_OK;
    if (requestedLedEnabled) {
        ledSetResult = setLedEnabled
            ? setLedEnabled(device.get(), *requestedLedEnabled)
            : RM_RET_ERR;
    }
    int indicatorSetResult = RM_RET_OK;
    int indicatorClearResult = RM_RET_OK;
    int indicatorRestoreResult = RM_RET_OK;
    int indicatorBaselineRestoreResult = RM_RET_OK;
    int indicatorBulkSetResult = RM_RET_OK;
    int indicatorBulkClearResult = RM_RET_OK;
    for (const uint8_t state : requestedIndicatorSets) {
        try {
            if (device->sysMgSetIndicatorStateR(state) != RM_RET_OK) {
                indicatorBulkSetResult = RM_RET_ERR;
            }
        } catch (...) {
            indicatorBulkSetResult = RM_RET_ERR;
        }
    }
    for (const uint8_t state : requestedIndicatorClears) {
        try {
            if (device->sysMgClearIndicatorStateR(state) != RM_RET_OK) {
                indicatorBulkClearResult = RM_RET_ERR;
            }
        } catch (...) {
            indicatorBulkClearResult = RM_RET_ERR;
        }
    }
    if (!requestedIndicatorClears.empty()) {
        indicatorBaselineRestoreResult = adapter.establishIndicatorBaseline(device.get());
    }
    if (requestedIndicatorState) {
        if (ledEnabledResult == RM_RET_OK && !baselineLedEnabled) {
            indicatorRestoreResult = setLedEnabled ? setLedEnabled(device.get(), true) : RM_RET_ERR;
        }
        if (indicatorRestoreResult == RM_RET_OK) {
            try {
                indicatorSetResult = device->sysMgSetIndicatorStateR(*requestedIndicatorState);
            } catch (...) {
                indicatorSetResult = RM_RET_ERR;
            }
            std::this_thread::sleep_for(indicatorStateHold);
            try {
                indicatorClearResult = device->sysMgClearIndicatorStateR(*requestedIndicatorState);
            } catch (...) {
                indicatorClearResult = RM_RET_ERR;
            }
            if (indicatorClearResult == RM_RET_OK) {
                indicatorBaselineRestoreResult = adapter.establishIndicatorBaseline(device.get());
            }
        } else {
            indicatorSetResult = RM_RET_ERR;
            indicatorClearResult = RM_RET_ERR;
        }
        if (ledEnabledResult == RM_RET_OK && !baselineLedEnabled && setLedEnabled) {
            indicatorRestoreResult = setLedEnabled(device.get(), false);
        }
    }
    int tallyBaselineResult = RM_RET_ERR;
    bool tallyBaselineEnabled = false;
    int32_t tallyBaselineBrightness = 0;
    bool batteryBaselineEnabled = false;
    int tallySetResult = RM_RET_OK;
    int tallyRestoreResult = RM_RET_OK;
    if (requestedTallyLight) {
        const auto setTally = reinterpret_cast<SetTallyLight>(
            dlsym(RTLD_DEFAULT, "_ZN6Device20cameraSetTallyLightREb")
        );
        const auto getTally = reinterpret_cast<GetTallyAndBatteryLight>(
            dlsym(RTLD_DEFAULT, "_ZN6Device30cameraGetTallyAndBatteryLightRERbRiS0_")
        );
        if (!setTally) {
            tallySetResult = RM_RET_ERR;
            tallyRestoreResult = RM_RET_ERR;
        } else {
            if (getTally) {
                try {
                    tallyBaselineResult = getTally(
                        device.get(), tallyBaselineEnabled, tallyBaselineBrightness, batteryBaselineEnabled
                    );
                } catch (...) {
                    tallyBaselineResult = RM_RET_ERR;
                }
            }
            try {
                tallySetResult = setTally(device.get(), requestedTallyLight->enabled);
            } catch (...) {
                tallySetResult = RM_RET_ERR;
            }
            std::this_thread::sleep_for(requestedTallyLight->hold);
            try {
                tallyRestoreResult = setTally(
                    device.get(), tallyBaselineResult == RM_RET_OK ? tallyBaselineEnabled : false
                );
            } catch (...) {
                tallyRestoreResult = RM_RET_ERR;
            }
        }
    }
    int32_t imageBrightness = 0;
    int32_t imageContrast = 0;
    int32_t imageHue = 0;
    int32_t imageSaturation = 0;
    int32_t imageSharpness = 0;
    int imageBrightnessResult = RM_RET_ERR;
    int imageContrastResult = RM_RET_ERR;
    int imageHueResult = RM_RET_ERR;
    int imageSaturationResult = RM_RET_ERR;
    int imageSharpnessResult = RM_RET_ERR;
    try {
        imageBrightnessResult = device->cameraGetImageBrightnessR(imageBrightness);
        imageContrastResult = device->cameraGetImageContrastR(imageContrast);
        imageHueResult = device->cameraGetImageHueR(imageHue);
        imageSaturationResult = device->cameraGetImageSaturationR(imageSaturation);
        imageSharpnessResult = device->cameraGetImageSharpR(imageSharpness);
    } catch (...) {
        imageBrightnessResult = RM_RET_ERR;
        imageContrastResult = RM_RET_ERR;
        imageHueResult = RM_RET_ERR;
        imageSaturationResult = RM_RET_ERR;
        imageSharpnessResult = RM_RET_ERR;
    }
    Device::AiGimbalStatus gimbalStatus {};
    const int gimbalStatusResult = getGimbalAllInfo
        ? getGimbalAllInfo(device.get(), gimbalStatus)
        : RM_RET_ERR;
    const auto &capabilities = adapter.contract();

    std::cout << "SOMA_OBSBOT_CAPABILITY contract=2"
              << " profile=" << capabilities.identifier
              << " product_type=" << static_cast<int>(device->productType())
              << " native_bridge=" << (capabilities.nativeBridge ? "true" : "false")
              << " motor_calibrated=" << (capabilities.calibratedMotorControl ? "true" : "false")
              << " bounded_calibration_pulses=" << (capabilities.boundedCalibrationPulses ? "true" : "false")
              << " native_human_tracking=" << (capabilities.nativeHumanTracking ? "true" : "false")
              << " indicator_palette=" << (capabilities.firmwareIndicatorPalette ? "true" : "false")
              << " indicator_default_green=" << (capabilities.firmwareDefaultIndicatorGreen ? "true" : "false")
              << " indicator_direct_rgb=" << (capabilities.directIndicatorColorMask != 0 ? "true" : "false")
              << " indicator_direct_rgb_mask=" << static_cast<int>(capabilities.directIndicatorColorMask)
              << " indicator_basic=" << (capabilities.indicatorEnableAndBrightness ? "true" : "false")
              << " indicator_pulse_transport=" << static_cast<int>(capabilities.indicatorPulseTransport)
              << " selectable_audio_modes=" << (capabilities.selectableAudioModes ? "true" : "false")
              << " supported_audio_mode_mask=" << static_cast<int>(capabilities.supportedAudioModeMask)
              << " sound_localization=" << (capabilities.soundLocalization ? "true" : "false")
              << " requires_measured_attitude_frame=" << (capabilities.requiresMeasuredAttitudeFrame ? "true" : "false")
              << " indicator_base_state_id=" << capabilities.indicatorBaseStateID
              << " indicator_yellow_state_id=" << capabilities.yellowIndicatorStateID
              << " indicator_green_state_id=" << capabilities.greenIndicatorStateID
              << " indicator_blue_state_id=" << capabilities.blueIndicatorStateID
              << " maximum_pan_degrees_per_second=" << capabilities.maximumPanDegreesPerSecond
              << " maximum_pitch_degrees_per_second=" << capabilities.maximumPitchDegreesPerSecond
              << " nominal_wide_horizontal_fov_degrees=" << capabilities.nominalWideHorizontalFieldOfViewDegrees
              << " native_tracking_transport=" << static_cast<int>(capabilities.nativeTrackingTransport)
              << " disable_native_tracking_result=" << (disableNativeTracking ? std::to_string(disableNativeTrackingResult) : "not_requested")
              << " firmware=" << device->devVersion()
              << " serial=" << device->devSn()
              << " attitude_pitch=" << (attitudeResult == RM_RET_OK ? std::to_string(attitudeXYZ[1]) : "unknown")
              << " attitude_pan=" << (attitudeResult == RM_RET_OK ? std::to_string(attitudeXYZ[2]) : "unknown")
              << " gimbal_status_result=" << gimbalStatusResult
              << " gimbal_lock=" << (gimbalStatusResult == RM_RET_OK ? std::to_string(gimbalStatus.lock) : "unknown")
              << " gimbal_system_status=" << (gimbalStatusResult == RM_RET_OK ? std::to_string(gimbalStatus.sys_status) : "unknown")
              << " gimbal_warning_flags=" << (gimbalStatusResult == RM_RET_OK ? std::to_string(gimbalStatus.warning_flag) : "unknown")
              << " gimbal_error_flags=" << (gimbalStatusResult == RM_RET_OK ? std::to_string(gimbalStatus.error_flag) : "unknown")
              << " gimbal_pan_range_mode=" << (gimbalStatusResult == RM_RET_OK ? std::to_string(gimbalStatus.pan_range_mode) : "unknown")
              << " gimbal_pitch_velocity=" << (gimbalStatusResult == RM_RET_OK ? std::to_string(gimbalStatus.pitch_v) : "unknown")
              << " gimbal_pan_velocity=" << (gimbalStatusResult == RM_RET_OK ? std::to_string(gimbalStatus.pan_v) : "unknown")
              << " gimbal_pitch_motor=" << (gimbalStatusResult == RM_RET_OK ? std::to_string(gimbalStatus.pitch_motor_d) : "unknown")
              << " gimbal_pan_motor=" << (gimbalStatusResult == RM_RET_OK ? std::to_string(gimbalStatus.pan_motor_d) : "unknown")
              << " device_status=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.dev_status) : "unknown")
              << " ai_mode=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.ai_mode) : "unknown")
              << " ai_sub_mode=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.ai_sub_mode) : "unknown")
              << " ai_target=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.ai_target) : "unknown")
              << " boot_mode=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.boot_mode) : "unknown")
              << " zoom_baseline_result=" << baselineZoomResult
              << " zoom_baseline=" << (baselineZoomResult == RM_RET_OK ? std::to_string(baselineZoom) : "unknown")
              << " zoom_requested=" << (requestedZoomVerification ? std::to_string(*requestedZoomVerification) : "not_requested")
              << " zoom_set_result=" << (requestedZoomVerification ? std::to_string(zoomSetResult) : "not_requested")
              << " zoom_verified_result=" << (requestedZoomVerification ? std::to_string(verifiedZoomResult) : "not_requested")
              << " zoom_verified=" << (requestedZoomVerification && verifiedZoomResult == RM_RET_OK ? std::to_string(verifiedZoom) : "not_available")
              << " zoom_restore_result=" << (requestedZoomVerification ? std::to_string(zoomRestoreResult) : "not_requested")
              << " zoom_restored_result=" << (requestedZoomVerification ? std::to_string(restoredZoomResult) : "not_requested")
              << " zoom_restored=" << (requestedZoomVerification && restoredZoomResult == RM_RET_OK ? std::to_string(restoredZoom) : "not_available")
              << " audio_mode=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.audio_mode.mode) : "unknown")
              << " audio_mode_source=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.audio_mode.source) : "unknown")
              << " audio_mode_requested=" << (requestedAudioModeVerification ? std::to_string(*requestedAudioModeVerification) : "not_requested")
              << " audio_mode_set_result=" << (requestedAudioModeVerification ? std::to_string(audioModeSetResult) : "not_requested")
              << " audio_mode_verified_result=" << (requestedAudioModeVerification ? std::to_string(audioModeVerifyResult) : "not_requested")
              << " audio_mode_verified=" << (requestedAudioModeVerification && audioModeVerifyResult == RM_RET_OK ? std::to_string(verifiedAudioMode) : "not_available")
              << " audio_mode_restore_result=" << (requestedAudioModeVerification ? std::to_string(audioModeRestoreResult) : "not_requested")
              << " audio_mode_restored_result=" << (requestedAudioModeVerification ? std::to_string(audioModeRestoredResult) : "not_requested")
              << " audio_mode_restored=" << (requestedAudioModeVerification && audioModeRestoredResult == RM_RET_OK ? std::to_string(restoredAudioMode) : "not_available")
              << " audio_vqe_baseline_result=" << audioVQEBaselineResult
              << " audio_vqe_baseline=" << (audioVQEBaselineResult == RM_RET_OK ? std::to_string(static_cast<int>(baselineAudioVQE)) : "unknown")
              << " audio_vqe_requested=" << (requestedAudioVQEVerification ? std::to_string(static_cast<int>(*requestedAudioVQEVerification)) : "not_requested")
              << " audio_vqe_set_result=" << (requestedAudioVQEVerification ? std::to_string(audioVQESetResult) : "not_requested")
              << " audio_vqe_verified=" << (requestedAudioVQEVerification && audioVQEVerified ? "true" : "false")
              << " audio_vqe_verify_result=" << (requestedAudioVQEVerification ? std::to_string(audioVQEVerifyResult) : "not_requested")
              << " audio_vqe_restore_result=" << (requestedAudioVQEVerification ? std::to_string(audioVQERestoreResult) : "not_requested")
              << " audio_vqe_restored=" << (requestedAudioVQEVerification && audioVQERestored ? "true" : "false")
              << " audio_vqe_restored_result=" << (requestedAudioVQEVerification ? std::to_string(audioVQERestoredResult) : "not_requested")
              << " audio_volume_baseline_result=" << audioVolumeBaselineResult
              << " audio_volume_baseline=" << (audioVolumeBaselineResult == RM_RET_OK ? std::to_string(baselineAudioVolume) : "unknown")
              << " audio_volume_requested=" << (requestedAudioVolumeVerification ? std::to_string(*requestedAudioVolumeVerification) : "not_requested")
              << " audio_volume_set_result=" << (requestedAudioVolumeVerification ? std::to_string(audioVolumeSetResult) : "not_requested")
              << " audio_volume_verified=" << (requestedAudioVolumeVerification && audioVolumeVerified ? "true" : "false")
              << " audio_volume_verify_result=" << (requestedAudioVolumeVerification ? std::to_string(audioVolumeVerifyResult) : "not_requested")
              << " audio_volume_restore_result=" << (requestedAudioVolumeVerification ? std::to_string(audioVolumeRestoreResult) : "not_requested")
              << " audio_volume_restored=" << (requestedAudioVolumeVerification && audioVolumeRestored ? "true" : "false")
              << " audio_volume_restored_result=" << (requestedAudioVolumeVerification ? std::to_string(audioVolumeRestoredResult) : "not_requested")
              << " audio_distance_baseline=" << (statusResult == RM_RET_OK ? std::to_string(baselineAudioDistance) : "unknown")
              << " audio_distance_requested=" << (requestedAudioDistanceVerification ? std::to_string(*requestedAudioDistanceVerification) : "not_requested")
              << " audio_distance_set_result=" << (requestedAudioDistanceVerification ? std::to_string(audioDistanceSetResult) : "not_requested")
              << " audio_distance_verified_result=" << (requestedAudioDistanceVerification ? std::to_string(audioDistanceVerifyResult) : "not_requested")
              << " audio_distance_verified=" << (requestedAudioDistanceVerification && audioDistanceVerifyResult == RM_RET_OK ? std::to_string(verifiedAudioDistance) : "not_available")
              << " audio_distance_restore_result=" << (requestedAudioDistanceVerification ? std::to_string(audioDistanceRestoreResult) : "not_requested")
              << " audio_distance_restored_result=" << (requestedAudioDistanceVerification ? std::to_string(audioDistanceRestoredResult) : "not_requested")
              << " audio_distance_restored=" << (requestedAudioDistanceVerification && audioDistanceRestoredResult == RM_RET_OK ? std::to_string(restoredAudioDistance) : "not_available")
              << " doa_range_requested=" << (requestedDoaRangeVerification ? std::to_string(*requestedDoaRangeVerification) : "not_requested")
              << " doa_range_set_result=" << (requestedDoaRangeVerification ? std::to_string(doaRangeSetResult) : "not_requested")
              << " doa_range_verified_result=" << (requestedDoaRangeVerification ? std::to_string(doaRangeVerifyResult) : "not_requested")
              << " doa_range_verified=" << (requestedDoaRangeVerification && doaRangeVerifyResult == RM_RET_OK ? std::to_string(verifiedDoaRange) : "not_available")
              << " doa_range_restore_result=" << (requestedDoaRangeVerification ? std::to_string(doaRangeRestoreResult) : "not_requested")
              << " doa_range_restored_result=" << (requestedDoaRangeVerification && doaRangeRestoredResult == RM_RET_OK ? std::to_string(restoredDoaRange) : "not_available")
              << " white_balance_baseline_result=" << baselineWhiteBalanceResult
              << " white_balance_baseline=" << (baselineWhiteBalanceResult == RM_RET_OK ? std::to_string(static_cast<int>(baselineWhiteBalance)) : "unknown")
              << " white_balance_baseline_parameter=" << (baselineWhiteBalanceResult == RM_RET_OK ? std::to_string(baselineWhiteBalanceParameter) : "unknown")
              << " white_balance_requested=" << (requestedManualWhiteBalanceVerification ? std::to_string(*requestedManualWhiteBalanceVerification) : "not_requested")
              << " white_balance_set_result=" << (requestedManualWhiteBalanceVerification ? std::to_string(manualWhiteBalanceSetResult) : "not_requested")
              << " white_balance_verified=" << (requestedManualWhiteBalanceVerification && manualWhiteBalanceVerified ? "true" : "false")
              << " white_balance_verified_result=" << (requestedManualWhiteBalanceVerification ? std::to_string(manualWhiteBalanceVerifyResult) : "not_requested")
              << " white_balance_verified_type=" << (requestedManualWhiteBalanceVerification && manualWhiteBalanceVerifyResult == RM_RET_OK ? std::to_string(static_cast<int>(verifiedWhiteBalance)) : "not_available")
              << " white_balance_verified_parameter=" << (requestedManualWhiteBalanceVerification && manualWhiteBalanceVerifyResult == RM_RET_OK ? std::to_string(verifiedWhiteBalanceParameter) : "not_available")
              << " white_balance_restore_result=" << (requestedManualWhiteBalanceVerification ? std::to_string(manualWhiteBalanceRestoreResult) : "not_requested")
              << " white_balance_restored=" << (requestedManualWhiteBalanceVerification && manualWhiteBalanceRestored ? "true" : "false")
              << " white_balance_restored_result=" << (requestedManualWhiteBalanceVerification ? std::to_string(manualWhiteBalanceRestoredResult) : "not_requested")
              << " white_balance_restored_type=" << (requestedManualWhiteBalanceVerification && manualWhiteBalanceRestoredResult == RM_RET_OK ? std::to_string(static_cast<int>(restoredWhiteBalance)) : "not_available")
              << " white_balance_restored_parameter=" << (requestedManualWhiteBalanceVerification && manualWhiteBalanceRestoredResult == RM_RET_OK ? std::to_string(restoredWhiteBalanceParameter) : "not_available")
              << " ae_lock_baseline_result=" << baselineExposureLockResult
              << " ae_lock_baseline=" << (baselineExposureLockResult == RM_RET_OK ? (baselineExposureLock ? "true" : "false") : "unknown")
              << " ae_lock_requested=" << (requestedExposureLockVerification ? (*requestedExposureLockVerification ? "true" : "false") : "not_requested")
              << " ae_lock_set_result=" << (requestedExposureLockVerification ? std::to_string(exposureLockSetResult) : "not_requested")
              << " ae_lock_verified=" << (requestedExposureLockVerification && exposureLockVerified ? "true" : "false")
              << " ae_lock_verified_result=" << (requestedExposureLockVerification ? std::to_string(exposureLockVerifyResult) : "not_requested")
              << " ae_lock_restore_result=" << (requestedExposureLockVerification ? std::to_string(exposureLockRestoreResult) : "not_requested")
              << " ae_lock_restored=" << (requestedExposureLockVerification && exposureLockRestored ? "true" : "false")
              << " ae_lock_restored_result=" << (requestedExposureLockVerification ? std::to_string(exposureLockRestoredResult) : "not_requested")
              << " autofocus_baseline_result=" << baselineAutoFocusResult
              << " autofocus_baseline=" << (baselineAutoFocusResult == RM_RET_OK ? std::to_string(static_cast<int>(baselineAutoFocus)) : "unknown")
              << " autofocus_requested=" << (requestedAutoFocusVerification ? std::to_string(static_cast<int>(*requestedAutoFocusVerification)) : "not_requested")
              << " autofocus_set_result=" << (requestedAutoFocusVerification ? std::to_string(autoFocusSetResult) : "not_requested")
              << " autofocus_verified=" << (requestedAutoFocusVerification && autoFocusVerified ? "true" : "false")
              << " autofocus_verified_result=" << (requestedAutoFocusVerification ? std::to_string(autoFocusVerifyResult) : "not_requested")
              << " autofocus_verified_value=" << (requestedAutoFocusVerification && autoFocusVerifyResult == RM_RET_OK ? std::to_string(static_cast<int>(verifiedAutoFocus)) : "not_available")
              << " autofocus_restore_result=" << (requestedAutoFocusVerification ? std::to_string(autoFocusRestoreResult) : "not_requested")
              << " autofocus_restored=" << (requestedAutoFocusVerification && autoFocusRestored ? "true" : "false")
              << " autofocus_restored_result=" << (requestedAutoFocusVerification ? std::to_string(autoFocusRestoredResult) : "not_requested")
              << " autofocus_restored_value=" << (requestedAutoFocusVerification && autoFocusRestoredResult == RM_RET_OK ? std::to_string(static_cast<int>(restoredAutoFocus)) : "not_available")
              << " absolute_focus_baseline_result=" << baselineAbsoluteFocusResult
              << " absolute_focus_baseline=" << (baselineAbsoluteFocusResult == RM_RET_OK ? std::to_string(baselineAbsoluteFocus) + "," + (baselineAbsoluteFocusAutomatic ? "auto" : "manual") : "unknown")
              << " absolute_focus_requested=" << (requestedAbsoluteFocusVerification ? std::to_string(requestedAbsoluteFocusVerification->position) + "," + (requestedAbsoluteFocusVerification->automatic ? "auto" : "manual") : "not_requested")
              << " absolute_focus_set_result=" << (requestedAbsoluteFocusVerification ? std::to_string(absoluteFocusSetResult) : "not_requested")
              << " absolute_focus_verified=" << (requestedAbsoluteFocusVerification && absoluteFocusVerified ? "true" : "false")
              << " absolute_focus_restore_result=" << (requestedAbsoluteFocusVerification ? std::to_string(absoluteFocusRestoreResult) : "not_requested")
              << " absolute_focus_restored=" << (requestedAbsoluteFocusVerification && absoluteFocusRestored ? "true" : "false")
              << " absolute_exposure_baseline_result=" << baselineAbsoluteExposureResult
              << " absolute_exposure_baseline=" << (baselineAbsoluteExposureResult == RM_RET_OK ? std::to_string(baselineAbsoluteExposure) + "," + (baselineAbsoluteExposureAutomatic ? "auto" : "manual") : "unknown")
              << " absolute_exposure_requested=" << (requestedAbsoluteExposureVerification ? std::to_string(requestedAbsoluteExposureVerification->shutter) + "," + (requestedAbsoluteExposureVerification->automatic ? "auto" : "manual") : "not_requested")
              << " absolute_exposure_set_result=" << (requestedAbsoluteExposureVerification ? std::to_string(absoluteExposureSetResult) : "not_requested")
              << " absolute_exposure_verified=" << (requestedAbsoluteExposureVerification && absoluteExposureVerified ? "true" : "false")
              << " absolute_exposure_restore_result=" << (requestedAbsoluteExposureVerification ? std::to_string(absoluteExposureRestoreResult) : "not_requested")
              << " absolute_exposure_restored=" << (requestedAbsoluteExposureVerification && absoluteExposureRestored ? "true" : "false")
              << " native_tracking_policy_baseline_readable=" << (nativeTrackingBaselineReadable ? "true" : "false")
              << " native_tracking_policy_baseline_speed=" << (nativeTrackingBaselineReadable ? std::to_string(baselineNativeTrackingPolicy.speedMode) : "unknown")
              << " native_tracking_policy_baseline_motion=" << (nativeTrackingBaselineReadable ? (baselineNativeTrackingPolicy.motionTracking ? "true" : "false") : "unknown")
              << " native_tracking_policy_baseline_fore_target=" << (nativeTrackingBaselineReadable ? (baselineNativeTrackingPolicy.foreTarget ? "true" : "false") : "unknown")
              << " native_tracking_policy_baseline_adaptive_composition=" << (nativeTrackingBaselineReadable ? (baselineNativeTrackingPolicy.adaptiveComposition ? "true" : "false") : "unknown")
              << " native_tracking_policy_requested_speed=" << (requestedNativeTrackingPolicyVerification ? std::to_string(requestedNativeTrackingPolicyVerification->speedMode) : "not_requested")
              << " native_tracking_policy_verified=" << (requestedNativeTrackingPolicyVerification && nativeTrackingPolicyVerified ? "true" : "false")
              << " native_tracking_policy_set_results=" << (requestedNativeTrackingPolicyVerification
                    ? std::to_string(nativeTrackingSetSpeedResult) + "," + std::to_string(nativeTrackingSetMotionResult) + "," + std::to_string(nativeTrackingSetForeResult) + "," + std::to_string(nativeTrackingSetCompositionResult)
                    : "not_requested")
              << " native_tracking_policy_verify_results=" << (requestedNativeTrackingPolicyVerification
                    ? std::to_string(nativeTrackingVerifySpeedResult) + "," + std::to_string(nativeTrackingVerifyMotionResult) + "," + std::to_string(nativeTrackingVerifyForeResult) + "," + std::to_string(nativeTrackingVerifyCompositionResult)
                    : "not_requested")
              << " native_tracking_policy_restored=" << (requestedNativeTrackingPolicyVerification && nativeTrackingPolicyRestored ? "true" : "false")
              << " native_tracking_policy_restore_results=" << (requestedNativeTrackingPolicyVerification
                    ? std::to_string(nativeTrackingRestoreSpeedResult) + "," + std::to_string(nativeTrackingRestoreMotionResult) + "," + std::to_string(nativeTrackingRestoreForeResult) + "," + std::to_string(nativeTrackingRestoreCompositionResult)
                    : "not_requested")
              << " native_tracking_adaptive_gain_baseline_readable=" << (nativeTrackingAdaptiveGainBaselineReadable ? "true" : "false")
              << " native_tracking_adaptive_gain_baseline=" << (nativeTrackingAdaptiveGainBaselineReadable ? (baselinePanGainAdaptive ? "true" : "false") + std::string(",") + (baselinePitchGainAdaptive ? "true" : "false") : "unknown")
              << " native_tracking_adaptive_gain_requested=" << (requestedNativeTrackingAdaptiveGainVerification ? ((*requestedNativeTrackingAdaptiveGainVerification)[0] ? "true" : "false") + std::string(",") + ((*requestedNativeTrackingAdaptiveGainVerification)[1] ? "true" : "false") : "not_requested")
              << " native_tracking_adaptive_gain_verified=" << (requestedNativeTrackingAdaptiveGainVerification && nativeTrackingAdaptiveGainVerified ? "true" : "false")
              << " native_tracking_adaptive_gain_restored=" << (requestedNativeTrackingAdaptiveGainVerification && nativeTrackingAdaptiveGainRestored ? "true" : "false")
              << " native_tracking_manual_gain_baseline=" << (nativeTrackingManualGainBaselineReadable ? std::to_string(baselineNativePanGain) + "," + std::to_string(baselineNativePitchGain) : "unknown")
              << " native_tracking_manual_gain_requested=" << (requestedNativeTrackingManualGainVerification ? std::to_string((*requestedNativeTrackingManualGainVerification)[0]) + "," + std::to_string((*requestedNativeTrackingManualGainVerification)[1]) : "not_requested")
              << " native_tracking_manual_gain_verified=" << (requestedNativeTrackingManualGainVerification && nativeTrackingManualGainVerified ? "true" : "false")
              << " native_tracking_manual_gain_restored=" << (requestedNativeTrackingManualGainVerification && nativeTrackingManualGainRestored ? "true" : "false")
              << " face_priority_requested=" << (requestedFacePriorityVerification ? (*requestedFacePriorityVerification ? "on" : "off") : "not_requested")
              << " face_focus_baseline=" << (statusResult == RM_RET_OK ? std::to_string(baselineFaceAutoFocus) : "unknown")
              << " face_ae_baseline=" << (statusResult == RM_RET_OK ? std::to_string(baselineFaceAE) : "unknown")
              << " face_focus_set_result=" << (requestedFacePriorityVerification ? std::to_string(faceFocusSetResult) : "not_requested")
              << " face_ae_set_result=" << (requestedFacePriorityVerification ? std::to_string(faceAESetResult) : "not_requested")
              << " face_priority_verified=" << (requestedFacePriorityVerification && facePriorityVerified ? "true" : "false")
              << " face_focus_verified=" << (requestedFacePriorityVerification && facePriorityVerifyResult == RM_RET_OK ? std::to_string(verifiedFaceAutoFocus) : "not_available")
              << " face_ae_verified=" << (requestedFacePriorityVerification && facePriorityVerifyResult == RM_RET_OK ? std::to_string(verifiedFaceAE) : "not_available")
              << " face_focus_restore_result=" << (requestedFacePriorityVerification ? std::to_string(faceFocusRestoreResult) : "not_requested")
              << " face_ae_restore_result=" << (requestedFacePriorityVerification ? std::to_string(faceAERestoreResult) : "not_requested")
              << " face_priority_restored=" << (requestedFacePriorityVerification && facePriorityRestored ? "true" : "false")
              << " anti_flicker_baseline=" << (baselineAntiFlickerResult == RM_RET_OK ? std::to_string(baselineAntiFlicker) : "unknown")
              << " anti_flicker_requested=" << (requestedAntiFlickerVerification ? std::to_string(*requestedAntiFlickerVerification) : "not_requested")
              << " anti_flicker_set_result=" << (requestedAntiFlickerVerification ? std::to_string(antiFlickerSetResult) : "not_requested")
              << " anti_flicker_verified=" << (requestedAntiFlickerVerification && antiFlickerVerified ? "true" : "false")
              << " anti_flicker_verified_result=" << (requestedAntiFlickerVerification ? std::to_string(antiFlickerVerifyResult) : "not_requested")
              << " anti_flicker_verified_value=" << (requestedAntiFlickerVerification && antiFlickerVerifyResult == RM_RET_OK ? std::to_string(verifiedAntiFlicker) : "not_available")
              << " anti_flicker_restore_result=" << (requestedAntiFlickerVerification ? std::to_string(antiFlickerRestoreResult) : "not_requested")
              << " anti_flicker_restored=" << (requestedAntiFlickerVerification && antiFlickerRestored ? "true" : "false")
              << " anti_flicker_restored_value=" << (requestedAntiFlickerVerification && antiFlickerRestoredResult == RM_RET_OK ? std::to_string(restoredAntiFlicker) : "not_available")
              << " fov_baseline=" << (statusResult == RM_RET_OK ? std::to_string(static_cast<int>(baselineFOV)) : "unknown")
              << " fov_requested=" << (requestedFOVVerification ? std::to_string(static_cast<int>(*requestedFOVVerification)) : "not_requested")
              << " fov_set_result=" << (requestedFOVVerification ? std::to_string(fovSetResult) : "not_requested")
              << " fov_verified=" << (requestedFOVVerification && fovVerified ? "true" : "false")
              << " fov_verified_value=" << (requestedFOVVerification && fovVerifyResult == RM_RET_OK ? std::to_string(static_cast<int>(verifiedFOV)) : "not_available")
              << " fov_restore_result=" << (requestedFOVVerification ? std::to_string(fovRestoreResult) : "not_requested")
              << " fov_restored=" << (requestedFOVVerification && fovRestored ? "true" : "false")
              << " fov_restored_value=" << (requestedFOVVerification && fovRestoredResult == RM_RET_OK ? std::to_string(static_cast<int>(restoredFOV)) : "not_available")
              << " doa_find_back_baseline=" << (statusResult == RM_RET_OK ? (baselineDoaFindBack ? "true" : "false") : "unknown")
              << " doa_find_back_requested=" << (requestedDoaFindBackVerification ? (*requestedDoaFindBackVerification ? "true" : "false") : "not_requested")
              << " doa_find_back_set_result=" << (requestedDoaFindBackVerification ? std::to_string(doaFindBackSetResult) : "not_requested")
              << " doa_find_back_verified=" << (requestedDoaFindBackVerification && doaFindBackVerified ? "true" : "false")
              << " doa_find_back_restore_result=" << (requestedDoaFindBackVerification ? std::to_string(doaFindBackRestoreResult) : "not_requested")
              << " doa_find_back_restored=" << (requestedDoaFindBackVerification && doaFindBackRestored ? "true" : "false")
              << " doa_find_back=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.doa_set.doa_find_back) : "unknown")
              << " doa_range=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.doa_set.doa_range) : "unknown")
              << " doa_beamforming_disabled=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.doa_set.disable_bf) : "unknown")
              << " led_set_result=" << (requestedLedEnabled ? std::to_string(ledSetResult) : "not_requested")
              << " indicator_state=" << (requestedIndicatorState ? std::to_string(*requestedIndicatorState) : "not_requested")
              << " indicator_set_result=" << (requestedIndicatorState ? std::to_string(indicatorSetResult) : "not_requested")
              << " indicator_clear_result=" << (requestedIndicatorState ? std::to_string(indicatorClearResult) : "not_requested")
              << " indicator_restore_result=" << (requestedIndicatorState ? std::to_string(indicatorRestoreResult) : "not_requested")
              << " indicator_baseline_restore_result=" << (requestedIndicatorState || !requestedIndicatorClears.empty() ? std::to_string(indicatorBaselineRestoreResult) : "not_requested")
              << " indicator_bulk_set_count=" << requestedIndicatorSets.size()
              << " indicator_bulk_set_result=" << (!requestedIndicatorSets.empty() ? std::to_string(indicatorBulkSetResult) : "not_requested")
              << " indicator_bulk_clear_count=" << requestedIndicatorClears.size()
              << " indicator_bulk_clear_result=" << (!requestedIndicatorClears.empty() ? std::to_string(indicatorBulkClearResult) : "not_requested")
              << " tally_requested=" << (requestedTallyLight ? (*requestedTallyLight).enabled ? "true" : "false" : "not_requested")
              << " tally_baseline_result=" << (requestedTallyLight ? std::to_string(tallyBaselineResult) : "not_requested")
              << " tally_baseline_enabled=" << (requestedTallyLight && tallyBaselineResult == RM_RET_OK ? tallyBaselineEnabled ? "true" : "false" : "not_available")
              << " tally_baseline_brightness=" << (requestedTallyLight && tallyBaselineResult == RM_RET_OK ? std::to_string(tallyBaselineBrightness) : "not_available")
              << " battery_baseline_enabled=" << (requestedTallyLight && tallyBaselineResult == RM_RET_OK ? batteryBaselineEnabled ? "true" : "false" : "not_available")
              << " tally_set_result=" << (requestedTallyLight ? std::to_string(tallySetResult) : "not_requested")
              << " tally_restore_result=" << (requestedTallyLight ? std::to_string(tallyRestoreResult) : "not_requested")
              << " image_brightness=" << (imageBrightnessResult == RM_RET_OK ? std::to_string(imageBrightness) : "unknown")
              << " image_contrast=" << (imageContrastResult == RM_RET_OK ? std::to_string(imageContrast) : "unknown")
              << " image_hue=" << (imageHueResult == RM_RET_OK ? std::to_string(imageHue) : "unknown")
              << " image_saturation=" << (imageSaturationResult == RM_RET_OK ? std::to_string(imageSaturation) : "unknown")
              << " image_sharpness=" << (imageSharpnessResult == RM_RET_OK ? std::to_string(imageSharpness) : "unknown")
              << " optics_inspected=" << (inspectOptics ? "true" : "false")
              << " autofocus_result=" << (inspectOptics ? std::to_string(autoFocusResult) : "not_requested")
              << " autofocus_mode=" << (inspectOptics && autoFocusResult == RM_RET_OK ? std::to_string(static_cast<int>(autoFocus)) : "not_available")
              << " focus_position_result=" << (inspectOptics ? std::to_string(focusPositionResult) : "not_requested")
              << " focus_position=" << (inspectOptics && focusPositionResult == RM_RET_OK ? std::to_string(focusPosition) : "not_available")
              << " exposure_mode_result=" << (inspectOptics ? std::to_string(exposureModeResult) : "not_requested")
              << " exposure_mode=" << (inspectOptics && exposureModeResult == RM_RET_OK ? std::to_string(exposureMode) : "not_available")
              << " iso_limit_result=" << (inspectOptics ? std::to_string(isoLimitResult) : "not_requested")
              << " iso_limits=" << (inspectOptics && isoLimitResult == RM_RET_OK ? std::to_string(minimumISO) + ":" + std::to_string(maximumISO) : "not_available")
              << " exposure_bias_result=" << (inspectOptics ? std::to_string(exposureBiasResult) : "not_requested")
              << " exposure_bias=" << (inspectOptics && exposureBiasResult == RM_RET_OK ? std::to_string(exposureBias) : "not_available")
              << " exposure_bias_range_result=" << (inspectOptics ? std::to_string(exposureBiasRangeResult) : "not_requested")
              << " exposure_bias_range=" << (inspectOptics && exposureBiasRangeResult == RM_RET_OK ? std::to_string(exposureBiasRange.min_) + ":" + std::to_string(exposureBiasRange.max_) + ":" + std::to_string(exposureBiasRange.step_) : "not_available")
              << " mirror_flip_result=" << (inspectOptics ? std::to_string(mirrorFlipResult) : "not_requested")
              << " mirror_flip=" << (inspectOptics && mirrorFlipResult == RM_RET_OK ? std::to_string(mirrorFlip) : "not_available")
              << " gimbal_tracking_inspected=" << (inspectGimbalTracking ? "true" : "false")
              << " gimbal_tracking_info_result=" << (inspectGimbalTracking ? std::to_string(gimbalTrackingInfoResult) : "not_requested")
              << " gimbal_tracking_response_state=" << (inspectGimbalTracking && gimbalTrackingInfoResult == RM_RET_OK ? std::to_string(gimbalTrackingResponse.state) : "not_available")
              << " gimbal_tracking_response_data=" << (inspectGimbalTracking && gimbalTrackingInfoResult == RM_RET_OK ? std::to_string(gimbalTrackingResponse.data) : "not_available")
              << " native_tracking_tuning_inspected=" << (inspectNativeTrackingTuning ? "true" : "false")
              << " pan_gain_adaptive_result=" << (inspectNativeTrackingTuning ? std::to_string(panGainAdaptiveResult) : "not_requested")
              << " pan_gain_adaptive=" << (inspectNativeTrackingTuning && panGainAdaptiveResult == RM_RET_OK ? (panGainAdaptive ? "true" : "false") : "not_available")
              << " pan_gain_result=" << (inspectNativeTrackingTuning ? std::to_string(panGainResult) : "not_requested")
              << " pan_gain=" << (inspectNativeTrackingTuning && panGainResult == RM_RET_OK ? std::to_string(panGain) : "not_available")
              << " pitch_gain_adaptive_result=" << (inspectNativeTrackingTuning ? std::to_string(pitchGainAdaptiveResult) : "not_requested")
              << " pitch_gain_adaptive=" << (inspectNativeTrackingTuning && pitchGainAdaptiveResult == RM_RET_OK ? (pitchGainAdaptive ? "true" : "false") : "not_available")
              << " pitch_gain_result=" << (inspectNativeTrackingTuning ? std::to_string(pitchGainResult) : "not_requested")
              << " pitch_gain=" << (inspectNativeTrackingTuning && pitchGainResult == RM_RET_OK ? std::to_string(pitchGain) : "not_available")
              << " auto_zoom_speed_result=" << (inspectNativeTrackingTuning ? std::to_string(autoZoomSpeedResult) : "not_requested")
              << " auto_zoom_speed=" << (inspectNativeTrackingTuning && autoZoomSpeedResult == RM_RET_OK ? std::to_string(autoZoomSpeed) : "not_available")
              << " led_enabled=" << (ledEnabledResult == RM_RET_OK && ledEnabled ? "true" : "false")
              << " led_brightness=" << (ledBrightnessResult == RM_RET_OK ? std::to_string(ledBrightness) : "unknown")
              << " firmware=" << device->devVersion()
              << " serial=" << device->devSn() << "\n";
    return 0;
}
