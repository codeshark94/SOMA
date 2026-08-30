#include "OpenOBSBOTUVCTransport.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USBSpec.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <thread>
#include <vector>

namespace soma {
namespace {

constexpr uint8_t cameraTerminalEntity = 0x01;
constexpr uint8_t extensionUnitEntity = 0x02;
constexpr uint8_t vendorSelector = 0x02;
constexpr uint8_t statusSelector = 0x06;
constexpr int success = 0;
constexpr int failure = -1;

uint16_t crc16USB(const uint8_t *bytes, size_t count) noexcept {
    uint16_t crc = 0xFFFF;
    for (size_t index = 0; index < count; ++index) {
        crc ^= bytes[index];
        for (int bit = 0; bit < 8; ++bit) {
            crc = (crc & 1) ? static_cast<uint16_t>((crc >> 1) ^ 0xA001) : static_cast<uint16_t>(crc >> 1);
        }
    }
    return static_cast<uint16_t>(crc ^ 0xFFFF);
}

void writeU16LE(uint8_t *destination, uint16_t value) noexcept {
    destination[0] = static_cast<uint8_t>(value & 0xFF);
    destination[1] = static_cast<uint8_t>((value >> 8) & 0xFF);
}

void writeU32LE(uint8_t *destination, uint32_t value) noexcept {
    destination[0] = static_cast<uint8_t>(value & 0xFF);
    destination[1] = static_cast<uint8_t>((value >> 8) & 0xFF);
    destination[2] = static_cast<uint8_t>((value >> 16) & 0xFF);
    destination[3] = static_cast<uint8_t>((value >> 24) & 0xFF);
}

CFMutableDictionaryRef deviceMatchingDictionary(uint16_t vendorID, uint16_t product) noexcept {
    CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matching) return nullptr;
    int32_t vendorValue = vendorID;
    int32_t productValue = product;
    CFNumberRef vendor = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vendorValue);
    CFNumberRef productNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &productValue);
    if (!vendor || !productNumber) {
        if (vendor) CFRelease(vendor);
        if (productNumber) CFRelease(productNumber);
        CFRelease(matching);
        return nullptr;
    }
    CFDictionarySetValue(matching, CFSTR("idVendor"), vendor);
    CFDictionarySetValue(matching, CFSTR("idProduct"), productNumber);
    CFRelease(vendor);
    CFRelease(productNumber);
    return matching;
}

bool readNumber(CFDictionaryRef properties, CFStringRef key, uint8_t &value) noexcept {
    if (!properties) return false;
    CFTypeRef raw = CFDictionaryGetValue(properties, key);
    if (!raw || CFGetTypeID(raw) != CFNumberGetTypeID()) return false;
    return CFNumberGetValue(static_cast<CFNumberRef>(raw), kCFNumberSInt8Type, &value);
}

std::string usbSerial(io_service_t device) {
    CFTypeRef raw = IORegistryEntryCreateCFProperty(
        device,
        CFSTR(kUSBSerialNumberString),
        kCFAllocatorDefault,
        0
    );
    if (!raw || CFGetTypeID(raw) != CFStringGetTypeID()) {
        if (raw) CFRelease(raw);
        return {};
    }
    char buffer[256] {};
    const bool converted = CFStringGetCString(
        static_cast<CFStringRef>(raw),
        buffer,
        sizeof(buffer),
        kCFStringEncodingUTF8
    );
    CFRelease(raw);
    return converted ? std::string(buffer) : std::string();
}

size_t connectedDeviceCount(OBSBOTOpenDeviceProfile profile) noexcept {
    CFMutableDictionaryRef matching = deviceMatchingDictionary(
        open_obsbot_protocol::vendorID,
        open_obsbot_protocol::productID(profile)
    );
    if (!matching) return 0;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != kIOReturnSuccess
        || iterator == IO_OBJECT_NULL) {
        return 0;
    }
    size_t count = 0;
    io_service_t candidate = IO_OBJECT_NULL;
    while ((candidate = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        ++count;
        IOObjectRelease(candidate);
    }
    IOObjectRelease(iterator);
    return count;
}

