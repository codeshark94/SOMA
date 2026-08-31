#pragma once

#include "OpenOBSBOTProtocol.hpp"
#include "OpenOBSBOTRecovery.hpp"

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>

namespace soma {

/// Direct macOS UVC/XU control transport. It owns only the USB control
/// endpoint; AVFoundation remains free to own the video stream.
class OpenOBSBOTUVCTransport final {
public:
    OpenOBSBOTUVCTransport();
    ~OpenOBSBOTUVCTransport();

    OpenOBSBOTUVCTransport(const OpenOBSBOTUVCTransport &) = delete;
    OpenOBSBOTUVCTransport &operator=(const OpenOBSBOTUVCTransport &) = delete;

    bool open(OBSBOTOpenDeviceProfile profile, std::string &error) noexcept;
    bool openDetected(std::string &error) noexcept;
    bool isOpen() const noexcept;
    OpenOBSBOTRecoverySnapshot recoveryStatus() const noexcept;
    bool serviceRecovery(std::string &error) noexcept;
    bool commitRecovery() noexcept;
    void abortRecovery(int32_t ioReturn) noexcept;
    const char *name() const noexcept { return "open_uvc_xu"; }
    OBSBOTOpenDeviceProfile profile() const noexcept;
    OpenOBSBOTDeviceIdentity identity() const;

    int readAttitude(double &pitchDegrees, double &panDegrees) noexcept;
    int setExternalVelocity(float pitchDegreesPerSecond, float panDegreesPerSecond) noexcept;
    int stopMotion() noexcept;
    int center() noexcept;
    int setAwake(bool awake) noexcept;
    int setZoomFactor(double factor) noexcept;
    int enableHumanTracking() noexcept;
    int selectHumanTrackingTarget(float x, float y, float width, float height) noexcept;
    int disableHumanTracking() noexcept;
    int setAudioMode(uint8_t source, uint8_t mode) noexcept;
    int setAudioInputGain(int16_t percent) noexcept;
    int setSoundFollowing(bool enabled) noexcept;
    int setIndicatorState(uint8_t stateID) noexcept;
    int clearIndicatorState(uint8_t stateID) noexcept;
    int setIndicatorBrightness(uint8_t brightness) noexcept;
    int setIndicatorEnabled(bool enabled) noexcept;

private:
    struct Storage;
    Storage *storage_;
    mutable std::mutex mutex_;

    int readAttitudeLocked(double &pitchDegrees, double &panDegrees) noexcept;
    bool openLocked(
        OBSBOTOpenDeviceProfile profile,
        const std::string &expectedSerial,
        uint32_t expectedLocationID,
        std::string &error,
        int32_t &ioReturn
    ) noexcept;
    void closeLocked() noexcept;
    void recordTransferFailureLocked(int32_t ioReturn) noexcept;
    int submitControlLocked(
        uint8_t requestType,
        uint8_t request,
        uint8_t selector,
        uint8_t entity,
        void *data,
        uint16_t length
    ) noexcept;
    int32_t submitFrameDirectLocked(
        uint16_t command,
        uint8_t receiver,
        const void *payload,
        size_t payloadSize
    ) noexcept;
    int setExternalVelocityLocked(float pitchDegreesPerSecond, float panDegreesPerSecond) noexcept;
    int setAIWorkModeLocked(uint8_t mode, uint8_t submode) noexcept;
    int selectHumanTrackingTargetLocked(float x, float y, float width, float height) noexcept;
    int sendFrame(uint16_t command, uint8_t receiver, const void *payload, size_t payloadSize) noexcept;
    int setIndicatorStateLocked(uint8_t stateID) noexcept;
};

} // namespace soma
