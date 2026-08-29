#pragma once

#include <cstdint>

#include <dev/devs.hpp>

namespace soma {

enum class OBSBOTDeviceProfile {
    unknown,
    tiny2Lite,
    tiny3Lite,
};

enum class OBSBOTNativeTrackingTransport {
    unavailable,
    legacyHumanMode,
    selectedHumanPortrait,
};

enum class OBSBOTIndicatorPulseTransport {
    unavailable = 0,
    brightnessDimming = 1,
    enableToggle = 2,
    directDark = 3,
};

enum class OBSBOTIndicatorColor : uint8_t {
    yellow = 0,
    green = 1,
    blue = 2,
};

struct OBSBOTDeviceContract {
    const char *identifier;
    bool nativeBridge;
    bool calibratedMotorControl;
    bool boundedCalibrationPulses;
    bool nativeHumanTracking;
    bool firmwareIndicatorPalette;
    bool firmwareDefaultIndicatorGreen;
    uint8_t directIndicatorColorMask;
    bool indicatorEnableAndBrightness;
    OBSBOTIndicatorPulseTransport indicatorPulseTransport;
    bool selectableAudioModes;
    uint8_t supportedAudioModeMask;
    bool soundLocalization;
    bool requiresMeasuredAttitudeFrame;
    int indicatorBaseStateID;
    int yellowIndicatorStateID;
    int greenIndicatorStateID;
    int blueIndicatorStateID;
    double maximumPanDegreesPerSecond;
    double maximumPitchDegreesPerSecond;
    double nominalWideHorizontalFieldOfViewDegrees;
    OBSBOTNativeTrackingTransport nativeTrackingTransport;
};

class OBSBOTDeviceAdapter {
public:
    virtual ~OBSBOTDeviceAdapter() = default;

    virtual OBSBOTDeviceProfile profile() const noexcept = 0;
    virtual const OBSBOTDeviceContract &contract() const noexcept = 0;

    bool supportsIndicatorStateID(int stateID) const noexcept;
    bool supportsIndicatorColor(OBSBOTIndicatorColor color) const noexcept;
    bool supportsAudioMode(int mode) const noexcept;

    int setIndicatorState(Device *device, uint8_t stateID) const noexcept;
    int clearIndicatorState(Device *device, uint8_t stateID) const noexcept;
    int establishIndicatorBaseline(Device *device) const noexcept;
    int getIndicatorEnabled(Device *device, bool &enabled) const noexcept;
    int setIndicatorEnabled(Device *device, bool enabled) const noexcept;
    int getIndicatorBrightness(Device *device, uint8_t &brightness) const noexcept;
    int setIndicatorBrightness(Device *device, uint8_t brightness) const noexcept;
    virtual int setIndicatorColor(Device *device, OBSBOTIndicatorColor color) const noexcept;
    virtual int setIndicatorDark(Device *device) const noexcept;
    virtual int setAudioMode(Device *device, uint8_t source, uint8_t mode) const noexcept;
    virtual int setAudioInputGain(Device *device, int16_t percent) const noexcept;
    virtual int setSoundFollowing(Device *device, bool enabled) const noexcept;

    virtual int disableNativeTracking(Device *device) const noexcept = 0;
    virtual int stopNativeMotion(Device *device) const noexcept = 0;
    virtual int setExternalVelocity(Device *device, float pitch, float pan) const noexcept = 0;
    virtual int center(Device *device) const noexcept = 0;
};

const OBSBOTDeviceAdapter &obsbotDeviceAdapter(ObsbotProductType type) noexcept;
const OBSBOTDeviceContract &obsbotDeviceContract(ObsbotProductType type) noexcept;
const char *obsbotProfileID(ObsbotProductType type) noexcept;

} // namespace soma