bool videoControlInterface(io_service_t device, uint8_t &interfaceNumber) noexcept {
    io_iterator_t iterator = IO_OBJECT_NULL;
    const IOReturn result = IORegistryEntryCreateIterator(
        device,
        kIOServicePlane,
        kIORegistryIterateRecursively,
        &iterator
    );
    if (result != kIOReturnSuccess || iterator == IO_OBJECT_NULL) return false;
    bool found = false;
    io_service_t child = IO_OBJECT_NULL;
    while (!found && (child = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFMutableDictionaryRef properties = nullptr;
        if (IORegistryEntryCreateCFProperties(child, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess
            && properties) {
            uint8_t interfaceClass = 0;
            uint8_t interfaceSubclass = 0;
            uint8_t number = 0;
            found = readNumber(properties, CFSTR("bInterfaceClass"), interfaceClass)
                && readNumber(properties, CFSTR("bInterfaceSubClass"), interfaceSubclass)
                && readNumber(properties, CFSTR("bInterfaceNumber"), number)
                && interfaceClass == kUSBVideoInterfaceClass
                && interfaceSubclass == kUSBVideoControlSubClass;
            if (found) interfaceNumber = number;
            CFRelease(properties);
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(iterator);
    return found;
}

IOUSBDeviceInterface **openUSBDevice(io_service_t device, IOReturn &result) noexcept {
    IOCFPlugInInterface **plugin = nullptr;
    SInt32 score = 0;
    result = IOCreatePlugInInterfaceForService(
        device,
        kIOUSBDeviceUserClientTypeID,
        kIOCFPlugInInterfaceID,
        &plugin,
        &score
    );
    if (result != kIOReturnSuccess || !plugin) return nullptr;
    IOUSBDeviceInterface **interface = nullptr;
    const HRESULT query = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
        reinterpret_cast<LPVOID *>(&interface)
    );
    (*plugin)->Release(plugin);
    if (query != S_OK || !interface) {
        result = kIOReturnNoDevice;
        return nullptr;
    }
    result = (*interface)->USBDeviceOpen(interface);
    if (result != kIOReturnSuccess) {
        (*interface)->Release(interface);
        return nullptr;
    }
    return interface;
}

IOReturn uvcControl(
    IOUSBDeviceInterface **device,
    uint8_t interfaceNumber,
    uint8_t requestType,
    uint8_t request,
    uint8_t selector,
    uint8_t entity,
    void *data,
    uint16_t length
) noexcept {
    if (!device) return kIOReturnNotOpen;
    IOUSBDevRequest control {};
    control.bmRequestType = requestType;
    control.bRequest = request;
    control.wValue = static_cast<uint16_t>(selector << 8);
    control.wIndex = static_cast<uint16_t>((entity << 8) | interfaceNumber);
    control.wLength = length;
    control.pData = data;
    return (*device)->DeviceRequest(device, &control);
}

} // namespace

struct OpenOBSBOTUVCTransport::Storage {
    IOUSBDeviceInterface **device = nullptr;
    uint8_t videoControlInterface = 0;
    uint16_t sequence = 1;
    OBSBOTOpenDeviceProfile profile = OBSBOTOpenDeviceProfile::tiny2Lite;
    std::string serial;
};

OpenOBSBOTUVCTransport::OpenOBSBOTUVCTransport() : storage_(new Storage) {}

OpenOBSBOTUVCTransport::~OpenOBSBOTUVCTransport() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (storage_->device) {
        (*storage_->device)->USBDeviceClose(storage_->device);
        (*storage_->device)->Release(storage_->device);
    }
    delete storage_;
}

bool OpenOBSBOTUVCTransport::open(OBSBOTOpenDeviceProfile profile, std::string &error) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (storage_->device) return storage_->profile == profile;
    CFMutableDictionaryRef matching = deviceMatchingDictionary(
        open_obsbot_protocol::vendorID,
        open_obsbot_protocol::productID(profile)
    );
    if (!matching) {
        error = "unable to construct the OBSBOT USB match";
        return false;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    const IOReturn matched = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (matched != kIOReturnSuccess || iterator == IO_OBJECT_NULL) {
        error = "unable to enumerate the OBSBOT USB device";
        return false;
    }
    io_service_t selected = IO_OBJECT_NULL;
    io_service_t candidate = IO_OBJECT_NULL;
    size_t count = 0;
    while ((candidate = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        ++count;
        if (selected == IO_OBJECT_NULL) selected = candidate;
        else IOObjectRelease(candidate);
    }
    IOObjectRelease(iterator);
    if (count != 1 || selected == IO_OBJECT_NULL) {
        if (selected != IO_OBJECT_NULL) IOObjectRelease(selected);
        error = count == 0
            ? "no compatible OBSBOT USB device is connected"
            : "multiple compatible OBSBOT devices require explicit USB-path binding";
        return false;
    }
    const std::string serial = usbSerial(selected);
    uint8_t interfaceNumber = 0;
    const bool hasVideoControl = videoControlInterface(selected, interfaceNumber);
    IOReturn openResult = kIOReturnNoDevice;
    IOUSBDeviceInterface **device = hasVideoControl ? openUSBDevice(selected, openResult) : nullptr;
    IOObjectRelease(selected);
    if (!hasVideoControl || !device) {
        error = !hasVideoControl
            ? "the OBSBOT exposes no UVC VideoControl interface"
            : "unable to open the OBSBOT USB control endpoint: " + std::to_string(openResult);
        return false;
    }
    storage_->device = device;
    storage_->videoControlInterface = interfaceNumber;
    storage_->profile = profile;
    storage_->serial = serial;
    return true;
}

bool OpenOBSBOTUVCTransport::openDetected(std::string &error) noexcept {
    const size_t tiny2Count = connectedDeviceCount(OBSBOTOpenDeviceProfile::tiny2Lite);
    const size_t tiny3Count = connectedDeviceCount(OBSBOTOpenDeviceProfile::tiny3Lite);
    if (tiny2Count + tiny3Count == 0) {
        error = "no supported OBSBOT USB device is connected";
        return false;
    }
    if (tiny2Count + tiny3Count != 1) {
        error = "multiple supported OBSBOT devices require explicit USB-path binding";
        return false;
    }
    return open(
        tiny2Count == 1 ? OBSBOTOpenDeviceProfile::tiny2Lite : OBSBOTOpenDeviceProfile::tiny3Lite,
        error
    );
}

bool OpenOBSBOTUVCTransport::isOpen() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return storage_->device != nullptr;
}

OBSBOTOpenDeviceProfile OpenOBSBOTUVCTransport::profile() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return storage_->profile;
}

OpenOBSBOTDeviceIdentity OpenOBSBOTUVCTransport::identity() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return {
        storage_->profile,
        open_obsbot_protocol::productID(storage_->profile),
        storage_->serial,
    };
}

int OpenOBSBOTUVCTransport::readAttitude(double &pitchDegrees, double &panDegrees) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return readAttitudeLocked(pitchDegrees, panDegrees);
}

int OpenOBSBOTUVCTransport::readAttitudeLocked(
    double &pitchDegrees,
    double &panDegrees
) noexcept {
    if (!storage_->device) return failure;
    std::array<int32_t, 2> panTilt {};
    const IOReturn result = uvcControl(
        storage_->device,
        storage_->videoControlInterface,
        0xA1,
        0x81,
        0x0D,
        cameraTerminalEntity,
        panTilt.data(),
        static_cast<uint16_t>(sizeof(panTilt))
    );
    if (result != kIOReturnSuccess) return failure;
    panDegrees = static_cast<double>(panTilt[0]) / 3600.0;
    // UVC tilt is positive upward. SOMA's established gimbal frame uses the
    // opposite sign, so normalize once at this transport boundary.
    pitchDegrees = -static_cast<double>(panTilt[1]) / 3600.0;
    return std::isfinite(pitchDegrees) && std::isfinite(panDegrees) ? success : failure;
}

int OpenOBSBOTUVCTransport::sendFrame(
    uint16_t command,
    uint8_t receiver,
    const void *payloadBytes,
    size_t payloadSize
) noexcept {
    if (!storage_->device || payloadSize > 44) return failure;
    std::array<uint8_t, 60> frame {};
    frame[0] = 0xAA;
    frame[1] = 0x25;
    writeU16LE(frame.data() + 2, storage_->sequence++);
    writeU16LE(frame.data() + 4, 12);
    frame[8] = 0x0A;
    frame[9] = receiver;
    writeU16LE(frame.data() + 10, command);
    writeU16LE(frame.data() + 6, crc16USB(frame.data(), 12));
    if (payloadSize > 0) {
        writeU16LE(frame.data() + 12, static_cast<uint16_t>(payloadSize));
        std::memcpy(frame.data() + 16, payloadBytes, payloadSize);
        writeU16LE(frame.data() + 14, crc16USB(frame.data() + 12, payloadSize + 4));
    }
    const IOReturn result = uvcControl(
        storage_->device,
        storage_->videoControlInterface,
        0x21,
        0x01,
        vendorSelector,
        extensionUnitEntity,
        frame.data(),
        static_cast<uint16_t>(frame.size())
    );
    return result == kIOReturnSuccess ? success : failure;
}

int OpenOBSBOTUVCTransport::setExternalVelocity(float pitch, float pan) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return setExternalVelocityLocked(pitch, pan);
}

int OpenOBSBOTUVCTransport::setExternalVelocityLocked(float pitch, float pan) noexcept {
    const auto encoded = open_obsbot_protocol::externalVelocity(
        storage_->profile,
        pitch,
        pan
    );
    if (!encoded) return failure;
    return sendFrame(
        encoded->command,
        encoded->receiver,
        encoded->payload.data(),
        encoded->payload.size()
    );
}

int OpenOBSBOTUVCTransport::stopMotion() noexcept {
    return setExternalVelocity(0, 0);
}

int OpenOBSBOTUVCTransport::center() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (const auto command = open_obsbot_protocol::firmwareRecenter(storage_->profile)) {
        return sendFrame(
            command->command,
            command->receiver,
            command->payload.data(),
            command->payload.size()
        );
    }
    // The Tiny 2 recenter frame is acknowledged but inert on Tiny 2 Lite.
    // Close the loop on the device's live UVC pose instead of treating that
    // ACK as arrival.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline) {
        double pitch = 0;
        double pan = 0;
        if (readAttitudeLocked(pitch, pan) != success) break;
        if (std::hypot(pitch, pan) <= 2.0) {
            setExternalVelocityLocked(0, 0);
            return success;
        }
        const float pitchVelocity = static_cast<float>(std::clamp(-pitch * 1.6, -60.0, 60.0));
        const float panVelocity = static_cast<float>(std::clamp(-pan * 1.6, -80.0, 80.0));
        if (setExternalVelocityLocked(pitchVelocity, panVelocity) != success) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
    }
    setExternalVelocityLocked(0, 0);
    return failure;
}

int OpenOBSBOTUVCTransport::setAwake(bool awake) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto command = open_obsbot_protocol::wakeState(storage_->profile, awake);
    return sendFrame(
        command.command,
        command.receiver,
        command.payload.data(),
        command.payload.size()
    );
}

int OpenOBSBOTUVCTransport::setZoomFactor(double factor) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!storage_->device || !std::isfinite(factor) || factor < 1 || factor > 4) return failure;
    int16_t minimum = 0;
    int16_t maximum = 0;
    IOReturn result = uvcControl(
        storage_->device,
        storage_->videoControlInterface,
        0xA1,
        0x82,
        0x0B,
        cameraTerminalEntity,
        &minimum,
        sizeof(minimum)
    );
    if (result == kIOReturnSuccess) {
        result = uvcControl(
            storage_->device,
            storage_->videoControlInterface,
            0xA1,
            0x83,
            0x0B,
            cameraTerminalEntity,
            &maximum,
            sizeof(maximum)
        );
    }
    if (result != kIOReturnSuccess || maximum <= minimum) return failure;
    const double normalized = (factor - 1.0) / 3.0;
    int16_t units = static_cast<int16_t>(std::lround(
        static_cast<double>(minimum) + static_cast<double>(maximum - minimum) * normalized
    ));
    result = uvcControl(
        storage_->device,
        storage_->videoControlInterface,
        0x21,
        0x01,
        0x0B,
        cameraTerminalEntity,
        &units,
        sizeof(units)
    );
    return result == kIOReturnSuccess ? success : failure;
}

int OpenOBSBOTUVCTransport::enableHumanTracking() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!storage_->device) return failure;
    if (storage_->profile == OBSBOTOpenDeviceProfile::tiny3Lite) {
        if (setAIWorkModeLocked(0x02, 0x00) != success) return failure;
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        if (setAIWorkModeLocked(0x0E, 0x00) != success) return failure;
        return selectHumanTrackingTargetLocked(0.25f, 0.15f, 0.5f, 0.7f);
    }
    // Tiny 2 accepts the framed AI_SET_AI_TRACK_MODE packet but does not act
    // on it. Its operational tracking switch is the 60-byte status/control XU:
    // tag 0x16, two-byte value, human work mode 0x02, normal framing 0x00.
    auto tracking = open_obsbot_protocol::trackingModeControl(0x02);
    const IOReturn trackingResult = uvcControl(
        storage_->device,
        storage_->videoControlInterface,
        0x21,
        0x01,
        statusSelector,
        extensionUnitEntity,
        tracking.data(),
        static_cast<uint16_t>(tracking.size())
    );
    if (trackingResult != kIOReturnSuccess) return failure;
    const uint8_t sport = 2;
    return sendFrame(0x0CC4, 0x04, &sport, sizeof(sport));
}

int OpenOBSBOTUVCTransport::setAIWorkModeLocked(uint8_t mode, uint8_t submode) noexcept {
    if (!storage_->device) return failure;
    auto control = open_obsbot_protocol::trackingModeControl(mode, submode);
    return uvcControl(
        storage_->device,
        storage_->videoControlInterface,
        0x21,
        0x01,
        statusSelector,
        extensionUnitEntity,
        control.data(),
        static_cast<uint16_t>(control.size())
    ) == kIOReturnSuccess ? success : failure;
}

int OpenOBSBOTUVCTransport::selectHumanTrackingTarget(
    float x,
    float y,
    float width,
    float height
) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return selectHumanTrackingTargetLocked(x, y, width, height);
}

int OpenOBSBOTUVCTransport::selectHumanTrackingTargetLocked(
    float x,
    float y,
    float width,
    float height
) noexcept {
    const auto target = open_obsbot_protocol::selectHumanTarget(
        storage_->profile,
        x,
        y,
        width,
        height
    );
    if (!target) return failure;
    return sendFrame(
        target->command,
        target->receiver,
        target->payload.data(),
        target->payload.size()
    );
}

int OpenOBSBOTUVCTransport::disableHumanTracking() noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!storage_->device) return failure;
    if (storage_->profile == OBSBOTOpenDeviceProfile::tiny3Lite) {
        const auto target = open_obsbot_protocol::clearTiny3HumanTarget();
        const int targetResult = sendFrame(
            target.command,
            target.receiver,
            target.payload.data(),
            target.payload.size()
        );
        const int modeResult = setAIWorkModeLocked(0x00, 0x00);
        return targetResult == success && modeResult == success ? success : failure;
    }
    auto tracking = open_obsbot_protocol::trackingModeControl(0x00);
    return uvcControl(
        storage_->device,
        storage_->videoControlInterface,
        0x21,
        0x01,
        statusSelector,
        extensionUnitEntity,
        tracking.data(),
        static_cast<uint16_t>(tracking.size())
    ) == kIOReturnSuccess ? success : failure;
}

int OpenOBSBOTUVCTransport::setAudioMode(uint8_t source, uint8_t mode) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!storage_->device || storage_->profile != OBSBOTOpenDeviceProfile::tiny3Lite
        || source > 1 || mode > 5 || mode == 3) {
        return failure;
    }
    std::array<uint8_t, 60> control {};
    writeU16LE(control.data(), 0x0222);
    control[2] = source;
    control[3] = mode;
    return uvcControl(
        storage_->device,
        storage_->videoControlInterface,
        0x21,
        0x01,
        statusSelector,
        extensionUnitEntity,
        control.data(),
        static_cast<uint16_t>(control.size())
    ) == kIOReturnSuccess ? success : failure;
}

int OpenOBSBOTUVCTransport::setAudioInputGain(int16_t percent) noexcept {
    (void)percent;
    return failure;
}

int OpenOBSBOTUVCTransport::setSoundFollowing(bool enabled) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!storage_->device || storage_->profile != OBSBOTOpenDeviceProfile::tiny3Lite) return failure;
    std::array<uint8_t, 60> control {};
    writeU16LE(control.data(), 0x0125);
    writeU32LE(control.data() + 2, enabled ? 1u : 0u);
    return uvcControl(
        storage_->device,
        storage_->videoControlInterface,
        0x21,
        0x01,
        statusSelector,
        extensionUnitEntity,
        control.data(),
        static_cast<uint16_t>(control.size())
    ) == kIOReturnSuccess ? success : failure;
}

int OpenOBSBOTUVCTransport::setIndicatorStateLocked(uint8_t stateID) noexcept {
    constexpr std::array<uint8_t, 3> presentationStates {16, 54, 57};
    for (const uint8_t current : presentationStates) {
        if (current == stateID) continue;
        if (sendFrame(0x704D, 0x12, &current, sizeof(current)) != success) return failure;
    }
    return sendFrame(0x700D, 0x12, &stateID, sizeof(stateID));
}

int OpenOBSBOTUVCTransport::setIndicatorState(uint8_t stateID) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return setIndicatorStateLocked(stateID);
}

int OpenOBSBOTUVCTransport::clearIndicatorState(uint8_t stateID) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return sendFrame(0x704D, 0x12, &stateID, sizeof(stateID));
}

int OpenOBSBOTUVCTransport::setIndicatorBrightness(uint8_t brightness) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    if (brightness > 3) return failure;
    return sendFrame(0x750D, 0x12, &brightness, sizeof(brightness));
}

int OpenOBSBOTUVCTransport::setIndicatorEnabled(bool enabled) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    const uint8_t value = enabled ? 1 : 0;
    return sendFrame(0x75CD, 0x12, &value, sizeof(value));
}

} // namespace soma
