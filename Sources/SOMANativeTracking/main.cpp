#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <chrono>
#include <csignal>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <filesystem>
#include <functional>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <poll.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <set>
#include <thread>
#include <unistd.h>
#include <vector>

#include <dev/devs.hpp>
#include <mach/mach_time.h>

namespace {

using Clock = std::chrono::steady_clock;

std::atomic_bool interrupted = false;

// The RM SDK serializes commands over one device link and is not internally
// thread-safe. Every device call takes sdkMutex so the dedicated attitude
// reporter thread and the bridge loop never issue concurrent SDK
// transactions. stderrMutex keeps pipe-protocol lines from interleaving.
std::mutex sdkMutex;
std::mutex stderrMutex;

struct Tiny3FixedRGB {
    uint8_t red = 0;
    uint8_t green = 0;
    uint8_t blue = 0;

    bool operator==(const Tiny3FixedRGB &other) const {
        return red == other.red && green == other.green && blue == other.blue;
    }
};

constexpr Tiny3FixedRGB kTiny3SemanticGreen {0, 255, 0};
constexpr Tiny3FixedRGB kTiny3SemanticYellow {255, 210, 0};
constexpr Tiny3FixedRGB kTiny3SemanticBlue {0, 0, 255};
constexpr uintptr_t kBundledSysMgSetIndicatorStateOffset = 0x447f4;
constexpr uintptr_t kBundledSendMsgSyncOffset = 0x59f54;
constexpr uint16_t kTiny3PaletteCommandSet = 13;
constexpr uint16_t kTiny3PaletteCommandID = 456;
constexpr uint16_t kTiny3SystemManagerTarget = 11;
constexpr uint16_t kFrmPacketHeaderSize = 12;
constexpr size_t kTiny3FrameCapacity = 0x1820;

using SendMsgSync = int32_t (*)(void *, void *, uint8_t *, int32_t, bool);

void writeU16LE(uint8_t *destination, uint16_t value) {
    destination[0] = static_cast<uint8_t>(value & 0xff);
    destination[1] = static_cast<uint8_t>(value >> 8);
}

void writeU64LE(uint8_t *destination, uint64_t value) {
    for (size_t index = 0; index < 8; ++index) {
        destination[index] = static_cast<uint8_t>(value >> (index * 8));
    }
}

std::optional<uintptr_t> bundledLibdevBase(std::string &failure) {
    const auto indicatorMember = &Device::sysMgSetIndicatorStateR;
    void *indicatorSymbol = nullptr;
    static_assert(sizeof(indicatorMember) >= sizeof(indicatorSymbol));
    std::memcpy(&indicatorSymbol, &indicatorMember, sizeof(indicatorSymbol));
    Dl_info image {};
    if (!indicatorSymbol || dladdr(indicatorSymbol, &image) == 0 || !image.dli_fbase) {
        failure = "sdk_image_unavailable";
        return std::nullopt;
    }
    const auto imageBase = reinterpret_cast<uintptr_t>(image.dli_fbase);
    if (reinterpret_cast<uintptr_t>(indicatorSymbol) - imageBase != kBundledSysMgSetIndicatorStateOffset) {
        failure = "unsupported_sdk_layout";
        return std::nullopt;
    }
    return imageBase;
}

struct Tiny3NativePaletteMessage {
    std::array<uint8_t, kTiny3FrameCapacity> bytes {};
    void *devicePrivate = nullptr;
    SendMsgSync sendSync = nullptr;
};

std::optional<Tiny3NativePaletteMessage> makeTiny3NativePaletteMessage(
    Device *device,
    Tiny3FixedRGB color,
    std::string &failure
) {
    const auto imageBase = bundledLibdevBase(failure);
    if (!imageBase) return std::nullopt;

    auto *const devicePrivate = *reinterpret_cast<void **>(reinterpret_cast<uint8_t *>(device) + 8);
    if (!devicePrivate) {
        failure = "sdk_device_private_unavailable";
        return std::nullopt;
    }

    Tiny3NativePaletteMessage message;
    message.devicePrivate = devicePrivate;
    message.sendSync = reinterpret_cast<SendMsgSync>(*imageBase + kBundledSendMsgSyncOffset);
    writeU16LE(message.bytes.data(), kFrmPacketHeaderSize + 3);
    writeU64LE(message.bytes.data() + 4, 0x0014000000000000ULL);
    writeU16LE(message.bytes.data() + 12, kTiny3SystemManagerTarget);
    writeU16LE(message.bytes.data() + 14, kTiny3PaletteCommandID);
    writeU16LE(message.bytes.data() + 16, kTiny3PaletteCommandSet);
    const auto *const privateBytes = reinterpret_cast<const uint8_t *>(devicePrivate);
    std::memcpy(message.bytes.data() + 20, privateBytes + 0x12f8, sizeof(uint32_t));
    std::memcpy(message.bytes.data() + 24, privateBytes + 0x14, sizeof(uint32_t));
    message.bytes[28] = color.red;
    message.bytes[29] = color.green;
    message.bytes[30] = color.blue;
    return message;
}

void handleSignal(int) {
    interrupted = true;
}

struct Options {
    bool allowMotion = false;
    bool allowDeviceCalibration = false;
    bool allowProfileCalibratedMotion = false;
    bool list = false;
    bool serve = false;
    bool center = false;
    bool manualStop = false;
    std::optional<bool> doaFindBack;
    bool durationSpecified = false;
    int durationSeconds = 10;
    std::string outputPath;
    size_t traceMaximumBytes = 0;
    int traceRetainedFiles = 0;
};

Options parseOptions(int argc, char **argv) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--allow-camera-motion") {
            options.allowMotion = true;
        } else if (argument == "--allow-device-calibration") {
            options.allowDeviceCalibration = true;
        } else if (argument == "--allow-profile-calibrated-motion") {
            options.allowProfileCalibratedMotion = true;
        } else if (argument == "--list") {
            options.list = true;
        } else if (argument == "--serve") {
            options.serve = true;
        } else if (argument == "--center") {
            options.center = true;
        } else if (argument == "--manual-stop") {
            options.manualStop = true;
        } else if (argument == "--set-doa-find-back") {
            if (++index >= argc) throw std::runtime_error("--set-doa-find-back requires 0 or 1");
            const std::string value = argv[index];
            if (value == "0") {
                options.doaFindBack = false;
            } else if (value == "1") {
                options.doaFindBack = true;
            } else {
                throw std::runtime_error("--set-doa-find-back requires 0 or 1");
            }
        } else if (argument == "--duration") {
            if (++index >= argc) throw std::runtime_error("--duration requires seconds");
            options.durationSpecified = true;
            options.durationSeconds = std::stoi(argv[index]);
        } else if (argument == "--output") {
            if (++index >= argc) throw std::runtime_error("--output requires a JSONL path");
            options.outputPath = argv[index];
        } else if (argument == "--trace-max-megabytes") {
            if (++index >= argc) throw std::runtime_error("--trace-max-megabytes requires a positive integer");
            const auto megabytes = std::stoull(argv[index]);
            if (megabytes == 0 || megabytes > std::numeric_limits<size_t>::max() / 1'048'576) {
                throw std::runtime_error("--trace-max-megabytes is out of range");
            }
            options.traceMaximumBytes = static_cast<size_t>(megabytes * 1'048'576);
        } else if (argument == "--trace-retained-files") {
            if (++index >= argc) throw std::runtime_error("--trace-retained-files requires a positive integer");
            options.traceRetainedFiles = std::stoi(argv[index]);
            if (options.traceRetainedFiles <= 0) {
                throw std::runtime_error("--trace-retained-files requires a positive integer");
            }
        } else if (argument == "--help" || argument == "-h") {
            std::cout << "Usage: soma-native-track --list | --manual-stop --output <trace.jsonl> | --set-doa-find-back <0|1> --output <trace.jsonl> | --allow-camera-motion --duration <0=continuous|1-30> --output <trace.jsonl> [--trace-max-megabytes MB --trace-retained-files count] [--serve|--center] [--allow-device-calibration|--allow-profile-calibrated-motion]\n";
            std::exit(0);
        } else {
            throw std::runtime_error("Unknown argument: " + argument);
        }
    }
    if (options.durationSeconds < 0 || options.durationSeconds > 30) {
        throw std::runtime_error("--duration must be 0 (continuous) or between 1 and 30 seconds");
    }
    if (options.list && (options.serve || options.center || options.manualStop || options.doaFindBack || options.allowMotion
        || options.allowDeviceCalibration || options.allowProfileCalibratedMotion)) {
        throw std::runtime_error("--list cannot be combined with a motion mode");
    }
    if (options.manualStop && (options.serve || options.center || options.doaFindBack || options.allowMotion
        || options.allowDeviceCalibration || options.allowProfileCalibratedMotion || options.durationSpecified)) {
        throw std::runtime_error("--manual-stop cannot be combined with a motion mode");
    }
    if (options.serve && options.center) {
        throw std::runtime_error("Choose either --serve or --center");
    }
    if (options.allowDeviceCalibration && !options.serve) {
        throw std::runtime_error("--allow-device-calibration requires --serve");
    }
    if (options.allowProfileCalibratedMotion && !options.serve && !options.center) {
        throw std::runtime_error("--allow-profile-calibrated-motion requires --serve or --center");
    }
    if (options.allowDeviceCalibration && options.allowProfileCalibratedMotion) {
        throw std::runtime_error("Calibration and profile-calibrated motion are separate helper modes");
    }
    if (options.center && options.durationSeconds == 0) {
        throw std::runtime_error("--center requires a positive duration for the move to complete");
    }
    if (!options.list && !options.manualStop && !options.doaFindBack && !options.allowMotion) {
        throw std::runtime_error("--allow-camera-motion is required to enable native tracking");
    }
    if (!options.list && !options.manualStop && !options.doaFindBack && !options.durationSpecified) {
        throw std::runtime_error("--duration is required for a motion run");
    }
    if (!options.list && options.outputPath.empty()) {
        throw std::runtime_error("--output is required for a motion run");
    }
    if ((options.traceMaximumBytes == 0) != (options.traceRetainedFiles == 0)) {
        throw std::runtime_error("--trace-max-megabytes and --trace-retained-files must be supplied together as positive integers");
    }
    return options;
}

uint64_t monotonicNanoseconds() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        Clock::now().time_since_epoch()).count());
}

std::string escape(const std::string &value) {
    constexpr char hex[] = "0123456789abcdef";
    constexpr size_t maximumMessageBytes = 192;
    std::string escaped;
    escaped.reserve(std::min(value.size(), maximumMessageBytes) * 2);
    for (size_t index = 0; index < value.size() && index < maximumMessageBytes; ++index) {
        const char character = value[index];
        switch (character) {
            case '"': escaped += "\\\""; break;
            case '\\': escaped += "\\\\"; break;
            case '\b': escaped += "\\b"; break;
            case '\f': escaped += "\\f"; break;
            case '\n': escaped += "\\n"; break;
            case '\r': escaped += "\\r"; break;
            case '\t': escaped += "\\t"; break;
            default: {
                const auto byte = static_cast<unsigned char>(character);
                if (byte < 0x20) {
                    escaped += "\\u00";
                    escaped += hex[(byte >> 4) & 0x0f];
                    escaped += hex[byte & 0x0f];
                } else {
                    escaped += character;
                }
            }
        }
    }
    if (value.size() > maximumMessageBytes) escaped += "...";
    return escaped;
}

class Trace {
public:
    Trace(const std::string &path, size_t maximumBytes, int retainedFiles)
        : basePath_(path), maximumBytes_(maximumBytes), retainedFiles_(retainedFiles) {
        const auto directory = basePath_.parent_path();
        if (!directory.empty()) std::filesystem::create_directories(directory);
        if (maximumBytes_ > 0) {
            const auto segments = matchingSegments();
            sequence_ = segments.empty() ? 1 : segments.back().first + 1;
            open(segmentPath(sequence_));
            prune();
        } else {
            open(basePath_);
        }
    }

    void event(
        const std::string &event,
        const std::string &owner,
        const std::string &state,
        int resultCode,
        const std::string &message,
        const std::string &commandID = ""
    ) noexcept {
        try {
            std::ostringstream line;
            line << "{\"event\":\"" << event
                 << "\",\"monotonic_ns\":" << monotonicNanoseconds()
                 << ",\"owner\":\"" << owner
                 << "\",\"state\":\"" << state
                 << "\",\"result_code\":" << resultCode
                 << ",\"message\":\"" << escape(message) << "\"";
            if (!commandID.empty()) line << ",\"command_id\":\"" << escape(commandID) << "\"";
            line << "}\n";
            write(line.str());
        } catch (...) {
            // A diagnostic failure must never suppress a camera safety command.
        }
    }

private:
    using Segment = std::pair<uint64_t, std::filesystem::path>;

    void write(const std::string &line) {
        if (maximumBytes_ > 0
            && bytesWritten_ > 0
            && bytesWritten_ + line.size() > maximumBytes_) {
            file_.close();
            open(segmentPath(++sequence_));
            prune();
        }
        file_ << line;
        if (!file_) throw std::runtime_error("Cannot write trace: " + currentPath_.string());
        bytesWritten_ += line.size();
        file_.flush();
    }

    void open(const std::filesystem::path &path) {
        currentPath_ = path;
        file_.open(path, std::ios::out | std::ios::trunc);
        if (!file_) throw std::runtime_error("Cannot create trace: " + path.string());
        bytesWritten_ = 0;
    }

    std::filesystem::path segmentPath(uint64_t sequence) const {
        std::ostringstream filename;
        filename << basePath_.stem().string() << '-' << std::setw(8) << std::setfill('0') << sequence
                 << basePath_.extension().string();
        return basePath_.parent_path() / filename.str();
    }

    std::vector<Segment> matchingSegments() const {
        std::vector<Segment> segments;
        const auto directory = basePath_.parent_path().empty()
            ? std::filesystem::path(".")
            : basePath_.parent_path();
        const auto prefix = basePath_.stem().string() + '-';
        const auto extension = basePath_.extension().string();
        for (const auto &entry : std::filesystem::directory_iterator(directory)) {
            if (!entry.is_regular_file()) continue;
            const auto name = entry.path().filename().string();
            if (name.size() != prefix.size() + 8 + extension.size()
                || name.rfind(prefix, 0) != 0
                || name.substr(name.size() - extension.size()) != extension) {
                continue;
            }
            const auto sequenceText = name.substr(prefix.size(), 8);
            if (!std::all_of(sequenceText.begin(), sequenceText.end(), ::isdigit)) continue;
            segments.emplace_back(std::stoull(sequenceText), entry.path());
        }
        std::sort(segments.begin(), segments.end(), [](const Segment &lhs, const Segment &rhs) {
            return lhs.first < rhs.first;
        });
        return segments;
    }

    void prune() {
        const auto segments = matchingSegments();
        const auto excess = segments.size() > static_cast<size_t>(retainedFiles_)
            ? segments.size() - static_cast<size_t>(retainedFiles_)
            : 0;
        for (size_t index = 0; index < excess; ++index) {
            std::filesystem::remove(segments[index].second);
        }
    }

    std::filesystem::path basePath_;
    std::filesystem::path currentPath_;
    size_t maximumBytes_ = 0;
    int retainedFiles_ = 0;
    uint64_t sequence_ = 0;
    size_t bytesWritten_ = 0;
    std::ofstream file_;
};

std::mutex discoveryLock;
std::string connectedSerial;
std::string connectionFailure;

void deviceChanged(std::string serial, bool connected, void *) {
    std::lock_guard<std::mutex> lock(discoveryLock);
    if (connected) {
        connectedSerial = std::move(serial);
    } else if (connectedSerial == serial) {
        connectedSerial.clear();
    }
}

void deviceConnectionFailed(DevConnectFailed reason, std::string, Device::DevMode, void *) {
    std::lock_guard<std::mutex> lock(discoveryLock);
    connectionFailure = std::to_string(static_cast<int>(reason));
}

void prepareDiscovery(Devices &devices) {
    {
        std::lock_guard<std::mutex> lock(discoveryLock);
        connectedSerial.clear();
        connectionFailure.clear();
    }
    devices.setDevChangedCallback(deviceChanged, nullptr);
    devices.setDevConnectFailedCallback(deviceConnectionFailed, nullptr);
    devices.setEnableMdnsScan(false);
}

std::string discoveredSerial() {
    std::lock_guard<std::mutex> lock(discoveryLock);
    return connectedSerial;
}

std::string discoveryFailure() {
    std::lock_guard<std::mutex> lock(discoveryLock);
    return connectionFailure;
}

struct DiscoveryResult {
    std::shared_ptr<Device> device;
    enum class Profile {
        tiny2Lite,
        tiny3Lite,
    } profile = Profile::tiny2Lite;
    bool interrupted;
};

struct DeviceCapabilities {
    const char *identifier;
    bool calibratedMotorControl;
    bool boundedCalibrationPulses;
    bool firmwareIndicatorPalette;
    bool directIndicatorRGB;
    bool indicatorEnableAndBrightness;
    bool selectableAudioModes;
    bool soundLocalization;
    bool requiresMeasuredAttitudeFrame;
    double maximumPanDegreesPerSecond;
    double maximumPitchDegreesPerSecond;
};

struct NativeTargetBox {
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;
};

struct NativeHumanTrackingPolicy {
    int speedMode = Device::DevGimCtrlSpeedModeFast;
    bool motionTracking = true;
    bool foreTarget = true;
    bool adaptiveComposition = false;
    bool adaptivePanGain = false;
    bool adaptivePitchGain = false;
    std::optional<float> panGain;
    std::optional<float> pitchGain;
};

bool validNativeHumanTrackingSpeedMode(int speedMode) noexcept {
    return speedMode >= Device::DevGimCtrlSpeedModeSuperLazy
        && speedMode <= Device::DevGimCtrlSpeedModeCrazy;
}

bool validNativeHumanTrackingGain(float gain) noexcept {
    return std::isfinite(gain) && gain >= 0.1f && gain <= 1.0f;
}

std::string nativeHumanTrackingGainDescription(const std::optional<float> &gain) {
    return gain ? std::to_string(*gain) : "keep";
}

std::optional<DiscoveryResult::Profile> supportedProfile(ObsbotProductType productType) {
    switch (productType) {
    case ObsbotProdTiny2Lite: return DiscoveryResult::Profile::tiny2Lite;
    case ObsbotProdTiny3Lite: return DiscoveryResult::Profile::tiny3Lite;
    default: return std::nullopt;
    }
}

const DeviceCapabilities &capabilitiesFor(DiscoveryResult::Profile profile) {
    static const DeviceCapabilities tiny2Lite {
        "tiny_2_lite", true, false, true, false, true, false, false, false, 180, 90,
    };
    static const DeviceCapabilities tiny3Lite {
        "tiny_3_lite", false, true, false, true, true, true, true, true, 90, 45,
    };
    return profile == DiscoveryResult::Profile::tiny3Lite ? tiny3Lite : tiny2Lite;
}

DiscoveryResult waitForSupportedDevice() {
    auto &devices = Devices::get();
    prepareDiscovery(devices);
    const auto deadline = Clock::now() + std::chrono::seconds(10);
    while (Clock::now() < deadline) {
        if (interrupted) return {nullptr, DiscoveryResult::Profile::tiny2Lite, true};
        const std::string serial = discoveredSerial();
        if (!serial.empty()) {
            const auto device = devices.getDevBySn(serial);
            if (device) {
                if (const auto profile = supportedProfile(device->productType())) {
                    return {device, *profile, false};
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return {nullptr, DiscoveryResult::Profile::tiny2Lite, false};
}

int cameraStatusMode(const std::shared_ptr<Device> &device) {
    std::lock_guard<std::mutex> lock(sdkMutex);
    Device::CameraStatus status{};
    return device->cameraGetCameraStatusU(status) == RM_RET_OK ? status.tiny.ai_mode : -1;
}

std::optional<int> verticalTrackingMode(const std::shared_ptr<Device> &device) noexcept {
    try {
        std::lock_guard<std::mutex> lock(sdkMutex);
        Device::AiStatus status{};
        if (device->aiGetAiStatusR(&status) == RM_RET_OK) {
            return static_cast<int>(status.v_track_landscape);
        }
    } catch (...) {}
    return std::nullopt;
}

std::optional<int> cameraHorizontalFieldOfViewDegrees(const std::shared_ptr<Device> &device) {
    std::lock_guard<std::mutex> lock(sdkMutex);
    Device::CameraStatus status{};
    if (device->cameraGetCameraStatusU(status) != RM_RET_OK) return std::nullopt;
    switch (status.tiny.fov) {
    case Device::FovType86: return 86;
    case Device::FovType78: return 78;
    case Device::FovType65: return 65;
    default: return std::nullopt;
    }
}

void emitHorizontalFieldOfView(int degrees) noexcept;

std::optional<float> cameraZoomFactor(const std::shared_ptr<Device> &device) noexcept {
    try {
        std::lock_guard<std::mutex> lock(sdkMutex);
        float zoom = 0;
        if (device->cameraGetZoomAbsoluteR(zoom) == RM_RET_OK && std::isfinite(zoom)) {
            return zoom;
        }
    } catch (...) {}
    return std::nullopt;
}

std::optional<float> waitForCameraZoom(
    const std::shared_ptr<Device> &device,
    float requestedZoom,
    float tolerance,
    std::chrono::milliseconds maximumWait
) noexcept {
    std::optional<float> measuredZoom;
    const auto deadline = Clock::now() + maximumWait;
    while (Clock::now() < deadline && !interrupted) {
        measuredZoom = cameraZoomFactor(device);
        if (measuredZoom && std::abs(*measuredZoom - requestedZoom) <= tolerance) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return measuredZoom;
}

/// Applies an explicit cognitive zoom request and confirms the value reported
/// by the camera before publishing it to the visual geometry layer.  The
/// camera's normalized value is quantized by firmware, so confirmation uses a
/// small measurement tolerance rather than assuming an exact float echo.
bool setCameraOpticalZoom(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    float requestedZoom,
    const std::string &commandID
) noexcept {
    if (!std::isfinite(requestedZoom) || requestedZoom < 1.0f || requestedZoom > 2.0f) {
        trace.event("camera.ack", "fault", "zoom_out_of_range", RM_RET_ERR,
                    "requested_zoom=" + std::to_string(requestedZoom), commandID);
        return false;
    }
    int setResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { setResult = device->cameraSetZoomAbsoluteR(requestedZoom); } catch (...) {}
    }
    // The firmware reports a transient value while returning to its wide end
    // stop.  Do not publish that transient as the geometry calibration: wide
    // framing is the reference used by the panorama and world field.
    const bool restoringWideView = requestedZoom <= 1.01f;
    const float confirmationTolerance = restoringWideView ? 0.015f : 0.04f;
    const auto waitLimit = restoringWideView ? std::chrono::milliseconds(6'000)
                                              : std::chrono::milliseconds(1'800);
    const auto confirmedZoom = setResult == RM_RET_OK
        ? waitForCameraZoom(device, requestedZoom, confirmationTolerance, waitLimit)
        : std::optional<float>{};
    const bool confirmed = setResult == RM_RET_OK
        && confirmedZoom
        && std::abs(*confirmedZoom - requestedZoom) <= confirmationTolerance;
    const std::string message = "requested_zoom=" + std::to_string(requestedZoom)
        + "; zoom_set_result=" + std::to_string(setResult)
        + "; reported_zoom=" + (confirmedZoom ? std::to_string(*confirmedZoom) : "unavailable");
    trace.event(
        "camera.ack",
        confirmed ? "manual" : "fault",
        confirmed ? "optical_zoom_active" : "optical_zoom_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        message,
        commandID
    );
    if (confirmed) {
        try {
            std::lock_guard<std::mutex> lock(stderrMutex);
            std::cerr << "SOMA_CAMERA_ZOOM factor=" << *confirmedZoom << "\n" << std::flush;
        } catch (...) {}
        if (const auto fieldOfView = cameraHorizontalFieldOfViewDegrees(device)) {
            emitHorizontalFieldOfView(*fieldOfView);
        }
    }
    return confirmed;
}

bool configureFixedCameraZoom(const std::shared_ptr<Device> &device, Trace &trace) noexcept {
    int autoZoomResult = RM_RET_ERR;
    int zoomResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { autoZoomResult = device->aiSetAiAutoZoomR(false); } catch (...) {}
        try { zoomResult = device->cameraSetZoomAbsoluteR(1.0f); } catch (...) {}
    }
    const auto zoom = zoomResult == RM_RET_OK
        ? waitForCameraZoom(device, 1.0f, 0.015f, std::chrono::milliseconds(6'000))
        : std::optional<float>{};
    const bool confirmed = zoomResult == RM_RET_OK && zoom && std::abs(*zoom - 1.0f) <= 0.015f;
    const std::string message = "auto_zoom_disable_result=" + std::to_string(autoZoomResult)
        + "; zoom_set_result=" + std::to_string(zoomResult)
        + (zoom ? "; zoom_factor=" + std::to_string(*zoom) : "; zoom_factor=unavailable");
    trace.event(
        "camera.ack",
        confirmed ? "manual" : "fault",
        confirmed ? "fixed_zoom_active" : "fixed_zoom_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        message,
        "startup-zoom-1x"
    );
    try {
        std::cerr << "SOMA_CAMERA_ZOOM factor="
                  << (zoom ? std::to_string(*zoom) : "unavailable")
                  << " fixed=" << (confirmed ? "true" : "false")
                  << "\n" << std::flush;
    } catch (...) {}
    return confirmed;
}

std::string audioProcessingValue(const std::optional<bool> &value) {
    if (!value) return "unavailable";
    return *value ? "on" : "off";
}

std::string audioProcessingValue(const std::optional<int> &value) {
    return value ? std::to_string(*value) : "unavailable";
}

/// Read the audio front-end without changing the user's camera settings. The
/// Tiny 3 Lite exposes several processing controls, but they are optional by
/// firmware and must be observed before an interaction policy relies on them.
void inspectAudioFrontEnd(
    const std::shared_ptr<Device> &device,
    const DeviceCapabilities &capabilities,
    Trace &trace
) noexcept {
    using GetAudioAGC = int (*)(Device *, bool &);
    using GetAudioNoiseReduce = int (*)(Device *, bool &, int &);
    using GetAudioVQEType = int (*)(Device *, Device::DevAudioVQEType &);
    using GetAudioSourceMute = int (*)(Device *, bool &);
    using GetAudioVolume = int (*)(Device *, int16_t &);

    const auto getAudioAGC = reinterpret_cast<GetAudioAGC>(
        dlsym(RTLD_DEFAULT, "_ZN6Device18cameraGetAudioAGCRERb")
    );
    const auto getAudioNoiseReduce = reinterpret_cast<GetAudioNoiseReduce>(
        dlsym(RTLD_DEFAULT, "_ZN6Device26cameraGetAudioNoiseReduceRERbRi")
    );
    const auto getAudioVQEType = reinterpret_cast<GetAudioVQEType>(
        dlsym(RTLD_DEFAULT, "_ZN6Device22cameraGetAudioVQETypeRERNS_15DevAudioVQETypeE")
    );
    const auto getAudioSourceMute = reinterpret_cast<GetAudioSourceMute>(
        dlsym(RTLD_DEFAULT, "_ZN6Device25cameraGetAudioSourceMuteRERb")
    );
    const auto getAudioVolume = reinterpret_cast<GetAudioVolume>(
        dlsym(RTLD_DEFAULT, "_ZN6Device21cameraGetAudioVolumeRERs")
    );

    Device::CameraStatus status {};
    bool agc = false;
    bool noiseReduce = false;
    int noiseLevel = 0;
    Device::DevAudioVQEType vqe = Device::DevAudioVQENone;
    bool muted = false;
    int16_t volume = 0;
    int statusResult = RM_RET_ERR;
    int agcResult = RM_RET_ERR;
    int noiseResult = RM_RET_ERR;
    int vqeResult = RM_RET_ERR;
    int muteResult = RM_RET_ERR;
    int volumeResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { statusResult = device->cameraGetCameraStatusU(status); } catch (...) {}
        if (getAudioAGC) {
            try { agcResult = getAudioAGC(device.get(), agc); } catch (...) {}
        }
        if (getAudioNoiseReduce) {
            try { noiseResult = getAudioNoiseReduce(device.get(), noiseReduce, noiseLevel); } catch (...) {}
        }
        if (getAudioVQEType) {
            try { vqeResult = getAudioVQEType(device.get(), vqe); } catch (...) {}
        }
        if (getAudioSourceMute) {
            try { muteResult = getAudioSourceMute(device.get(), muted); } catch (...) {}
        }
        if (getAudioVolume) {
            try { volumeResult = getAudioVolume(device.get(), volume); } catch (...) {}
        }
    }

    const std::string message = "profile=" + std::string(capabilities.identifier)
        + "; status_result=" + std::to_string(statusResult)
        + "; mode=" + (statusResult == RM_RET_OK ? std::to_string(status.tiny.audio_mode.mode) : "unavailable")
        + "; agc_result=" + std::to_string(agcResult)
        + "; agc=" + (agcResult == RM_RET_OK ? (agc ? "on" : "off") : "unavailable")
        + "; noise_reduce_result=" + std::to_string(noiseResult)
        + "; noise_reduce=" + (noiseResult == RM_RET_OK ? (noiseReduce ? "on" : "off") : "unavailable")
        + "; noise_level=" + (noiseResult == RM_RET_OK ? std::to_string(noiseLevel) : "unavailable")
        + "; vqe_result=" + std::to_string(vqeResult)
        + "; vqe_mode=" + (vqeResult == RM_RET_OK ? std::to_string(static_cast<int>(vqe)) : "unavailable")
        + "; mute_result=" + std::to_string(muteResult)
        + "; muted=" + (muteResult == RM_RET_OK ? (muted ? "true" : "false") : "unavailable")
        + "; volume_result=" + std::to_string(volumeResult)
        + "; volume=" + (volumeResult == RM_RET_OK ? std::to_string(volume) : "unavailable");
    trace.event("audio.capability", "firmware", "frontend_observed", RM_RET_OK, message, "startup-audio-frontend");
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_AUDIO_FRONTEND profile=" << capabilities.identifier
                  << " status_result=" << statusResult
                  << " mode=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.audio_mode.mode) : "unavailable")
                  << " agc_result=" << agcResult
                  << " agc=" << (agcResult == RM_RET_OK ? (agc ? "on" : "off") : "unavailable")
                  << " noise_reduce_result=" << noiseResult
                  << " noise_reduce=" << (noiseResult == RM_RET_OK ? (noiseReduce ? "on" : "off") : "unavailable")
                  << " noise_level=" << (noiseResult == RM_RET_OK ? std::to_string(noiseLevel) : "unavailable")
                  << " vqe_result=" << vqeResult
                  << " vqe_mode=" << (vqeResult == RM_RET_OK ? std::to_string(static_cast<int>(vqe)) : "unavailable")
                  << " mute_result=" << muteResult
                  << " muted=" << (muteResult == RM_RET_OK ? (muted ? "true" : "false") : "unavailable")
                  << " volume_result=" << volumeResult
                  << " volume=" << (volumeResult == RM_RET_OK ? std::to_string(volume) : "unavailable")
                  << "\n" << std::flush;
        if (statusResult == RM_RET_OK) {
            std::cerr << "SOMA_AUDIO_MODE mode=" << static_cast<int>(status.tiny.audio_mode.mode)
                      << " source=" << static_cast<int>(status.tiny.audio_mode.source)
                      << "\n" << std::flush;
        }
    } catch (...) {}
}

bool setCameraAudioMode(
    const std::shared_ptr<Device> &device,
    DiscoveryResult::Profile profile,
    Trace &trace,
    int requestedMode,
    const std::string &commandID
) noexcept {
    using SetAudioMode = int32_t (*)(Device *, Device::AudioMode);
    if (profile != DiscoveryResult::Profile::tiny3Lite || requestedMode < Device::AudioModeOmni
        || requestedMode >= Device::AudioModeButt) {
        trace.event("audio.ack", "fault", "audio_mode_unsupported", RM_RET_ERR,
                    "requested_mode=" + std::to_string(requestedMode), commandID);
        return false;
    }
    const auto set = reinterpret_cast<SetAudioMode>(
        dlsym(RTLD_DEFAULT, "_ZN6Device19cameraSetAudioModeUENS_9AudioModeE")
    );
    Device::CameraStatus initialStatus {};
    int statusResult = RM_RET_ERR;
    int setResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { statusResult = device->cameraGetCameraStatusU(initialStatus); } catch (...) {}
        if (statusResult == RM_RET_OK && set) {
            const Device::AudioMode audioMode {
                initialStatus.tiny.audio_mode.source,
                static_cast<uint8_t>(requestedMode)
            };
            try { setResult = set(device.get(), audioMode); } catch (...) {}
        }
    }
    std::optional<uint8_t> confirmedMode;
    std::optional<uint8_t> confirmedSource;
    const auto deadline = Clock::now() + std::chrono::milliseconds(1'500);
    while (setResult == RM_RET_OK && Clock::now() < deadline && !interrupted) {
        Device::CameraStatus status {};
        int result = RM_RET_ERR;
        {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try { result = device->cameraGetCameraStatusU(status); } catch (...) {}
        }
        if (result == RM_RET_OK) {
            confirmedMode = static_cast<uint8_t>(status.tiny.audio_mode.mode);
            confirmedSource = static_cast<uint8_t>(status.tiny.audio_mode.source);
            if (*confirmedMode == requestedMode) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    const bool confirmed = setResult == RM_RET_OK && confirmedMode && *confirmedMode == requestedMode;
    trace.event(
        "audio.ack",
        confirmed ? "firmware" : "fault",
        confirmed ? "audio_mode_active" : "audio_mode_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        "requested_mode=" + std::to_string(requestedMode)
            + "; status_result=" + std::to_string(statusResult)
            + "; set_result=" + std::to_string(setResult)
            + "; reported_mode=" + (confirmedMode ? std::to_string(*confirmedMode) : "unavailable")
            + "; reported_source=" + (confirmedSource ? std::to_string(*confirmedSource) : "unavailable"),
        commandID
    );
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_AUDIO_MODE requested=" << requestedMode
                  << " mode=" << (confirmedMode ? std::to_string(*confirmedMode) : "unavailable")
                  << " source=" << (confirmedSource ? std::to_string(*confirmedSource) : "unavailable")
                  << " confirmed=" << (confirmed ? "true" : "false")
                  << "\n" << std::flush;
    } catch (...) {}
    return confirmed;
}

bool setCameraAudioInputGain(
    const std::shared_ptr<Device> &device,
    DiscoveryResult::Profile profile,
    Trace &trace,
    int requestedPercent,
    const std::string &commandID
) noexcept {
    using GetAudioVolume = int (*)(Device *, int16_t &);
    using SetAudioVolume = int (*)(Device *, int16_t);
    if (profile != DiscoveryResult::Profile::tiny3Lite || requestedPercent < 0 || requestedPercent > 100) {
        trace.event(
            "audio.ack", "fault", "audio_input_gain_unsupported", RM_RET_ERR,
            "requested_percent=" + std::to_string(requestedPercent), commandID
        );
        return false;
    }
    const auto get = reinterpret_cast<GetAudioVolume>(
        dlsym(RTLD_DEFAULT, "_ZN6Device21cameraGetAudioVolumeRERs")
    );
    const auto set = reinterpret_cast<SetAudioVolume>(
        dlsym(RTLD_DEFAULT, "_ZN6Device21cameraSetAudioVolumeREs")
    );
    int16_t baseline = 0;
    int baselineResult = RM_RET_ERR;
    int setResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        if (get) {
            try { baselineResult = get(device.get(), baseline); } catch (...) {}
        }
        if (set) {
            try { setResult = set(device.get(), static_cast<int16_t>(requestedPercent)); } catch (...) {}
        }
    }
    int16_t reported = 0;
    int getResult = RM_RET_ERR;
    bool confirmed = false;
    const auto deadline = Clock::now() + std::chrono::milliseconds(1'500);
    while (setResult == RM_RET_OK && Clock::now() < deadline && !interrupted) {
        {
            std::lock_guard<std::mutex> lock(sdkMutex);
            if (get) {
                try { getResult = get(device.get(), reported); } catch (...) {}
            }
        }
        confirmed = getResult == RM_RET_OK && reported == requestedPercent;
        if (confirmed) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    int rollbackResult = RM_RET_OK;
    if (!confirmed && baselineResult == RM_RET_OK && set) {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { rollbackResult = set(device.get(), baseline); } catch (...) { rollbackResult = RM_RET_ERR; }
    }
    trace.event(
        "audio.ack",
        confirmed ? "firmware" : "fault",
        confirmed ? "audio_input_gain_active" : "audio_input_gain_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        "requested_percent=" + std::to_string(requestedPercent)
            + "; baseline_result=" + std::to_string(baselineResult)
            + "; baseline_percent=" + (baselineResult == RM_RET_OK ? std::to_string(baseline) : "unavailable")
            + "; set_result=" + std::to_string(setResult)
            + "; get_result=" + std::to_string(getResult)
            + "; reported_percent=" + (getResult == RM_RET_OK ? std::to_string(reported) : "unavailable")
            + "; rollback_result=" + std::to_string(rollbackResult),
        commandID
    );
    return confirmed;
}

bool setCameraWhiteBalance(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    bool automatic,
    int temperatureKelvin,
    const std::string &commandID
) noexcept {
    if (!automatic && (temperatureKelvin < 2'000 || temperatureKelvin > 9'000)) {
        trace.event("camera.ack", "fault", "white_balance_out_of_range", RM_RET_ERR,
                    "requested_temperature_kelvin=" + std::to_string(temperatureKelvin), commandID);
        return false;
    }

    const auto requestedType = automatic ? Device::DevWhiteBalanceAuto : Device::DevWhiteBalanceManual;
    const auto requestedParameter = automatic ? 0 : temperatureKelvin;
    int setResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { setResult = device->cameraSetWhiteBalanceR(requestedType, requestedParameter); } catch (...) {}
    }

    Device::DevWhiteBalanceType confirmedType = Device::DevWhiteBalanceAuto;
    int32_t confirmedParameter = 0;
    int getResult = RM_RET_ERR;
    bool confirmed = false;
    const auto deadline = Clock::now() + std::chrono::milliseconds(1'500);
    while (setResult == RM_RET_OK && Clock::now() < deadline && !interrupted) {
        {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try { getResult = device->cameraGetWhiteBalanceR(confirmedType, confirmedParameter); } catch (...) {}
        }
        confirmed = getResult == RM_RET_OK
            && confirmedType == requestedType
            && (automatic || confirmedParameter == requestedParameter);
        if (confirmed) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    const std::string mode = automatic ? "auto" : "manual";
    trace.event(
        "camera.ack",
        confirmed ? "firmware" : "fault",
        confirmed ? "white_balance_active" : "white_balance_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        "requested_mode=" + mode
            + "; requested_temperature_kelvin=" + (automatic ? std::string("automatic") : std::to_string(temperatureKelvin))
            + "; set_result=" + std::to_string(setResult)
            + "; reported_type=" + std::to_string(static_cast<int>(confirmedType))
            + "; reported_parameter=" + std::to_string(confirmedParameter),
        commandID
    );
    if (confirmed) {
        try {
            std::lock_guard<std::mutex> lock(stderrMutex);
            std::cerr << "SOMA_CAMERA_WHITE_BALANCE mode=" << mode
                      << " temperature_kelvin=" << confirmedParameter << "\n" << std::flush;
        } catch (...) {}
    }
    return confirmed;
}

bool setCameraExposureLock(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    bool locked,
    const std::string &commandID
) noexcept {
    bool reportedLocked = false;
    int setResult = RM_RET_ERR;
    int getResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try {
            setResult = device->cameraSetAELockR(locked);
            if (setResult == RM_RET_OK) getResult = device->cameraGetAELockR(reportedLocked);
        } catch (...) {}
    }
    const bool confirmed = setResult == RM_RET_OK && getResult == RM_RET_OK && reportedLocked == locked;
    trace.event(
        "camera.ack",
        confirmed ? "firmware" : "fault",
        confirmed ? "exposure_lock_active" : "exposure_lock_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        std::string("requested_locked=") + (locked ? "true" : "false")
            + "; set_result=" + std::to_string(setResult)
            + "; get_result=" + std::to_string(getResult)
            + "; reported_locked=" + (reportedLocked ? "true" : "false"),
        commandID
    );
    return confirmed;
}

bool setCameraFocus(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    bool automatic,
    int position,
    const std::string &commandID
) noexcept {
    Device::UvcParamRange range {};
    int rangeResult = RM_RET_ERR;
    int baselinePosition = 0;
    bool baselineAutomatic = true;
    int baselineResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { rangeResult = device->cameraGetRangeFocusAbsolute(range); } catch (...) {}
        try { baselineResult = device->cameraGetFocusAbsolute(baselinePosition, baselineAutomatic); } catch (...) {}
    }
    const int requestedPosition = automatic ? baselinePosition : position;
    if (!automatic && (rangeResult != RM_RET_OK || requestedPosition < range.min_ || requestedPosition > range.max_
        || ((requestedPosition - range.min_) % std::max<long>(1L, range.step_) != 0))) {
        trace.event(
            "camera.ack", "fault", "camera_focus_out_of_range", RM_RET_ERR,
            "requested_position=" + std::to_string(requestedPosition)
                + "; range_result=" + std::to_string(rangeResult),
            commandID
        );
        return false;
    }

    int setResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { setResult = device->cameraSetFocusAbsolute(requestedPosition, automatic); } catch (...) {}
    }
    int confirmedPosition = 0;
    bool confirmedAutomatic = !automatic;
    int getResult = RM_RET_ERR;
    bool confirmed = false;
    const auto deadline = Clock::now() + std::chrono::milliseconds(1'500);
    while (setResult == RM_RET_OK && Clock::now() < deadline && !interrupted) {
        {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try { getResult = device->cameraGetFocusAbsolute(confirmedPosition, confirmedAutomatic); } catch (...) {}
        }
        confirmed = getResult == RM_RET_OK
            && confirmedAutomatic == automatic
            && (automatic || confirmedPosition == requestedPosition);
        if (confirmed) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    trace.event(
        "camera.ack",
        confirmed ? "firmware" : "fault",
        confirmed ? "camera_focus_active" : "camera_focus_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        "requested_mode=" + std::string(automatic ? "auto" : "manual")
            + "; requested_position=" + (automatic ? std::string("automatic") : std::to_string(requestedPosition))
            + "; baseline_result=" + std::to_string(baselineResult)
            + "; range=" + (rangeResult == RM_RET_OK
                ? std::to_string(range.min_) + ":" + std::to_string(range.max_)
                    + ":" + std::to_string(range.step_)
                : std::string("unavailable"))
            + "; set_result=" + std::to_string(setResult)
            + "; reported_mode=" + (confirmedAutomatic ? "auto" : "manual")
            + "; reported_position=" + std::to_string(confirmedPosition),
        commandID
    );
    return confirmed;
}

bool setCameraAbsoluteExposure(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    bool automatic,
    int shutterCode,
    const std::string &commandID
) noexcept {
    Device::UvcParamRange range {};
    int rangeResult = RM_RET_ERR;
    int baselineShutter = 0;
    bool baselineAutomatic = true;
    int baselineResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { rangeResult = device->cameraGetRangeExposureAbsolute(range); } catch (...) {}
        try { baselineResult = device->cameraGetExposureAbsolute(baselineShutter, baselineAutomatic); } catch (...) {}
    }
    const int requestedShutter = automatic ? baselineShutter : shutterCode;
    if (!automatic && (rangeResult != RM_RET_OK || requestedShutter < range.min_ || requestedShutter > range.max_
        || ((requestedShutter - range.min_) % std::max<long>(1L, range.step_) != 0))) {
        trace.event(
            "camera.ack", "fault", "camera_absolute_exposure_out_of_range", RM_RET_ERR,
            "requested_shutter_code=" + std::to_string(requestedShutter)
                + "; range_result=" + std::to_string(rangeResult),
            commandID
        );
        return false;
    }

    int setResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { setResult = device->cameraSetExposureAbsolute(requestedShutter, automatic); } catch (...) {}
    }
    int confirmedShutter = 0;
    bool confirmedAutomatic = !automatic;
    int getResult = RM_RET_ERR;
    bool confirmed = false;
    const auto deadline = Clock::now() + std::chrono::milliseconds(1'500);
    while (setResult == RM_RET_OK && Clock::now() < deadline && !interrupted) {
        {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try { getResult = device->cameraGetExposureAbsolute(confirmedShutter, confirmedAutomatic); } catch (...) {}
        }
        confirmed = getResult == RM_RET_OK
            && confirmedAutomatic == automatic
            && (automatic || confirmedShutter == requestedShutter);
        if (confirmed) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    trace.event(
        "camera.ack",
        confirmed ? "firmware" : "fault",
        confirmed ? "camera_absolute_exposure_active" : "camera_absolute_exposure_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        "requested_mode=" + std::string(automatic ? "auto" : "manual")
            + "; requested_shutter_code=" + (automatic ? std::string("automatic") : std::to_string(requestedShutter))
            + "; baseline_result=" + std::to_string(baselineResult)
            + "; range=" + (rangeResult == RM_RET_OK
                ? std::to_string(range.min_) + ":" + std::to_string(range.max_)
                    + ":" + std::to_string(range.step_)
                : std::string("unavailable"))
            + "; set_result=" + std::to_string(setResult)
            + "; reported_mode=" + (confirmedAutomatic ? "auto" : "manual")
            + "; reported_shutter_code=" + std::to_string(confirmedShutter),
        commandID
    );
    return confirmed;
}

bool setCameraFacePriority(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    bool enabled,
    const std::string &commandID
) noexcept {
    int focusSetResult = RM_RET_ERR;
    int aeSetResult = RM_RET_ERR;
    int statusResult = RM_RET_ERR;
    Device::CameraStatus status {};
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try {
            focusSetResult = device->cameraSetFaceFocusR(enabled);
            aeSetResult = device->cameraSetFaceAER(enabled ? 1 : 0);
            if (focusSetResult == RM_RET_OK && aeSetResult == RM_RET_OK) {
                statusResult = device->cameraGetCameraStatusU(status);
            }
        } catch (...) {}
    }
    const bool confirmed = focusSetResult == RM_RET_OK && aeSetResult == RM_RET_OK
        && statusResult == RM_RET_OK
        && (status.tiny.face_auto_focus != 0) == enabled
        && (status.tiny.face_ae != 0) == enabled;
    trace.event(
        "camera.ack",
        confirmed ? "firmware" : "fault",
        confirmed ? "face_priority_active" : "face_priority_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        std::string("requested_enabled=") + (enabled ? "true" : "false")
            + "; face_focus_set_result=" + std::to_string(focusSetResult)
            + "; face_ae_set_result=" + std::to_string(aeSetResult)
            + "; camera_status_result=" + std::to_string(statusResult)
            + "; reported_face_focus=" + std::to_string(status.tiny.face_auto_focus)
            + "; reported_face_ae=" + std::to_string(status.tiny.face_ae),
        commandID
    );
    return confirmed;
}

bool setCameraAntiFlicker(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    int mode,
    const std::string &commandID
) noexcept {
    if (mode < Device::PowerLineFreqOff || mode > Device::PowerLineFreqAuto) {
        trace.event("camera.ack", "fault", "anti_flicker_out_of_range", RM_RET_ERR,
                    "requested_mode=" + std::to_string(mode), commandID);
        return false;
    }
    int setResult = RM_RET_ERR;
    int getResult = RM_RET_ERR;
    int reportedMode = -1;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try {
            setResult = device->cameraSetAntiFlickR(mode);
            if (setResult == RM_RET_OK) getResult = device->cameraGetAntiFlickR(reportedMode);
        } catch (...) {}
    }
    const bool confirmed = setResult == RM_RET_OK && getResult == RM_RET_OK && reportedMode == mode;
    trace.event(
        "camera.ack",
        confirmed ? "firmware" : "fault",
        confirmed ? "anti_flicker_active" : "anti_flicker_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        "requested_mode=" + std::to_string(mode)
            + "; set_result=" + std::to_string(setResult)
            + "; get_result=" + std::to_string(getResult)
            + "; reported_mode=" + std::to_string(reportedMode),
        commandID
    );
    return confirmed;
}

struct CameraImageTuning {
    std::optional<int32_t> brightness;
    std::optional<int32_t> contrast;
    std::optional<int32_t> hue;
    std::optional<int32_t> saturation;
    std::optional<int32_t> sharpness;

    bool containsAdjustment() const noexcept {
        return brightness || contrast || hue || saturation || sharpness;
    }
};

bool setCameraImageTuning(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    const CameraImageTuning &requested,
    const std::string &commandID
) noexcept {
    using Getter = int32_t (Device::*)(int32_t &);
    using Setter = int32_t (Device::*)(int32_t);
    using RangeGetter = int32_t (Device::*)(Device::UvcParamRange &);
    struct Item {
        const char *name;
        std::optional<int32_t> requested;
        Getter get;
        Setter set;
        RangeGetter getRange;
        int32_t baseline = 0;
        int32_t reported = 0;
        Device::UvcParamRange range {};
        int baselineResult = RM_RET_ERR;
        int rangeResult = RM_RET_ERR;
        int setResult = RM_RET_ERR;
        int verifyResult = RM_RET_ERR;
        int restoreResult = RM_RET_ERR;
    };
    std::array<Item, 5> items {{
        {"brightness", requested.brightness, &Device::cameraGetImageBrightnessR, &Device::cameraSetImageBrightnessR, &Device::cameraGetRangeImageBrightnessR},
        {"contrast", requested.contrast, &Device::cameraGetImageContrastR, &Device::cameraSetImageContrastR, &Device::cameraGetRangeImageContrastR},
        {"hue", requested.hue, &Device::cameraGetImageHueR, &Device::cameraSetImageHueR, &Device::cameraGetRangeImageHueR},
        {"saturation", requested.saturation, &Device::cameraGetImageSaturationR, &Device::cameraSetImageSaturationR, &Device::cameraGetRangeImageSaturationR},
        {"sharpness", requested.sharpness, &Device::cameraGetImageSharpR, &Device::cameraSetImageSharpR, &Device::cameraGetRangeImageSharpR},
    }};
    if (!requested.containsAdjustment()) {
        trace.event("camera.ack", "fault", "image_tuning_empty", RM_RET_ERR, "no_requested_values", commandID);
        return false;
    }

    bool preflight = true;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        for (auto &item : items) {
            if (!item.requested) continue;
            try {
                item.rangeResult = (device.get()->*(item.getRange))(item.range);
                item.baselineResult = (device.get()->*(item.get))(item.baseline);
            } catch (...) {
                item.rangeResult = RM_RET_ERR;
                item.baselineResult = RM_RET_ERR;
            }
            preflight = preflight
                && item.rangeResult == RM_RET_OK
                && item.baselineResult == RM_RET_OK
                && *item.requested >= item.range.min_
                && *item.requested <= item.range.max_;
        }
    }
    if (!preflight) {
        trace.event("camera.ack", "fault", "image_tuning_preflight_rejected", RM_RET_ERR,
                    "range_or_baseline_unavailable", commandID);
        return false;
    }

    bool setSucceeded = true;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        for (auto &item : items) {
            if (!item.requested) continue;
            try { item.setResult = (device.get()->*(item.set))(*item.requested); } catch (...) { item.setResult = RM_RET_ERR; }
            setSucceeded = setSucceeded && item.setResult == RM_RET_OK;
        }
    }

    bool verified = setSucceeded;
    if (setSucceeded) {
        std::lock_guard<std::mutex> lock(sdkMutex);
        for (auto &item : items) {
            if (!item.requested) continue;
            try { item.verifyResult = (device.get()->*(item.get))(item.reported); } catch (...) { item.verifyResult = RM_RET_ERR; }
            verified = verified && item.verifyResult == RM_RET_OK && item.reported == *item.requested;
        }
    }

    bool restored = true;
    if (!verified) {
        std::lock_guard<std::mutex> lock(sdkMutex);
        for (auto &item : items) {
            if (!item.requested || item.baselineResult != RM_RET_OK) continue;
            try { item.restoreResult = (device.get()->*(item.set))(item.baseline); } catch (...) { item.restoreResult = RM_RET_ERR; }
            restored = restored && item.restoreResult == RM_RET_OK;
        }
    }

    std::ostringstream message;
    message << "requested_brightness=" << (requested.brightness ? std::to_string(*requested.brightness) : "keep")
            << "; requested_contrast=" << (requested.contrast ? std::to_string(*requested.contrast) : "keep")
            << "; requested_hue=" << (requested.hue ? std::to_string(*requested.hue) : "keep")
            << "; requested_saturation=" << (requested.saturation ? std::to_string(*requested.saturation) : "keep")
            << "; requested_sharpness=" << (requested.sharpness ? std::to_string(*requested.sharpness) : "keep")
            << "; rollback=" << (!verified ? (restored ? "restored" : "incomplete") : "not_needed");
    trace.event(
        "camera.ack",
        verified ? "firmware" : "fault",
        verified ? "image_tuning_active" : "image_tuning_unconfirmed",
        verified ? RM_RET_OK : RM_RET_ERR,
        message.str(),
        commandID
    );
    return verified;
}

std::optional<Device::FovType> fovTypeForDegrees(int degrees) noexcept {
    switch (degrees) {
    case 86: return Device::FovType86;
    case 78: return Device::FovType78;
    case 65: return Device::FovType65;
    default: return std::nullopt;
    }
}

bool setCameraFieldOfView(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    int requestedDegrees,
    const std::string &commandID
) noexcept {
    const auto requestedType = fovTypeForDegrees(requestedDegrees);
    if (!requestedType) {
        trace.event("camera.ack", "fault", "field_of_view_out_of_range", RM_RET_ERR,
                    "requested_degrees=" + std::to_string(requestedDegrees), commandID);
        return false;
    }
    int setResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { setResult = device->cameraSetFovU(*requestedType); } catch (...) {}
    }
    Device::FovType confirmedType = Device::FovTypeNull;
    int getResult = RM_RET_ERR;
    bool confirmed = false;
    const auto deadline = Clock::now() + std::chrono::milliseconds(1'500);
    while (setResult == RM_RET_OK && Clock::now() < deadline && !interrupted) {
        Device::CameraStatus status {};
        {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try { getResult = device->cameraGetCameraStatusU(status); } catch (...) {}
        }
        if (getResult == RM_RET_OK) {
            confirmedType = static_cast<Device::FovType>(status.tiny.fov);
            confirmed = confirmedType == *requestedType;
            if (confirmed) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    trace.event(
        "camera.ack",
        confirmed ? "firmware" : "fault",
        confirmed ? "field_of_view_active" : "field_of_view_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        "requested_degrees=" + std::to_string(requestedDegrees)
            + "; set_result=" + std::to_string(setResult)
            + "; reported_type=" + std::to_string(static_cast<int>(confirmedType)),
        commandID
    );
    if (confirmed) {
        emitHorizontalFieldOfView(requestedDegrees);
        try {
            std::lock_guard<std::mutex> lock(stderrMutex);
            std::cerr << "SOMA_CAMERA_FOV degrees=" << requestedDegrees << "\n" << std::flush;
        } catch (...) {}
    }
    return confirmed;
}

/// Query the imaging controls that the active firmware actually exposes.  SDK
/// declarations cover several OBSBOT families, so these reads are the source
/// of truth for the cognitive camera layer; this probe never changes image
/// settings or autofocus behavior.
void inspectImagingFrontEnd(
    const std::shared_ptr<Device> &device,
    const DeviceCapabilities &capabilities,
    Trace &trace
) noexcept {
    Device::UvcParamRange zoomRange;
    float zoom = 0;
    Device::DevWhiteBalanceType whiteBalance = Device::DevWhiteBalanceAuto;
    int32_t whiteBalanceParameter = 0;
    int32_t wdr = 0;
    int32_t antiFlicker = 0;
    int32_t brightness = 0;
    int32_t contrast = 0;
    int32_t hue = 0;
    int32_t saturation = 0;
    int32_t sharpness = 0;
    Device::DevAutoFocusType autoFocus = Device::DevAutoFocusAutoSelect;
    int32_t focusPosition = 0;
    int32_t absoluteFocusPosition = 0;
    bool absoluteAutoFocus = false;
    Device::UvcParamRange focusRange;
    Device::DevAFCType continuousFocusTarget = Device::DevAFCCenter;
    int32_t exposureMode = Device::DevExposureUnknown;
    int32_t absoluteExposureShutter = 0;
    bool absoluteExposureAutomatic = false;
    Device::UvcParamRange exposureRange;
    uint32_t minimumISO = 0;
    uint32_t maximumISO = 0;
    int32_t exposureBias = 0;
    Device::UvcParamRange exposureBiasRange;
    Device::UvcParamRange antiFlickerRange;
    Device::UvcParamRange whiteBalanceRange;
    std::vector<int32_t> whiteBalanceModes;
    int32_t whiteBalanceMinimum = 0;
    int32_t whiteBalanceMaximum = 0;
    int32_t mirrorFlip = 0;
    int zoomRangeResult = RM_RET_ERR;
    int zoomResult = RM_RET_ERR;
    int whiteBalanceResult = RM_RET_ERR;
    int wdrResult = RM_RET_ERR;
    int antiFlickerResult = RM_RET_ERR;
    int brightnessResult = RM_RET_ERR;
    int contrastResult = RM_RET_ERR;
    int hueResult = RM_RET_ERR;
    int saturationResult = RM_RET_ERR;
    int sharpnessResult = RM_RET_ERR;
    int autoFocusResult = RM_RET_ERR;
    int focusPositionResult = RM_RET_ERR;
    int absoluteFocusResult = RM_RET_ERR;
    int focusRangeResult = RM_RET_ERR;
    int continuousFocusTargetResult = RM_RET_ERR;
    int exposureModeResult = RM_RET_ERR;
    int absoluteExposureResult = RM_RET_ERR;
    int exposureRangeResult = RM_RET_ERR;
    int isoLimitResult = RM_RET_ERR;
    int exposureBiasResult = RM_RET_ERR;
    int exposureBiasRangeResult = RM_RET_ERR;
    int antiFlickerRangeResult = RM_RET_ERR;
    int whiteBalanceRangeResult = RM_RET_ERR;
    int whiteBalanceModesResult = RM_RET_ERR;
    int mirrorFlipResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { zoomRangeResult = device->cameraGetRangeZoomAbsoluteR(zoomRange); } catch (...) {}
        try { zoomResult = device->cameraGetZoomAbsoluteR(zoom); } catch (...) {}
        try { whiteBalanceResult = device->cameraGetWhiteBalanceR(whiteBalance, whiteBalanceParameter); } catch (...) {}
        try { wdrResult = device->cameraGetWdrR(wdr); } catch (...) {}
        try { antiFlickerResult = device->cameraGetAntiFlickR(antiFlicker); } catch (...) {}
        try { brightnessResult = device->cameraGetImageBrightnessR(brightness); } catch (...) {}
        try { contrastResult = device->cameraGetImageContrastR(contrast); } catch (...) {}
        try { hueResult = device->cameraGetImageHueR(hue); } catch (...) {}
        try { saturationResult = device->cameraGetImageSaturationR(saturation); } catch (...) {}
        try { sharpnessResult = device->cameraGetImageSharpR(sharpness); } catch (...) {}
        try { autoFocusResult = device->cameraGetAutoFocusModeR(autoFocus); } catch (...) {}
        try { focusPositionResult = device->cameraGetFocusPosR(focusPosition); } catch (...) {}
        try { absoluteFocusResult = device->cameraGetFocusAbsolute(absoluteFocusPosition, absoluteAutoFocus); } catch (...) {}
        try { focusRangeResult = device->cameraGetRangeFocusAbsolute(focusRange); } catch (...) {}
        try { continuousFocusTargetResult = device->cameraGetAFCTrackModeR(continuousFocusTarget); } catch (...) {}
        try { exposureModeResult = device->cameraGetExposureModeR(exposureMode); } catch (...) {}
        try { absoluteExposureResult = device->cameraGetExposureAbsolute(absoluteExposureShutter, absoluteExposureAutomatic); } catch (...) {}
        try { exposureRangeResult = device->cameraGetRangeExposureAbsolute(exposureRange); } catch (...) {}
        try { isoLimitResult = device->cameraGetISOLimitR(minimumISO, maximumISO); } catch (...) {}
        try { exposureBiasResult = device->cameraGetPAEEvBiasR(exposureBias); } catch (...) {}
        try { exposureBiasRangeResult = device->cameraGetRangePAEEvBiasR(exposureBiasRange); } catch (...) {}
        try { antiFlickerRangeResult = device->cameraGetRangeAntiFlickR(antiFlickerRange); } catch (...) {}
        try { whiteBalanceRangeResult = device->cameraGetRangeWhiteBalanceR(whiteBalanceRange); } catch (...) {}
        try { whiteBalanceModesResult = device->cameraGetWhiteBalanceListR(whiteBalanceModes, whiteBalanceMinimum, whiteBalanceMaximum); } catch (...) {}
        try { mirrorFlipResult = device->cameraGetMirrorFlipR(mirrorFlip); } catch (...) {}
    }

    const auto valueOrUnavailable = [](int result, const auto &value) {
        return result == RM_RET_OK ? std::to_string(value) : std::string("unavailable");
    };
    const std::string zoomRangeText = zoomRangeResult == RM_RET_OK
        ? std::to_string(zoomRange.min_) + ":" + std::to_string(zoomRange.max_)
            + ":" + std::to_string(zoomRange.step_)
        : "unavailable";
    const std::string message = "profile=" + std::string(capabilities.identifier)
        + "; zoom_range_result=" + std::to_string(zoomRangeResult)
        + "; zoom_range=" + zoomRangeText
        + "; zoom_result=" + std::to_string(zoomResult)
        + "; zoom=" + valueOrUnavailable(zoomResult, zoom)
        + "; white_balance_result=" + std::to_string(whiteBalanceResult)
        + "; white_balance=" + valueOrUnavailable(whiteBalanceResult, static_cast<int>(whiteBalance))
        + "; white_balance_parameter=" + valueOrUnavailable(whiteBalanceResult, whiteBalanceParameter)
        + "; wdr_result=" + std::to_string(wdrResult)
        + "; wdr=" + valueOrUnavailable(wdrResult, wdr)
        + "; anti_flicker_result=" + std::to_string(antiFlickerResult)
        + "; anti_flicker=" + valueOrUnavailable(antiFlickerResult, antiFlicker);
    const std::string imageStyleMessage = "profile=" + std::string(capabilities.identifier)
        + "; brightness_result=" + std::to_string(brightnessResult)
        + "; brightness=" + valueOrUnavailable(brightnessResult, brightness)
        + "; contrast_result=" + std::to_string(contrastResult)
        + "; contrast=" + valueOrUnavailable(contrastResult, contrast)
        + "; hue_result=" + std::to_string(hueResult)
        + "; hue=" + valueOrUnavailable(hueResult, hue)
        + "; saturation_result=" + std::to_string(saturationResult)
        + "; saturation=" + valueOrUnavailable(saturationResult, saturation)
        + "; sharpness_result=" + std::to_string(sharpnessResult)
        + "; sharpness=" + valueOrUnavailable(sharpnessResult, sharpness);
    const std::string focusMessage = "profile=" + std::string(capabilities.identifier)
        + "; autofocus_result=" + std::to_string(autoFocusResult)
        + "; autofocus_mode=" + valueOrUnavailable(autoFocusResult, static_cast<int>(autoFocus))
        + "; focus_position_result=" + std::to_string(focusPositionResult)
        + "; focus_position=" + valueOrUnavailable(focusPositionResult, focusPosition)
        + "; absolute_focus_result=" + std::to_string(absoluteFocusResult)
        + "; absolute_focus_position=" + valueOrUnavailable(absoluteFocusResult, absoluteFocusPosition)
        + "; absolute_focus_automatic=" + (absoluteFocusResult == RM_RET_OK
            ? std::string(absoluteAutoFocus ? "true" : "false") : std::string("unavailable"))
        + "; focus_range_result=" + std::to_string(focusRangeResult)
        + "; focus_range=" + (focusRangeResult == RM_RET_OK
            ? std::to_string(focusRange.min_) + ":" + std::to_string(focusRange.max_)
                + ":" + std::to_string(focusRange.step_)
            : std::string("unavailable"))
        + "; continuous_focus_target_result=" + std::to_string(continuousFocusTargetResult)
        + "; continuous_focus_target=" + valueOrUnavailable(
            continuousFocusTargetResult, static_cast<int>(continuousFocusTarget)
        );
    const std::string exposureMessage = "profile=" + std::string(capabilities.identifier)
        + "; exposure_mode_result=" + std::to_string(exposureModeResult)
        + "; exposure_mode=" + valueOrUnavailable(exposureModeResult, exposureMode)
        + "; absolute_exposure_result=" + std::to_string(absoluteExposureResult)
        + "; absolute_exposure_shutter=" + valueOrUnavailable(absoluteExposureResult, absoluteExposureShutter)
        + "; absolute_exposure_automatic=" + (absoluteExposureResult == RM_RET_OK
            ? std::string(absoluteExposureAutomatic ? "true" : "false") : std::string("unavailable"))
        + "; exposure_range_result=" + std::to_string(exposureRangeResult)
        + "; exposure_range=" + (exposureRangeResult == RM_RET_OK
            ? std::to_string(exposureRange.min_) + ":" + std::to_string(exposureRange.max_)
                + ":" + std::to_string(exposureRange.step_)
            : std::string("unavailable"))
        + "; iso_limit_result=" + std::to_string(isoLimitResult)
        + "; iso_limits=" + (isoLimitResult == RM_RET_OK
            ? std::to_string(minimumISO) + ":" + std::to_string(maximumISO)
            : std::string("unavailable"))
        + "; exposure_bias_result=" + std::to_string(exposureBiasResult)
        + "; exposure_bias=" + valueOrUnavailable(exposureBiasResult, exposureBias)
        + "; exposure_bias_range_result=" + std::to_string(exposureBiasRangeResult)
        + "; exposure_bias_range=" + (exposureBiasRangeResult == RM_RET_OK
            ? std::to_string(exposureBiasRange.min_) + ":" + std::to_string(exposureBiasRange.max_)
                + ":" + std::to_string(exposureBiasRange.step_)
            : std::string("unavailable"))
        + "; mirror_flip_result=" + std::to_string(mirrorFlipResult)
        + "; mirror_flip=" + valueOrUnavailable(mirrorFlipResult, mirrorFlip)
        + "; anti_flicker_range_result=" + std::to_string(antiFlickerRangeResult)
        + "; anti_flicker_range=" + (antiFlickerRangeResult == RM_RET_OK
            ? std::to_string(antiFlickerRange.min_) + ":" + std::to_string(antiFlickerRange.max_)
                + ":" + std::to_string(antiFlickerRange.step_)
            : std::string("unavailable"));
    const std::string whiteBalanceMessage = "profile=" + std::string(capabilities.identifier)
        + "; white_balance_range_result=" + std::to_string(whiteBalanceRangeResult)
        + "; white_balance_range=" + (whiteBalanceRangeResult == RM_RET_OK
            ? std::to_string(whiteBalanceRange.min_) + ":" + std::to_string(whiteBalanceRange.max_)
                + ":" + std::to_string(whiteBalanceRange.step_)
            : std::string("unavailable"))
        + "; white_balance_modes_result=" + std::to_string(whiteBalanceModesResult)
        + "; white_balance_modes=" + (whiteBalanceModesResult == RM_RET_OK
            ? std::to_string(whiteBalanceModes.size()) + ":" + std::to_string(whiteBalanceMinimum)
                + ":" + std::to_string(whiteBalanceMaximum)
            : std::string("unavailable"));
    trace.event("camera.capability", "firmware", "imaging_observed", RM_RET_OK, message, "startup-imaging-frontend");
    trace.event("camera.capability", "firmware", "image_style_observed", RM_RET_OK, imageStyleMessage, "startup-image-style-frontend");
    trace.event("camera.capability", "firmware", "focus_observed", RM_RET_OK, focusMessage, "startup-focus-frontend");
    trace.event("camera.capability", "firmware", "exposure_observed", RM_RET_OK, exposureMessage, "startup-exposure-frontend");
    trace.event("camera.capability", "firmware", "white_balance_range_observed", RM_RET_OK, whiteBalanceMessage, "startup-white-balance-frontend");
    trace.event(
        "camera.capability",
        absoluteFocusResult == RM_RET_OK ? "firmware" : "fault",
        absoluteFocusResult == RM_RET_OK ? "manual_focus_absolute_observed" : "manual_focus_absolute_unavailable",
        absoluteFocusResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
        "absolute_focus_position=" + valueOrUnavailable(absoluteFocusResult, absoluteFocusPosition)
            + "; automatic=" + (absoluteFocusResult == RM_RET_OK
                ? std::string(absoluteAutoFocus ? "true" : "false") : std::string("unavailable"))
            + "; range=" + (focusRangeResult == RM_RET_OK
                ? std::to_string(focusRange.min_) + ":" + std::to_string(focusRange.max_)
                    + ":" + std::to_string(focusRange.step_)
                : std::string("unavailable"))
            + "; results=" + std::to_string(absoluteFocusResult)
                + "/" + std::to_string(focusRangeResult),
        "startup-manual-focus-frontend"
    );
    trace.event(
        "camera.capability",
        continuousFocusTargetResult == RM_RET_OK ? "firmware" : "fault",
        continuousFocusTargetResult == RM_RET_OK
            ? "continuous_focus_target_observed" : "continuous_focus_target_unavailable",
        continuousFocusTargetResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
        "target_mode=" + valueOrUnavailable(
            continuousFocusTargetResult, static_cast<int>(continuousFocusTarget)
        ) + "; result=" + std::to_string(continuousFocusTargetResult),
        "startup-continuous-focus-frontend"
    );
    trace.event(
        "camera.capability",
        absoluteExposureResult == RM_RET_OK ? "firmware" : "fault",
        absoluteExposureResult == RM_RET_OK
            ? "manual_exposure_absolute_observed" : "manual_exposure_absolute_unavailable",
        absoluteExposureResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
        "shutter=" + valueOrUnavailable(absoluteExposureResult, absoluteExposureShutter)
            + "; automatic=" + (absoluteExposureResult == RM_RET_OK
                ? std::string(absoluteExposureAutomatic ? "true" : "false") : std::string("unavailable"))
            + "; range=" + (exposureRangeResult == RM_RET_OK
                ? std::to_string(exposureRange.min_) + ":" + std::to_string(exposureRange.max_)
                    + ":" + std::to_string(exposureRange.step_)
                : std::string("unavailable"))
            + "; results=" + std::to_string(absoluteExposureResult)
                + "/" + std::to_string(exposureRangeResult),
        "startup-manual-exposure-frontend"
    );
    trace.event(
        "camera.capability",
        antiFlickerRangeResult == RM_RET_OK ? "firmware" : "fault",
        antiFlickerRangeResult == RM_RET_OK
            ? "anti_flicker_range_observed" : "anti_flicker_range_unavailable",
        antiFlickerRangeResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
        "range=" + (antiFlickerRangeResult == RM_RET_OK
            ? std::to_string(antiFlickerRange.min_) + ":" + std::to_string(antiFlickerRange.max_)
                + ":" + std::to_string(antiFlickerRange.step_)
            : std::string("unavailable"))
            + "; result=" + std::to_string(antiFlickerRangeResult),
        "startup-anti-flicker-range"
    );
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_CAMERA_OPTICS " << message << "\n" << std::flush;
        if (zoomResult == RM_RET_OK) {
            std::cerr << "SOMA_CAMERA_ZOOM factor=" << zoom << "\n" << std::flush;
        }
    } catch (...) {}
}

/// Tiny-series firmware exposes hardware noise-reduction intensities through
/// OBSBOT Center. The medium level preserves conversational speech while
/// avoiding aggressive suppression that can erase quiet turn onsets.
void configureConversationAudioProcessing(const std::shared_ptr<Device> &device, Trace &trace) noexcept {
    constexpr int kMediumNoiseReductionLevel = 5;
    using GetAudioAGC = int (*)(Device *, bool &);
    using GetAudioNoiseReduce = int (*)(Device *, bool &, int &);
    using SetAudioNoiseReduce = int (*)(Device *, bool, int);
    const auto getAudioAGC = reinterpret_cast<GetAudioAGC>(
        dlsym(RTLD_DEFAULT, "_ZN6Device18cameraGetAudioAGCRERb")
    );
    const auto getAudioNoiseReduce = reinterpret_cast<GetAudioNoiseReduce>(
        dlsym(RTLD_DEFAULT, "_ZN6Device26cameraGetAudioNoiseReduceRERbRi")
    );
    const auto setAudioNoiseReduce = reinterpret_cast<SetAudioNoiseReduce>(
        dlsym(RTLD_DEFAULT, "_ZN6Device26cameraSetAudioNoiseReduceREbi")
    );

    std::optional<bool> agcBefore;
    std::optional<bool> noiseBefore;
    std::optional<int> noiseLevelBefore;
    int statusBeforeResult = RM_RET_ERR;
    int agcQueryBeforeResult = RM_RET_ERR;
    int noiseQueryBeforeResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        Device::CameraStatus status{};
        statusBeforeResult = device->cameraGetCameraStatusU(status);
        if (statusBeforeResult == RM_RET_OK) {
            agcBefore = status.tiny.audio_auto_gain != 0;
            noiseBefore = status.tiny.noise_cancellation != 0;
        }
        if (getAudioAGC) {
            bool enabled = false;
            agcQueryBeforeResult = getAudioAGC(device.get(), enabled);
            if (agcQueryBeforeResult == RM_RET_OK) agcBefore = enabled;
        }
        if (getAudioNoiseReduce) {
            bool enabled = false;
            int level = 0;
            noiseQueryBeforeResult = getAudioNoiseReduce(device.get(), enabled, level);
            if (noiseQueryBeforeResult == RM_RET_OK) {
                noiseBefore = enabled;
                noiseLevelBefore = level;
            }
        }
    }

    int agcSetResult = RM_RET_OK;
    int noiseSetResult = RM_RET_OK;
    bool agcChanged = false;
    bool noiseChanged = false;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        if (agcBefore && !*agcBefore) {
            try { agcSetResult = device->cameraSetAudioAutoGainU(true); } catch (...) { agcSetResult = RM_RET_ERR; }
            agcChanged = agcSetResult == RM_RET_OK;
        }
        if (noiseBefore && !*noiseBefore && setAudioNoiseReduce) {
            try {
                noiseSetResult = setAudioNoiseReduce(device.get(), true, kMediumNoiseReductionLevel);
            } catch (...) {
                noiseSetResult = RM_RET_ERR;
            }
            noiseChanged = noiseSetResult == RM_RET_OK;
        } else if (!setAudioNoiseReduce) {
            noiseSetResult = RM_RET_ERR;
        }
    }

    std::optional<bool> agcAfter;
    std::optional<bool> noiseAfter;
    std::optional<int> noiseLevelAfter;
    int statusAfterResult = RM_RET_ERR;
    int agcQueryAfterResult = RM_RET_ERR;
    int noiseQueryAfterResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        Device::CameraStatus status{};
        statusAfterResult = device->cameraGetCameraStatusU(status);
        if (statusAfterResult == RM_RET_OK) {
            agcAfter = status.tiny.audio_auto_gain != 0;
            noiseAfter = status.tiny.noise_cancellation != 0;
        }
        if (getAudioAGC) {
            bool enabled = false;
            agcQueryAfterResult = getAudioAGC(device.get(), enabled);
            if (agcQueryAfterResult == RM_RET_OK) agcAfter = enabled;
        }
        if (getAudioNoiseReduce) {
            bool enabled = false;
            int level = 0;
            noiseQueryAfterResult = getAudioNoiseReduce(device.get(), enabled, level);
            if (noiseQueryAfterResult == RM_RET_OK) {
                noiseAfter = enabled;
                noiseLevelAfter = level;
            }
        }
    }

    const bool agcReady = agcAfter.value_or(false);
    const bool noiseReady = noiseAfter.value_or(false);
    trace.event(
        "audio.processing",
        "firmware",
        agcReady && noiseReady ? "conversation_profile_active" : "conversation_profile_partial",
        agcReady && noiseReady ? RM_RET_OK : RM_RET_ERR,
        "profile=conversation; agc_before=" + audioProcessingValue(agcBefore)
            + "; requested_noise_level=" + std::to_string(kMediumNoiseReductionLevel)
            + "; agc_changed=" + (agcChanged ? "true" : "false")
            + "; agc_set_result=" + std::to_string(agcSetResult)
            + "; agc_after=" + audioProcessingValue(agcAfter)
            + "; noise_before=" + audioProcessingValue(noiseBefore)
            + "; noise_level_before=" + audioProcessingValue(noiseLevelBefore)
            + "; noise_changed=" + (noiseChanged ? "true" : "false")
            + "; noise_set_result=" + std::to_string(noiseSetResult)
            + "; noise_after=" + audioProcessingValue(noiseAfter)
            + "; noise_level_after=" + audioProcessingValue(noiseLevelAfter)
            + "; status_results=" + std::to_string(statusBeforeResult)
            + "," + std::to_string(statusAfterResult)
            + "; direct_query_results=" + std::to_string(agcQueryBeforeResult)
            + "," + std::to_string(agcQueryAfterResult)
            + "," + std::to_string(noiseQueryBeforeResult)
            + "," + std::to_string(noiseQueryAfterResult)
    );
}

struct NativeTrackingControlReadback {
    bool motion = false;
    bool foreTarget = false;
    bool composition = false;
    bool panGainAdaptive = false;
    bool panLocked = false;
    bool pitchGainAdaptive = false;
    bool pitchLocked = false;
    bool offsetAdaptiveX = false;
    bool offsetAdaptiveY = false;
    bool limitAutoSelection = false;
    int trackerType = -1;
    int gimbalControlMode = -1;
    int gimbalSpeedMode = -1;
    int autoZoomCustomized = -1;
    int autoZoomMode = -1;
    int autoZoomSpeed = -1;
    float panGain = 0;
    float pitchGain = 0;
    float offsetX = 0;
    float offsetY = 0;
    float limitPanMinimum = 0;
    float limitPanMaximum = 0;
    float limitPitchMinimum = 0;
    float limitPitchMaximum = 0;
    int motionResult = RM_RET_ERR;
    int foreTargetResult = RM_RET_ERR;
    int compositionResult = RM_RET_ERR;
    int panGainAdaptiveResult = RM_RET_ERR;
    int panLockedResult = RM_RET_ERR;
    int pitchGainAdaptiveResult = RM_RET_ERR;
    int pitchLockedResult = RM_RET_ERR;
    int offsetAdaptiveXResult = RM_RET_ERR;
    int offsetAdaptiveYResult = RM_RET_ERR;
    int limitAutoSelectionResult = RM_RET_ERR;
    int trackerTypeResult = RM_RET_ERR;
    int gimbalControlModeResult = RM_RET_ERR;
    int gimbalSpeedModeResult = RM_RET_ERR;
    int autoZoomCustomizedResult = RM_RET_ERR;
    int autoZoomModeResult = RM_RET_ERR;
    int autoZoomSpeedResult = RM_RET_ERR;
    int panGainResult = RM_RET_ERR;
    int pitchGainResult = RM_RET_ERR;
    int offsetXResult = RM_RET_ERR;
    int offsetYResult = RM_RET_ERR;
    int limitPanMinimumResult = RM_RET_ERR;
    int limitPanMaximumResult = RM_RET_ERR;
    int limitPitchMinimumResult = RM_RET_ERR;
    int limitPitchMaximumResult = RM_RET_ERR;
};

NativeTrackingControlReadback readNativeTrackingControls(
    Device &device,
    Device::DevControlTargetType target
) noexcept {
    NativeTrackingControlReadback values;
    try { values.motionResult = device.aiGetControlParaR(target, Device::DevControlParaTypeMotion, values.motion); } catch (...) {}
    try { values.foreTargetResult = device.aiGetControlParaR(target, Device::DevControlParaTypeForeTrack, values.foreTarget); } catch (...) {}
    try { values.compositionResult = device.aiGetControlParaR(target, Device::DevControlParaTypeComposition, values.composition); } catch (...) {}
    try { values.panGainAdaptiveResult = device.aiGetControlParaR(target, Device::DevControlParaTypePanGainAdaptive, values.panGainAdaptive); } catch (...) {}
    try { values.panLockedResult = device.aiGetControlParaR(target, Device::DevControlParaTypePanLocked, values.panLocked); } catch (...) {}
    try { values.pitchGainAdaptiveResult = device.aiGetControlParaR(target, Device::DevControlParaTypePitchGainAdaptive, values.pitchGainAdaptive); } catch (...) {}
    try { values.pitchLockedResult = device.aiGetControlParaR(target, Device::DevControlParaTypePitchLocked, values.pitchLocked); } catch (...) {}
    try { values.offsetAdaptiveXResult = device.aiGetControlParaR(target, Device::DevControlParaTypeOffsetAdaptiveX, values.offsetAdaptiveX); } catch (...) {}
    try { values.offsetAdaptiveYResult = device.aiGetControlParaR(target, Device::DevControlParaTypeOffsetAdaptiveY, values.offsetAdaptiveY); } catch (...) {}
    try { values.limitAutoSelectionResult = device.aiGetControlParaR(target, Device::DevControlParaTypeLimitAutoSelection, values.limitAutoSelection); } catch (...) {}
    try { values.trackerTypeResult = device.aiGetControlParaR(target, Device::DevControlParaTypeTrackerType, values.trackerType); } catch (...) {}
    try { values.gimbalControlModeResult = device.aiGetControlParaR(target, Device::DevControlParaTypeGimCtrlMode, values.gimbalControlMode); } catch (...) {}
    try { values.gimbalSpeedModeResult = device.aiGetControlParaR(target, Device::DevControlParaTypeGimCtrlSpeedMode, values.gimbalSpeedMode); } catch (...) {}
    try { values.autoZoomCustomizedResult = device.aiGetControlParaR(target, Device::DevControlParaTypeAutoZoomCustomized, values.autoZoomCustomized); } catch (...) {}
    try { values.autoZoomModeResult = device.aiGetControlParaR(target, Device::DevControlParaTypeAutoZoomMode, values.autoZoomMode); } catch (...) {}
    try { values.autoZoomSpeedResult = device.aiGetControlParaR(target, Device::DevControlParaTypeAutoZoomSpeed, values.autoZoomSpeed); } catch (...) {}
    try { values.panGainResult = device.aiGetControlParaR(target, Device::DevControlParaTypePanGainValue, values.panGain); } catch (...) {}
    try { values.pitchGainResult = device.aiGetControlParaR(target, Device::DevControlParaTypePitchGainValue, values.pitchGain); } catch (...) {}
    try { values.offsetXResult = device.aiGetControlParaR(target, Device::DevControlParaTypeOffsetX, values.offsetX); } catch (...) {}
    try { values.offsetYResult = device.aiGetControlParaR(target, Device::DevControlParaTypeOffsetY, values.offsetY); } catch (...) {}
    try { values.limitPanMinimumResult = device.aiGetControlParaR(target, Device::DevControlParaTypeLimitPanMin, values.limitPanMinimum); } catch (...) {}
    try { values.limitPanMaximumResult = device.aiGetControlParaR(target, Device::DevControlParaTypeLimitPanMax, values.limitPanMaximum); } catch (...) {}
    try { values.limitPitchMinimumResult = device.aiGetControlParaR(target, Device::DevControlParaTypeLimitPitchMin, values.limitPitchMinimum); } catch (...) {}
    try { values.limitPitchMaximumResult = device.aiGetControlParaR(target, Device::DevControlParaTypeLimitPitchMax, values.limitPitchMaximum); } catch (...) {}
    return values;
}

std::string nativeTrackingControlCoreSummary(
    const char *targetName,
    const NativeTrackingControlReadback &values
) {
    const auto boolValue = [](int result, bool value) {
        return result == RM_RET_OK ? (value ? "true" : "false") : "unavailable";
    };
    const auto intValue = [](int result, int value) {
        return result == RM_RET_OK ? std::to_string(value) : std::string("unavailable");
    };
    const auto floatValue = [](int result, float value) {
        return result == RM_RET_OK ? std::to_string(value) : std::string("unavailable");
    };
    return "target=" + std::string(targetName)
        + "; motion=" + boolValue(values.motionResult, values.motion)
        + "; fore_target=" + boolValue(values.foreTargetResult, values.foreTarget)
        + "; composition=" + boolValue(values.compositionResult, values.composition)
        + "; tracker_type=" + intValue(values.trackerTypeResult, values.trackerType)
        + "; gimbal_mode=" + intValue(values.gimbalControlModeResult, values.gimbalControlMode)
        + "; speed_mode=" + intValue(values.gimbalSpeedModeResult, values.gimbalSpeedMode);
}

std::string nativeTrackingControlDynamicsSummary(
    const char *targetName,
    const NativeTrackingControlReadback &values
) {
    const auto boolValue = [](int result, bool value) {
        return result == RM_RET_OK ? (value ? "true" : "false") : "unavailable";
    };
    const auto floatValue = [](int result, float value) {
        return result == RM_RET_OK ? std::to_string(value) : std::string("unavailable");
    };
    return "target=" + std::string(targetName)
        + "; pan_gain_adaptive=" + boolValue(values.panGainAdaptiveResult, values.panGainAdaptive)
        + "; pan_gain=" + floatValue(values.panGainResult, values.panGain)
        + "; pan_locked=" + boolValue(values.panLockedResult, values.panLocked)
        + "; pitch_gain_adaptive=" + boolValue(values.pitchGainAdaptiveResult, values.pitchGainAdaptive)
        + "; pitch_gain=" + floatValue(values.pitchGainResult, values.pitchGain)
        + "; pitch_locked=" + boolValue(values.pitchLockedResult, values.pitchLocked);
}

std::string nativeTrackingControlFramingSummary(
    const char *targetName,
    const NativeTrackingControlReadback &values
) {
    const auto boolValue = [](int result, bool value) {
        return result == RM_RET_OK ? (value ? "true" : "false") : "unavailable";
    };
    const auto intValue = [](int result, int value) {
        return result == RM_RET_OK ? std::to_string(value) : std::string("unavailable");
    };
    const auto floatValue = [](int result, float value) {
        return result == RM_RET_OK ? std::to_string(value) : std::string("unavailable");
    };
    return "target=" + std::string(targetName)
        + "; auto_zoom_custom=" + intValue(values.autoZoomCustomizedResult, values.autoZoomCustomized)
        + "; auto_zoom_mode=" + intValue(values.autoZoomModeResult, values.autoZoomMode)
        + "; auto_zoom_speed=" + intValue(values.autoZoomSpeedResult, values.autoZoomSpeed)
        + "; offset_adaptive_x=" + boolValue(values.offsetAdaptiveXResult, values.offsetAdaptiveX)
        + "; offset_x=" + floatValue(values.offsetXResult, values.offsetX)
        + "; offset_adaptive_y=" + boolValue(values.offsetAdaptiveYResult, values.offsetAdaptiveY)
        + "; offset_y=" + floatValue(values.offsetYResult, values.offsetY);
}

std::string nativeTrackingControlLimitsSummary(
    const char *targetName,
    const NativeTrackingControlReadback &values
) {
    const auto boolValue = [](int result, bool value) {
        return result == RM_RET_OK ? (value ? "true" : "false") : "unavailable";
    };
    const auto floatValue = [](int result, float value) {
        return result == RM_RET_OK ? std::to_string(value) : std::string("unavailable");
    };
    return "target=" + std::string(targetName)
        + "; limit_auto_selection=" + boolValue(values.limitAutoSelectionResult, values.limitAutoSelection)
        + "; limits=" + floatValue(values.limitPanMinimumResult, values.limitPanMinimum)
            + ":" + floatValue(values.limitPanMaximumResult, values.limitPanMaximum)
            + ":" + floatValue(values.limitPitchMinimumResult, values.limitPitchMinimum)
            + ":" + floatValue(values.limitPitchMaximumResult, values.limitPitchMaximum);
}

void inspectNativeTrackingFrontEnd(
    const std::shared_ptr<Device> &device,
    DiscoveryResult::Profile profile,
    Trace &trace
) noexcept {
    if (profile != DiscoveryResult::Profile::tiny3Lite) return;
    int gimbalSpeedMode = -1;
    bool motionTracking = false;
    bool foreTracking = false;
    bool adaptiveComposition = false;
    bool adaptivePanGain = false;
    bool adaptivePitchGain = false;
    int speedResult = RM_RET_ERR;
    int motionResult = RM_RET_ERR;
    int foreResult = RM_RET_ERR;
    int compositionResult = RM_RET_ERR;
    int adaptivePanGainResult = RM_RET_ERR;
    int adaptivePitchGainResult = RM_RET_ERR;
    NativeTrackingControlReadback humanControls;
    NativeTrackingControlReadback animalControls;
    NativeTrackingControlReadback objectControls;
    try {
        std::lock_guard<std::mutex> lock(sdkMutex);
        speedResult = device->aiGetControlParaR(
            Device::DevControlTargetTypeHuman,
            Device::DevControlParaTypeGimCtrlSpeedMode,
            gimbalSpeedMode
        );
        motionResult = device->aiGetControlParaR(
            Device::DevControlTargetTypeHuman,
            Device::DevControlParaTypeMotion,
            motionTracking
        );
        foreResult = device->aiGetControlParaR(
            Device::DevControlTargetTypeHuman,
            Device::DevControlParaTypeForeTrack,
            foreTracking
        );
        compositionResult = device->aiGetControlParaR(
            Device::DevControlTargetTypeHuman,
            Device::DevControlParaTypeComposition,
            adaptiveComposition
        );
        adaptivePanGainResult = device->aiGetControlParaR(
            Device::DevControlTargetTypeHuman,
            Device::DevControlParaTypePanGainAdaptive,
            adaptivePanGain
        );
        adaptivePitchGainResult = device->aiGetControlParaR(
            Device::DevControlTargetTypeHuman,
            Device::DevControlParaTypePitchGainAdaptive,
            adaptivePitchGain
        );
        humanControls = readNativeTrackingControls(*device, Device::DevControlTargetTypeHuman);
        animalControls = readNativeTrackingControls(*device, Device::DevControlTargetTypeAnimal);
        objectControls = readNativeTrackingControls(*device, Device::DevControlTargetTypeObject);
    } catch (...) {}
    const bool observed = speedResult == RM_RET_OK
        || motionResult == RM_RET_OK
        || foreResult == RM_RET_OK
        || compositionResult == RM_RET_OK;
    trace.event(
        "camera.capability",
        observed ? "firmware" : "fault",
        observed ? "native_tracking_frontend_observed" : "native_tracking_frontend_unavailable",
        observed ? RM_RET_OK : RM_RET_ERR,
        "profile=tiny_3_lite; speed_mode=" + std::to_string(gimbalSpeedMode)
            + "; motion=" + (motionTracking ? "true" : "false")
            + "; fore_target=" + (foreTracking ? "true" : "false")
            + "; adaptive_composition=" + (adaptiveComposition ? "true" : "false")
            + "; adaptive_pan_gain=" + (adaptivePanGain ? "true" : "false")
            + "; adaptive_pitch_gain=" + (adaptivePitchGain ? "true" : "false")
            + "; read_results=" + std::to_string(speedResult)
            + "/" + std::to_string(motionResult)
            + "/" + std::to_string(foreResult)
            + "/" + std::to_string(compositionResult)
            + "/" + std::to_string(adaptivePanGainResult)
            + "/" + std::to_string(adaptivePitchGainResult),
        "startup-native-tracking-frontend"
    );
    const auto emitControlSurface = [&trace](
        const char *targetName,
        const NativeTrackingControlReadback &controls
    ) {
        const bool observed = controls.motionResult == RM_RET_OK;
        const std::string target(targetName);
        const std::string commandPrefix = "startup-native-tracking-" + target + "-";
        trace.event(
            "camera.capability",
            observed ? "firmware" : "fault",
            "native_tracking_" + target + "_core_" + (observed ? "observed" : "unavailable"),
            observed ? RM_RET_OK : RM_RET_ERR,
            nativeTrackingControlCoreSummary(targetName, controls),
            commandPrefix + "core"
        );
        trace.event(
            "camera.capability",
            controls.panGainResult == RM_RET_OK ? "firmware" : "fault",
            "native_tracking_" + target + "_dynamics_"
                + (controls.panGainResult == RM_RET_OK ? "observed" : "unavailable"),
            controls.panGainResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
            nativeTrackingControlDynamicsSummary(targetName, controls),
            commandPrefix + "dynamics"
        );
        trace.event(
            "camera.capability",
            controls.autoZoomModeResult == RM_RET_OK ? "firmware" : "fault",
            "native_tracking_" + target + "_framing_"
                + (controls.autoZoomModeResult == RM_RET_OK ? "observed" : "unavailable"),
            controls.autoZoomModeResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
            nativeTrackingControlFramingSummary(targetName, controls),
            commandPrefix + "framing"
        );
        trace.event(
            "camera.capability",
            controls.limitPanMinimumResult == RM_RET_OK ? "firmware" : "fault",
            "native_tracking_" + target + "_limits_"
                + (controls.limitPanMinimumResult == RM_RET_OK ? "observed" : "unavailable"),
            controls.limitPanMinimumResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
            nativeTrackingControlLimitsSummary(targetName, controls),
            commandPrefix + "limits"
        );
    };
    emitControlSurface("human", humanControls);
    emitControlSurface("animal", animalControls);
    emitControlSurface("object", objectControls);
}

bool waitForMode(const std::shared_ptr<Device> &device, int expectedMode, int timeoutMilliseconds) {
    const auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMilliseconds);
    while (Clock::now() < deadline && !interrupted) {
        // cameraStatusMode takes sdkMutex internally per poll, so the lock is
        // never held across the 100ms sleep and the attitude reporter is not
        // starved for the whole mode-switch transaction.
        if (cameraStatusMode(device) == expectedMode) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return false;
}

bool listDevices() {
    auto &devices = Devices::get();
    prepareDiscovery(devices);
    const auto deadline = Clock::now() + std::chrono::seconds(10);
    std::shared_ptr<Device> device;
    while (Clock::now() < deadline && !interrupted) {
        const std::string serial = discoveredSerial();
        if (!serial.empty()) {
            device = devices.getDevBySn(serial);
            if (device) break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (device) {
        std::cout << device->devName() << " product_type=" << device->productType() << "\n";
        return true;
    }
    const std::string failure = discoveryFailure();
    std::cerr << "No OBSBOT SDK device was discovered within 10 seconds"
              << (failure.empty() ? ".\n" : "; connect_failure=" + failure + ".\n");
    return false;
}

void emitNativeTrackingState(
    const std::string &state,
    const std::string &commandID,
    const std::string &outcome = "stopped"
) noexcept;

bool isTiny3Lite(const DiscoveryResult::Profile profile) noexcept {
    return profile == DiscoveryResult::Profile::tiny3Lite;
}

int setTiny3NativeTrackingDisabled(const std::shared_ptr<Device> &device) noexcept {
    try {
        return device->cameraSetAiModeU(Device::AiWorkModeNone, 0);
    } catch (...) {
        return RM_RET_ERR;
    }
}

int selectTiny3HumanTrackingTarget(
    const std::shared_ptr<Device> &device,
    std::optional<NativeTargetBox> targetBox
) noexcept {
    Device::DevTargetSelection target {};
    target.selection_type = static_cast<int16_t>(
        targetBox ? Device::DevTargetSelectionTypeBox : Device::DevTargetSelectionTypeCenter
    );
    target.class_type = static_cast<int16_t>(Device::DevTargetClassTypeHuman);
    target.zoom_type = static_cast<int16_t>(Device::DevTargetZoomTypeAdaptive);
    target.view_type = static_cast<int16_t>(Device::DevTargetViewTypeIgnored);
    if (targetBox) {
        target.location.roi.x_min = static_cast<float>(targetBox->x);
        target.location.roi.y_min = static_cast<float>(targetBox->y);
        target.location.roi.x_max = static_cast<float>(targetBox->x + targetBox->width);
        target.location.roi.y_max = static_cast<float>(targetBox->y + targetBox->height);
    }
    try { return device->aiSetSelectedTargetR(target); } catch (...) { return RM_RET_ERR; }
}

bool applyTiny3NativeHumanTrackingPolicy(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    const NativeHumanTrackingPolicy &policy,
    const std::string &commandID
) noexcept {
    const bool hasManualGain = policy.panGain.has_value() || policy.pitchGain.has_value();
    if (!validNativeHumanTrackingSpeedMode(policy.speedMode)
        || (hasManualGain && (!policy.panGain || !policy.pitchGain
            || !validNativeHumanTrackingGain(*policy.panGain)
            || !validNativeHumanTrackingGain(*policy.pitchGain)
            || policy.adaptivePanGain || policy.adaptivePitchGain))) {
        trace.event(
            "camera.ack",
            "fault",
            "native_tracking_policy_out_of_range",
            RM_RET_ERR,
            "speed_mode=" + std::to_string(policy.speedMode),
            commandID
        );
        return false;
    }

    int speedSetResult = RM_RET_ERR;
    int motionSetResult = RM_RET_ERR;
    int foreSetResult = RM_RET_ERR;
    int compositionSetResult = RM_RET_ERR;
    int panGainSetResult = RM_RET_ERR;
    int pitchGainSetResult = RM_RET_ERR;
    int speedGetResult = RM_RET_ERR;
    int motionGetResult = RM_RET_ERR;
    int foreGetResult = RM_RET_ERR;
    int compositionGetResult = RM_RET_ERR;
    int panGainGetResult = RM_RET_ERR;
    int pitchGainGetResult = RM_RET_ERR;
    int reportedSpeed = -1;
    bool reportedMotion = false;
    bool reportedFore = false;
    bool reportedComposition = false;
    bool reportedAdaptivePanGain = false;
    bool reportedAdaptivePitchGain = false;
    float baselinePanGain = 0;
    float baselinePitchGain = 0;
    float reportedPanGain = 0;
    float reportedPitchGain = 0;
    int manualGainBaselinePanResult = RM_RET_ERR;
    int manualGainBaselinePitchResult = RM_RET_ERR;
    int manualGainSetPanResult = RM_RET_ERR;
    int manualGainSetPitchResult = RM_RET_ERR;
    int manualGainVerifyPanResult = RM_RET_ERR;
    int manualGainVerifyPitchResult = RM_RET_ERR;
    int manualGainRollbackPanResult = RM_RET_ERR;
    int manualGainRollbackPitchResult = RM_RET_ERR;
    bool manualGainVerified = !hasManualGain;
    bool manualGainRestored = !hasManualGain;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try {
            speedSetResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeGimCtrlSpeedMode,
                policy.speedMode
            );
            motionSetResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeMotion,
                policy.motionTracking
            );
            foreSetResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeForeTrack,
                policy.foreTarget
            );
            compositionSetResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeComposition,
                policy.adaptiveComposition
            );
            panGainSetResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePanGainAdaptive,
                policy.adaptivePanGain
            );
            pitchGainSetResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypePitchGainAdaptive,
                policy.adaptivePitchGain
            );
            if (speedSetResult == RM_RET_OK && motionSetResult == RM_RET_OK
                && foreSetResult == RM_RET_OK && compositionSetResult == RM_RET_OK
                && panGainSetResult == RM_RET_OK && pitchGainSetResult == RM_RET_OK) {
                speedGetResult = device->aiGetControlParaR(
                    Device::DevControlTargetTypeHuman,
                    Device::DevControlParaTypeGimCtrlSpeedMode,
                    reportedSpeed
                );
                motionGetResult = device->aiGetControlParaR(
                    Device::DevControlTargetTypeHuman,
                    Device::DevControlParaTypeMotion,
                    reportedMotion
                );
                foreGetResult = device->aiGetControlParaR(
                    Device::DevControlTargetTypeHuman,
                    Device::DevControlParaTypeForeTrack,
                    reportedFore
                );
                compositionGetResult = device->aiGetControlParaR(
                    Device::DevControlTargetTypeHuman,
                    Device::DevControlParaTypeComposition,
                    reportedComposition
                );
                panGainGetResult = device->aiGetControlParaR(
                    Device::DevControlTargetTypeHuman,
                    Device::DevControlParaTypePanGainAdaptive,
                    reportedAdaptivePanGain
                );
                pitchGainGetResult = device->aiGetControlParaR(
                    Device::DevControlTargetTypeHuman,
                    Device::DevControlParaTypePitchGainAdaptive,
                    reportedAdaptivePitchGain
                );
                const bool basePolicyConfirmed = speedGetResult == RM_RET_OK
                    && motionGetResult == RM_RET_OK && foreGetResult == RM_RET_OK
                    && compositionGetResult == RM_RET_OK && panGainGetResult == RM_RET_OK
                    && pitchGainGetResult == RM_RET_OK
                    && reportedSpeed == policy.speedMode
                    && reportedMotion == policy.motionTracking
                    && reportedFore == policy.foreTarget
                    && reportedComposition == policy.adaptiveComposition
                    && reportedAdaptivePanGain == policy.adaptivePanGain
                    && reportedAdaptivePitchGain == policy.adaptivePitchGain;
                if (basePolicyConfirmed && hasManualGain) {
                    manualGainBaselinePanResult = device->aiGetControlParaR(
                        Device::DevControlTargetTypeHuman,
                        Device::DevControlParaTypePanGainValue,
                        baselinePanGain
                    );
                    manualGainBaselinePitchResult = device->aiGetControlParaR(
                        Device::DevControlTargetTypeHuman,
                        Device::DevControlParaTypePitchGainValue,
                        baselinePitchGain
                    );
                    if (manualGainBaselinePanResult == RM_RET_OK && manualGainBaselinePitchResult == RM_RET_OK) {
                        manualGainSetPanResult = device->aiSetControlParaR(
                            Device::DevControlTargetTypeHuman,
                            Device::DevControlParaTypePanGainValue,
                            *policy.panGain
                        );
                        manualGainSetPitchResult = device->aiSetControlParaR(
                            Device::DevControlTargetTypeHuman,
                            Device::DevControlParaTypePitchGainValue,
                            *policy.pitchGain
                        );
                        if (manualGainSetPanResult == RM_RET_OK && manualGainSetPitchResult == RM_RET_OK) {
                            manualGainVerifyPanResult = device->aiGetControlParaR(
                                Device::DevControlTargetTypeHuman,
                                Device::DevControlParaTypePanGainValue,
                                reportedPanGain
                            );
                            manualGainVerifyPitchResult = device->aiGetControlParaR(
                                Device::DevControlTargetTypeHuman,
                                Device::DevControlParaTypePitchGainValue,
                                reportedPitchGain
                            );
                            manualGainVerified = manualGainVerifyPanResult == RM_RET_OK
                                && manualGainVerifyPitchResult == RM_RET_OK
                                && std::abs(reportedPanGain - *policy.panGain) <= 0.0001f
                                && std::abs(reportedPitchGain - *policy.pitchGain) <= 0.0001f;
                        }
                    }
                    if (!manualGainVerified) {
                        if (manualGainBaselinePanResult == RM_RET_OK) {
                            manualGainRollbackPanResult = device->aiSetControlParaR(
                                Device::DevControlTargetTypeHuman,
                                Device::DevControlParaTypePanGainValue,
                                baselinePanGain
                            );
                        }
                        if (manualGainBaselinePitchResult == RM_RET_OK) {
                            manualGainRollbackPitchResult = device->aiSetControlParaR(
                                Device::DevControlTargetTypeHuman,
                                Device::DevControlParaTypePitchGainValue,
                                baselinePitchGain
                            );
                        }
                        manualGainRestored = manualGainRollbackPanResult == RM_RET_OK
                            && manualGainRollbackPitchResult == RM_RET_OK;
                    }
                }
            }
        } catch (...) {}
    }
    const bool confirmed = speedSetResult == RM_RET_OK && motionSetResult == RM_RET_OK
        && foreSetResult == RM_RET_OK && compositionSetResult == RM_RET_OK
        && panGainSetResult == RM_RET_OK && pitchGainSetResult == RM_RET_OK
        && speedGetResult == RM_RET_OK && motionGetResult == RM_RET_OK
        && foreGetResult == RM_RET_OK && compositionGetResult == RM_RET_OK
        && panGainGetResult == RM_RET_OK && pitchGainGetResult == RM_RET_OK
        && reportedSpeed == policy.speedMode
        && reportedMotion == policy.motionTracking
        && reportedFore == policy.foreTarget
        && reportedComposition == policy.adaptiveComposition
        && reportedAdaptivePanGain == policy.adaptivePanGain
        && reportedAdaptivePitchGain == policy.adaptivePitchGain
        && manualGainVerified;
    trace.event(
        "camera.ack",
        confirmed ? "firmware" : "fault",
        confirmed ? "native_tracking_policy_active" : "native_tracking_policy_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        "speed_mode=" + std::to_string(policy.speedMode)
            + "; motion=" + (policy.motionTracking ? "true" : "false")
            + "; fore_target=" + (policy.foreTarget ? "true" : "false")
            + "; adaptive_composition=" + (policy.adaptiveComposition ? "true" : "false")
            + "; adaptive_pan_gain=" + (policy.adaptivePanGain ? "true" : "false")
            + "; adaptive_pitch_gain=" + (policy.adaptivePitchGain ? "true" : "false")
            + "; requested_pan_gain=" + nativeHumanTrackingGainDescription(policy.panGain)
            + "; requested_pitch_gain=" + nativeHumanTrackingGainDescription(policy.pitchGain)
            + "; reported_pan_gain=" + (hasManualGain ? std::to_string(reportedPanGain) : "keep")
            + "; reported_pitch_gain=" + (hasManualGain ? std::to_string(reportedPitchGain) : "keep")
            + "; manual_gain_baseline_results=" + std::to_string(manualGainBaselinePanResult)
            + "," + std::to_string(manualGainBaselinePitchResult)
            + "; manual_gain_set_results=" + std::to_string(manualGainSetPanResult)
            + "," + std::to_string(manualGainSetPitchResult)
            + "; manual_gain_verify_results=" + std::to_string(manualGainVerifyPanResult)
            + "," + std::to_string(manualGainVerifyPitchResult)
            + "; manual_gain_rollback=" + (manualGainVerified ? "not_needed" : (manualGainRestored ? "restored" : "incomplete"))
            + "; set_results=" + std::to_string(speedSetResult)
            + "," + std::to_string(motionSetResult)
            + "," + std::to_string(foreSetResult)
            + "," + std::to_string(compositionSetResult)
            + "," + std::to_string(panGainSetResult)
            + "," + std::to_string(pitchGainSetResult)
            + "; get_results=" + std::to_string(speedGetResult)
            + "," + std::to_string(motionGetResult)
            + "," + std::to_string(foreGetResult)
            + "," + std::to_string(compositionGetResult)
            + "," + std::to_string(panGainGetResult)
            + "," + std::to_string(pitchGainGetResult)
            + "; reported_speed_mode=" + std::to_string(reportedSpeed)
            + "; reported_motion=" + (reportedMotion ? "true" : "false")
            + "; reported_fore_target=" + (reportedFore ? "true" : "false")
            + "; reported_adaptive_composition=" + (reportedComposition ? "true" : "false")
            + "; reported_adaptive_pan_gain=" + (reportedAdaptivePanGain ? "true" : "false")
            + "; reported_adaptive_pitch_gain=" + (reportedAdaptivePitchGain ? "true" : "false"),
        commandID
    );
    return confirmed;
}

bool requestManualStop(
    const std::shared_ptr<Device> &device,
    const DiscoveryResult::Profile profile,
    Trace &trace,
    const std::string &reason,
    const std::string &commandID,
    const std::string &controllingOwner = "native_ai"
) noexcept {
    trace.event("camera.command", controllingOwner, "manual_sent", 0, reason, commandID);
    int stopResult = RM_RET_ERR;
    int stopMotionResult = RM_RET_ERR;
    int zeroVelocityResult = RM_RET_ERR;
    int observedMode = -1;
    int attempts = 0;
    bool deactivated = false;
    std::string verification = "mode_none";
    if (isTiny3Lite(profile)) {
        // Tiny 3 has two distinct owners.  A native portrait/human owner has
        // to be observed in AiWorkModeNone before it is released.  A direct
        // velocity owner is already in manual mode: the authoritative safe
        // transition there is the accepted zero-velocity setpoint.  Treating
        // a transient AiWorkModeNone query failure as a fatal direct-motion
        // failure used to tear down the whole bridge after an otherwise
        // successful stop command.
        constexpr int maximumStopAttempts = 3;
        for (attempts = 1; attempts <= maximumStopAttempts; ++attempts) {
            {
                std::lock_guard<std::mutex> lock(sdkMutex);
                try { zeroVelocityResult = device->gimbalSpeedCtrlR(0, 0, 0); } catch (...) {}
                stopResult = setTiny3NativeTrackingDisabled(device);
            }
            observedMode = cameraStatusMode(device);

            if (controllingOwner == "external" && zeroVelocityResult == RM_RET_OK) {
                deactivated = true;
                stopMotionResult = RM_RET_OK;
                verification = observedMode == Device::AiWorkModeNone
                    ? "external_zero_velocity_mode_none"
                    : "external_zero_velocity";
                break;
            }

            // On Tiny 3 Lite, CameraStatus.tiny.ai_mode is not the portrait
            // tracker’s completion signal.  The device can continue reporting
            // its last tracking mode after it has accepted both the explicit
            // mode-none command and the zero-velocity setpoint.  Treating that
            // stale status as a failed release terminates the long-lived
            // bridge, restores the firmware's default indicator, and forces a
            // later process launch to physically home the gimbal.  The two
            // accepted control commands are the host-side release contract;
            // the visual runtime independently verifies any later acquisition.
            if (zeroVelocityResult == RM_RET_OK && stopResult == RM_RET_OK) {
                deactivated = true;
                stopMotionResult = RM_RET_OK;
                verification = observedMode == Device::AiWorkModeNone
                    ? "tiny3_stop_ack_mode_none"
                    : "tiny3_stop_ack_status_pending";
                break;
            }

            if (attempts < maximumStopAttempts) {
                std::this_thread::sleep_for(std::chrono::milliseconds(80));
            }
        }
    } else {
        {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try { stopResult = device->cameraSetAiModeU(Device::AiWorkModeNone); } catch (...) {}
            try { stopMotionResult = device->aiSetGimbalStop(); } catch (...) {}
        }
        try { deactivated = waitForMode(device, Device::AiWorkModeNone, 2'000); } catch (...) {}
    }
    try {
        trace.event(
            "camera.ack",
            deactivated ? "manual" : "fault",
            deactivated ? "manual_active" : "stop_unconfirmed",
            deactivated ? RM_RET_OK : RM_RET_ERR,
            "profile=" + std::string(capabilitiesFor(profile).identifier)
                + "; camera_status_ai_mode=" + std::to_string(isTiny3Lite(profile) ? observedMode : cameraStatusMode(device))
                + "; ai_mode_none_result=" + std::to_string(stopResult)
                + "; gimbal_stop_result=" + std::to_string(stopMotionResult)
                + "; zero_velocity_result=" + std::to_string(zeroVelocityResult)
                + "; stop_attempts=" + std::to_string(attempts)
                + "; verification=" + verification
                + "; profile_native_stop=" + (isTiny3Lite(profile) ? "tiny3_human_portrait_off" : "human_track_off"),
            commandID
        );
    } catch (...) {}
    // The Swift bridge keeps a native-tracking lease alive with heartbeats.
    // Whenever the device is actually returned to manual mode — whether by the
    // owner, the watchdog, an external yield, a recenter, or shutdown — it must
    // be told so, or it will keep sending heartbeats for a lease the native
    // side no longer holds (spamming heartbeat_rejected faults).
    if (deactivated) {
        emitNativeTrackingState("inactive", commandID);
    }
    return deactivated;
}

bool setDoaFindBack(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    bool enabled,
    const std::string &commandID = "doa-find-back-1"
) noexcept {
    using SetDoaFindBack = int (*)(Device *, uint8_t);
    const auto set = reinterpret_cast<SetDoaFindBack>(
        dlsym(RTLD_DEFAULT, "_ZN6Device20cameraSetDoaFindBackEh")
    );
    int result = RM_RET_ERR;
    Device::CameraStatus status{};
    int statusResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        if (set) {
            try { result = set(device.get(), enabled ? 1 : 0); } catch (...) {}
        }
        try { statusResult = device->cameraGetCameraStatusU(status); } catch (...) {}
    }
    const bool confirmed = result == RM_RET_OK
        && statusResult == RM_RET_OK
        && (status.tiny.doa_set.doa_find_back != 0) == enabled;
    trace.event(
        "audio.doa",
        confirmed ? "firmware" : "fault",
        confirmed ? "sound_source_tracking_configured" : "sound_source_tracking_unconfirmed",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        "enabled=" + std::string(enabled ? "true" : "false")
            + "; reported_enabled=" + (statusResult == RM_RET_OK
                ? std::string(status.tiny.doa_set.doa_find_back ? "true" : "false")
                : std::string("unavailable")),
        commandID
    );
    if (confirmed) {
        try {
            std::lock_guard<std::mutex> lock(stderrMutex);
            std::cerr << "SOMA_DOA_FOLLOW enabled=" << (enabled ? "true" : "false") << "\n" << std::flush;
        } catch (...) {}
    }
    return confirmed;
}

struct GimbalAttitude {
    double pitch;
    double pan;
    uint64_t monotonicNS;
    const char *source;
};

struct GimbalHealth {
    int result;
    uint8_t systemStatus;
    uint8_t warningFlags;
    uint8_t errorFlags;
    uint8_t panRangeMode;
    uint8_t locked;
    int16_t pitchVelocity;
    int16_t panVelocity;
};

GimbalHealth readGimbalHealth(const std::shared_ptr<Device> &device) noexcept {
    using GetGimbalAllInfo = int32_t (*)(Device *, Device::AiGimbalStatus &);
    static const auto getGimbalAllInfo = reinterpret_cast<GetGimbalAllInfo>(
        dlsym(RTLD_DEFAULT, "_ZN6Device16gimbalGetAllInfoERNS_14AiGimbalStatusE")
    );
    Device::AiGimbalStatus status {};
    int result = RM_RET_ERR;
    if (getGimbalAllInfo) {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { result = getGimbalAllInfo(device.get(), status); } catch (...) {}
    }
    return GimbalHealth {
        result,
        status.sys_status,
        status.warning_flag,
        status.error_flag,
        status.pan_range_mode,
        status.lock,
        status.pitch_v,
        status.pan_v
    };
}

bool hasSameGimbalHealth(const GimbalHealth &lhs, const GimbalHealth &rhs) noexcept {
    return lhs.result == rhs.result
        && lhs.systemStatus == rhs.systemStatus
        && lhs.warningFlags == rhs.warningFlags
        && lhs.errorFlags == rhs.errorFlags
        && lhs.panRangeMode == rhs.panRangeMode
        && lhs.locked == rhs.locked;
}

std::optional<GimbalAttitude> readGimbalAttitude(const std::shared_ptr<Device> &device) noexcept {
    std::lock_guard<std::mutex> lock(sdkMutex);
    float xyz[3] = {};
    int attitudeResult = RM_RET_ERR;
    try { attitudeResult = device->gimbalGetAttitudeInfoR(xyz); } catch (...) {}
    const bool hasAttitude = attitudeResult == RM_RET_OK
        && std::isfinite(xyz[1])
        && std::isfinite(xyz[2]);

    Device::AiGimbalStateInfo aiState {};
    int aiStateResult = RM_RET_ERR;
    if (!hasAttitude) {
        try { aiStateResult = device->aiGetGimbalStateR(&aiState); } catch (...) {}
    }
    const bool hasAIState = aiStateResult == RM_RET_OK
        && std::isfinite(aiState.pitch_euler)
        && std::isfinite(aiState.yaw_euler);
    if (!hasAttitude && !hasAIState) return std::nullopt;
    mach_timebase_info_data_t timebase {};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return std::nullopt;
    const auto nanoseconds = static_cast<uint64_t>(
        (static_cast<__uint128_t>(mach_absolute_time()) * timebase.numer) / timebase.denom
    );
    return hasAttitude
        ? GimbalAttitude {xyz[1], xyz[2], nanoseconds, "attitude"}
        : GimbalAttitude {aiState.pitch_euler, aiState.yaw_euler, nanoseconds, "ai_state"};
}

void emitGimbalAttitude(const GimbalAttitude &attitude) noexcept {
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_GIMBAL_ATTITUDE pitch=" << attitude.pitch
                  << " pan=" << attitude.pan
                  << " source=" << attitude.source
                  << " monotonic_ns=" << attitude.monotonicNS << "\n" << std::flush;
    } catch (...) {}
}

void emitGimbalHealth(const GimbalHealth &health) noexcept {
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_GIMBAL_HEALTH result=" << health.result
                  << " system_status=" << static_cast<unsigned int>(health.systemStatus)
                  << " warning_flags=" << static_cast<unsigned int>(health.warningFlags)
                  << " error_flags=" << static_cast<unsigned int>(health.errorFlags)
                  << " pan_range_mode=" << static_cast<unsigned int>(health.panRangeMode)
                  << " locked=" << static_cast<unsigned int>(health.locked)
                  << " pitch_velocity=" << health.pitchVelocity
                  << " pan_velocity=" << health.panVelocity << "\n" << std::flush;
    } catch (...) {}
}

void emitGimbalHome(const GimbalAttitude &attitude) noexcept {
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_GIMBAL_HOME pitch=" << attitude.pitch
                  << " pan=" << attitude.pan
                  << " source=" << attitude.source
                  << " monotonic_ns=" << attitude.monotonicNS << "\n" << std::flush;
    } catch (...) {}
}

std::optional<GimbalAttitude> waitForSettledCenter(const std::shared_ptr<Device> &device) noexcept {
    constexpr auto deadline = std::chrono::seconds(10);
    constexpr auto sampleInterval = std::chrono::milliseconds(160);
    constexpr auto requiredStableWindow = std::chrono::milliseconds(1200);
    constexpr double maximumStableWindowDeltaDegrees = 0.12;
    const auto end = Clock::now() + deadline;
    std::optional<GimbalAttitude> stableAnchor;
    std::optional<Clock::time_point> stableSince;
    while (Clock::now() < end && !interrupted) {
        const auto current = readGimbalAttitude(device);
        if (current) {
            const auto now = Clock::now();
            if (!stableAnchor
                || std::abs(current->pitch - stableAnchor->pitch) > maximumStableWindowDeltaDegrees
                || std::abs(current->pan - stableAnchor->pan) > maximumStableWindowDeltaDegrees) {
                stableAnchor = current;
                stableSince = now;
            } else if (stableSince && now - *stableSince >= requiredStableWindow) {
                return current;
            }
        }
        std::this_thread::sleep_for(sampleInterval);
    }
    return std::nullopt;
}

void emitHorizontalFieldOfView(int degrees) noexcept {
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_GIMBAL_FOV degrees=" << degrees << "\n" << std::flush;
    } catch (...) {}
}

void emitDeviceCapabilities(
    const std::shared_ptr<Device> &device,
    const DeviceCapabilities &capabilities
) noexcept {
    try {
        Device::CameraStatus status{};
        int statusResult = RM_RET_ERR;
        {
            std::lock_guard<std::mutex> sdkLock(sdkMutex);
            statusResult = device->cameraGetCameraStatusU(status);
        }
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_OBSBOT_CAPABILITY profile=" << capabilities.identifier
                  << " motor_calibrated=" << (capabilities.calibratedMotorControl ? "true" : "false")
                  << " bounded_calibration_pulses=" << (capabilities.boundedCalibrationPulses ? "true" : "false")
                  << " indicator_palette=" << (capabilities.firmwareIndicatorPalette ? "true" : "false")
                  << " indicator_direct_rgb=" << (capabilities.directIndicatorRGB ? "true" : "false")
                  << " indicator_basic=" << (capabilities.indicatorEnableAndBrightness ? "true" : "false")
                  << " selectable_audio_modes=" << (capabilities.selectableAudioModes ? "true" : "false")
                  << " sound_localization=" << (capabilities.soundLocalization ? "true" : "false")
                  << " requires_measured_attitude_frame=" << (capabilities.requiresMeasuredAttitudeFrame ? "true" : "false")
                  << " maximum_pan_degrees_per_second=" << capabilities.maximumPanDegreesPerSecond
                  << " maximum_pitch_degrees_per_second=" << capabilities.maximumPitchDegreesPerSecond
                  << " audio_mode=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.audio_mode.mode) : "unknown")
                  << " doa_find_back=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.doa_set.doa_find_back) : "unknown")
                  << " doa_range=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.doa_set.doa_range) : "unknown")
                  << " doa_beamforming_disabled=" << (statusResult == RM_RET_OK ? std::to_string(status.tiny.doa_set.disable_bf) : "unknown")
                  << " firmware=" << device->devVersion()
                  << " serial=" << device->devSn() << "\n" << std::flush;
    } catch (...) {}
}

void emitNativeTrackingState(
    const std::string &state,
    const std::string &commandID,
    const std::string &outcome
) noexcept {
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_NATIVE_TRACKING state=" << state
                  << " command_id=" << commandID
                  << " outcome=" << outcome << "\n" << std::flush;
    } catch (...) {}
}

bool requestExternalVelocity(
    const std::shared_ptr<Device> &device,
    const DiscoveryResult::Profile profile,
    Trace &trace,
    const DeviceCapabilities &capabilities,
    const std::string &commandID,
    double pitch,
    double pan,
    bool alreadyExternal
) noexcept {
    if (!std::isfinite(pitch) || !std::isfinite(pan)
        || std::abs(pitch) > capabilities.maximumPitchDegreesPerSecond
        || std::abs(pan) > capabilities.maximumPanDegreesPerSecond) {
        trace.event("camera.ack", "fault", "external_velocity_rejected", RM_RET_ERR, "external_velocity_out_of_range", commandID);
        return false;
    }
    trace.event(
        "camera.command",
        "external",
        "external_velocity_sent",
        0,
        "requested_pitch_degrees_per_second=" + std::to_string(pitch)
            + "; requested_pan_degrees_per_second=" + std::to_string(pan)
            + "; pitch_degrees_per_second=" + std::to_string(pitch)
            + "; pan_degrees_per_second=" + std::to_string(pan),
        commandID
    );
    if (!alreadyExternal) {
        if (!requestManualStop(device, profile, trace, "external_control_acquire", "acquire-" + commandID, "external")) {
            trace.event("camera.ack", "fault", "external_acquire_unconfirmed", RM_RET_ERR, "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device)), commandID);
            return false;
        }
    }
    int speedResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try {
            speedResult = isTiny3Lite(profile)
                ? device->gimbalSpeedCtrlR(pitch, pan)
                : device->aiSetGimbalSpeedCtrlR(pitch, pan);
        } catch (...) {}
    }
    trace.event(
        "camera.ack",
        speedResult == RM_RET_OK ? "external" : "fault",
        speedResult == RM_RET_OK ? "external_active" : "external_speed_rejected",
        speedResult,
        "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device)) + "; attitude=reported_by_poller",
        commandID
    );
    if (speedResult != RM_RET_OK) requestManualStop(device, profile, trace, "external_speed_rejected", "cleanup-" + commandID, "external");
    return speedResult == RM_RET_OK;
}

bool requestExternalPosition(
    const std::shared_ptr<Device> &device,
    const DiscoveryResult::Profile profile,
    Trace &trace,
    const std::string &commandID,
    double pitch,
    double pan,
    bool alreadyExternal
) noexcept {
    if (!std::isfinite(pitch) || !std::isfinite(pan) || std::abs(pitch) > 90 || std::abs(pan) > 120) {
        trace.event("camera.ack", "fault", "external_position_rejected", RM_RET_ERR, "external_position_out_of_range", commandID);
        return false;
    }
    trace.event(
        "camera.command",
        "external",
        "external_position_sent",
        0,
        "target_pitch_degrees=" + std::to_string(pitch)
            + "; target_pan_degrees=" + std::to_string(pan),
        commandID
    );
    if (!alreadyExternal) {
        if (!requestManualStop(device, profile, trace, "external_control_acquire", "acquire-" + commandID, "external")) {
            trace.event("camera.ack", "fault", "external_acquire_unconfirmed", RM_RET_ERR, "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device)), commandID);
            return false;
        }
    }
    int positionResult = RM_RET_ERR;
    // gimbalGetAttitudeInfoR and gimbalSetSpeedPositionR share the same
    // stabilised pose coordinates. aiSetGimbalMotorAngleR instead accepts
    // motor-internal angles, which are not comparable to the reported pose.
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { positionResult = device->gimbalSetSpeedPositionR(0, static_cast<float>(pitch), static_cast<float>(pan), 0, 90, 90); } catch (...) {}
    }
    trace.event(
        "camera.ack",
        positionResult == RM_RET_OK ? "external" : "fault",
        positionResult == RM_RET_OK ? "external_position_active" : "external_position_rejected",
        positionResult,
        "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device)) + "; attitude=reported_by_poller",
        commandID
    );
    if (positionResult != RM_RET_OK) requestManualStop(device, profile, trace, "external_position_rejected", "cleanup-" + commandID, "external");
    return positionResult == RM_RET_OK;
}

bool requestCenter(
    const std::shared_ptr<Device> &device,
    const DiscoveryResult::Profile profile,
    Trace &trace,
    const std::string &commandID
) noexcept {
    trace.event("camera.command", "manual", "center_sent", 0, "pitch_degrees=0; yaw_degrees=0", commandID);
    int disableAIResult = RM_RET_ERR;
    int positionResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        disableAIResult = isTiny3Lite(profile)
            ? setTiny3NativeTrackingDisabled(device)
            : device->cameraSetAiModeU(Device::AiWorkModeNone);
        try {
            positionResult = isTiny3Lite(profile)
                ? device->gimbalRstPosR()
                : device->gimbalSetSpeedPositionR(0, 0, 0, 0, 60, 90);
        } catch (...) {}
    }
    trace.event(
        "camera.ack",
        disableAIResult == RM_RET_OK && positionResult == RM_RET_OK ? "manual" : "fault",
        disableAIResult == RM_RET_OK && positionResult == RM_RET_OK ? "center_accepted" : "center_rejected",
        disableAIResult == RM_RET_OK && positionResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
        "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device)),
        commandID
    );
    return disableAIResult == RM_RET_OK && positionResult == RM_RET_OK;
}

bool setDeviceRunStatus(
    const std::shared_ptr<Device> &device,
    Device::DevStatus status,
    Trace &trace,
    const std::string &commandID
) noexcept {
    int result = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { result = device->cameraSetDevRunStatusR(status); } catch (...) {}
    }
    const bool succeeded = result == RM_RET_OK;
    trace.event(
        "camera.ack",
        succeeded ? "manual" : "fault",
        status == Device::DevStatusSleep
            ? (succeeded ? "sleep_active" : "sleep_rejected")
            : (succeeded ? "wake_active" : "wake_rejected"),
        result,
        std::string("requested_status=") + (status == Device::DevStatusSleep ? "sleep" : "run"),
        commandID
    );
    return succeeded;
}

bool parkAtRestPoseAndSleep(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    const std::string &commandID
) noexcept {
    constexpr double arrivalToleranceDegrees = 1.5;
    constexpr auto arrivalDeadline = std::chrono::seconds(15);

    trace.event(
        "camera.command",
        "manual",
        "rest_pose_sent",
        0,
        "target_pitch_degrees=0; target_pan_degrees=0; control=firmware_gimbal_reset",
        commandID
    );
    int resetResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { resetResult = device->gimbalRstPosR(); } catch (...) {}
    }
    if (resetResult != RM_RET_OK) {
        trace.event(
            "camera.ack",
            "fault",
            "rest_pose_rejected",
            resetResult,
            "control=firmware_gimbal_reset; sleep_withheld=true",
            commandID
        );
        return false;
    }
    const auto deadline = Clock::now() + arrivalDeadline;
    bool arrived = false;
    std::optional<GimbalAttitude> initialAttitude;
    std::optional<GimbalAttitude> lastAttitude;
    while (Clock::now() < deadline && !interrupted) {
        const auto attitude = readGimbalAttitude(device);
        if (!attitude) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }
        if (!initialAttitude) initialAttitude = attitude;
        lastAttitude = attitude;
        if (std::abs(attitude->pitch) <= arrivalToleranceDegrees
            && std::abs(attitude->pan) <= arrivalToleranceDegrees) {
            arrived = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }
    trace.event(
        "camera.ack",
        arrived ? "manual" : "fault",
        arrived ? "rest_pose_arrived" : "rest_pose_timeout",
        arrived ? RM_RET_OK : RM_RET_ERR,
        std::string("target_pitch_degrees=0; target_pan_degrees=0")
            + "; initial_pitch_degrees=" + (initialAttitude ? std::to_string(initialAttitude->pitch) : std::string("unavailable"))
            + "; initial_pan_degrees=" + (initialAttitude ? std::to_string(initialAttitude->pan) : std::string("unavailable"))
            + "; final_pitch_degrees=" + (lastAttitude ? std::to_string(lastAttitude->pitch) : std::string("unavailable"))
            + "; final_pan_degrees=" + (lastAttitude ? std::to_string(lastAttitude->pan) : std::string("unavailable"))
            + "; reset_result=" + std::to_string(resetResult)
            + "; sleep_withheld=" + std::string(arrived ? "false" : "true"),
        commandID
    );
    return arrived
        && setDeviceRunStatus(device, Device::DevStatusSleep, trace, commandID + "-sleep");
}

bool requestNativeHumanTracking(
    const std::shared_ptr<Device> &device,
    const DiscoveryResult::Profile profile,
    Trace &trace,
    const std::string &commandID,
    const std::string &cleanupCommandID,
    std::optional<NativeTargetBox> targetBox = std::nullopt,
    const NativeHumanTrackingPolicy &policy = {},
    const std::function<void(const std::string &)> &reassertIndicator = {}
) noexcept {
    if (isTiny3Lite(profile)) {
        trace.event(
            "camera.command",
            "native_ai",
            "tiny3_tracking_enable_sent",
            0,
            "profile=tiny_3_lite; transition=human_then_portrait_track",
            commandID
        );
        int humanModeResult = RM_RET_ERR;
        int portraitModeResult = RM_RET_ERR;
        int targetResult = RM_RET_ERR;
        {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try {
                humanModeResult = device->cameraSetAiModeU(
                    Device::AiWorkModeHuman,
                    Device::AiSubModeNormal
                );
            } catch (...) {}
        }
        // Tiny 3 exposes portrait tracking through the v3 target-selection
        // surface, but camera status retains the legacy Tiny2 AI-mode field.
        // Let the human mode transition settle before entering portrait mode;
        // a direct PortraitTrack request is accepted by the SDK yet ignored by
        // the firmware on this device profile.
        if (humanModeResult == RM_RET_OK) {
            // Entering a native AI mode temporarily revives the camera's own
            // status animation. Reassert the semantic presentation before
            // waiting for PortraitTrack so a status flash cannot leak into
            // an eye-contact transition.
            if (reassertIndicator) reassertIndicator("human_mode");
            std::this_thread::sleep_for(std::chrono::milliseconds(150));
            {
                std::lock_guard<std::mutex> lock(sdkMutex);
                try {
                    portraitModeResult = device->cameraSetAiModeU(
                        Device::AiWorkModePortraitTrack,
                        0
                    );
                } catch (...) {}
            }
            if (portraitModeResult == RM_RET_OK && reassertIndicator) {
                reassertIndicator("portrait_mode");
            }
        }
        const bool transitionAccepted = humanModeResult == RM_RET_OK
            && portraitModeResult == RM_RET_OK;
        if (transitionAccepted) {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try {
                targetResult = selectTiny3HumanTrackingTarget(device, targetBox);
            } catch (...) { targetResult = RM_RET_ERR; }
        }
        const bool policyActive = transitionAccepted && targetResult == RM_RET_OK
            && applyTiny3NativeHumanTrackingPolicy(device, trace, policy, commandID);
        const bool activated = transitionAccepted && targetResult == RM_RET_OK && policyActive;
        trace.event(
            "camera.ack",
            activated ? "native_ai" : "fault",
            activated ? "tiny3_tracking_verification_pending" : "tiny3_tracking_rejected",
            activated ? RM_RET_OK : RM_RET_ERR,
            "human_mode_result=" + std::to_string(humanModeResult)
                + "; portrait_track_result=" + std::to_string(portraitModeResult)
                + "; transition_accepted=" + (transitionAccepted ? "true" : "false")
                + "; target_selection_result=" + std::to_string(targetResult)
                + "; target_selection=" + (targetBox ? "face_box_adaptive" : "center_adaptive")
                + "; policy_active=" + (policyActive ? "true" : "false")
                + "; speed_mode=" + std::to_string(policy.speedMode)
                + "; motion=" + (policy.motionTracking ? "true" : "false")
                + "; fore_target=" + (policy.foreTarget ? "true" : "false")
                + "; adaptive_composition=" + (policy.adaptiveComposition ? "true" : "false")
                + "; adaptive_pan_gain=" + (policy.adaptivePanGain ? "true" : "false")
                + "; adaptive_pitch_gain=" + (policy.adaptivePitchGain ? "true" : "false")
                + "; legacy_camera_status_ai_mode=" + std::to_string(cameraStatusMode(device))
                + "; status_contract=legacy_tiny2_field_not_native_proof"
                + "; functional_verification=runtime_vision_attitude",
            commandID
        );
        if (!activated) {
            requestManualStop(device, profile, trace, "tiny3_start_rejected", cleanupCommandID);
            emitNativeTrackingState("inactive", commandID, "start_rejected");
        } else {
            if (reassertIndicator) reassertIndicator("tracking_active");
            emitNativeTrackingState("active", commandID, "active");
        }
        return activated;
    }

    trace.event(
        "camera.command",
        "native_ai",
        "human_normal_sent",
        0,
        "Tiny 2 Lite; vertical_tracking_mode=motion",
        commandID
    );
    int startResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { startResult = device->cameraSetAiModeU(Device::AiWorkModeHuman, Device::AiSubModeNormal); } catch (...) {}
    }
    if (startResult != RM_RET_OK) {
        trace.event("camera.ack", "fault", "start_rejected", startResult, "SDK rejected native human tracking", commandID);
        requestManualStop(device, profile, trace, "start_rejected", cleanupCommandID);
        emitNativeTrackingState("inactive", commandID, "start_rejected");
        return false;
    }
    int trackingModeResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { trackingModeResult = device->aiSetTrackingModeR(Device::AiVTrackMotion); } catch (...) {}
    }
    // Mode activation is asynchronous on Tiny 2 Lite. A two-second timeout
    // repeatedly tore a valid handoff down while the camera was still
    // transitioning, which made L0 alternate between native tracking and
    // coverage. The Swift owner lease already bounds a pending start at 8 s;
    // leave the device one continuous 7 s confirmation window inside it.
    bool activated = false;
    try { activated = waitForMode(device, Device::AiWorkModeHuman, 7'000); } catch (...) {}
    // Apply tracking behavior after the mode is confirmed active. The camera
    // can reset control parameters when it transitions into AI mode, so
    // setting them before waitForMode left the camera at its sluggish
    // defaults (the camera kept dropping the subject into explore).
    //  - GimCtrlSpeedMode: preset speed for how briskly the gimbal chases.
    //  - ForeTrack: when the subject is briefly lost, keep tracking forward
    //    instead of dropping back into autonomous explore, which read as the
    //    robot "ignoring" the person.
    int speedResult = RM_RET_ERR;
    int motionResult = RM_RET_ERR;
    int foreTrackResult = RM_RET_ERR;
    if (activated) {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try {
            speedResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeGimCtrlSpeedMode,
                Device::DevGimCtrlSpeedModeCrazy
            );
            motionResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeMotion,
                true
            );
            foreTrackResult = device->aiSetControlParaR(
                Device::DevControlTargetTypeHuman,
                Device::DevControlParaTypeForeTrack,
                true
            );
        } catch (...) {}
    }
    const int confirmedTrackingMode = verticalTrackingMode(device).value_or(-1);
    trace.event(
        "camera.ack",
        activated ? "native_ai" : "fault",
        activated ? "human_normal_active" : "start_unconfirmed",
        activated ? RM_RET_OK : RM_RET_ERR,
        "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device))
            + "; tracking_mode_set_result=" + std::to_string(trackingModeResult)
            + "; gimbal_speed_mode_set_result=" + std::to_string(speedResult)
            + "; motion_tracking_set_result=" + std::to_string(motionResult)
            + "; fore_track_set_result=" + std::to_string(foreTrackResult)
            + "; camera_status_vertical_tracking_mode=" + std::to_string(confirmedTrackingMode),
        commandID
    );
    if (!activated) {
        requestManualStop(device, profile, trace, "start_acknowledgement_timed_out", cleanupCommandID);
        emitNativeTrackingState("inactive", commandID, "start_rejected");
    } else {
        emitNativeTrackingState("active", commandID, "active");
    }
    return activated;
}

enum class BridgeCommandType {
    nativeStart,
    heartbeat,
    externalVelocity,
    externalPosition,
    externalPulse,
    externalVelocityOutOfRange,
    externalPositionOutOfRange,
    externalStop,
    cameraZoom,
    audioMode,
    audioInputGain,
    cameraWhiteBalance,
    cameraExposureLock,
    cameraFocus,
    cameraAbsoluteExposure,
    cameraFacePriority,
    cameraAntiFlicker,
    cameraImageTuning,
    nativeHumanTrackingPolicy,
    cameraFieldOfView,
    doaFollow,
    manualStop,
    recenter,
    indicatorSet,
    indicatorClear,
    indicatorBrightness,
    indicatorEnabled,
    indicatorEnforce,
    indicatorReconcile,
    indicatorRGBEnforce,
    indicatorRGBReconcile,
    indicatorRGBClear,
    shutdown,
    invalid
};

enum class IndicatorPattern {
    steady,
    firmwareAnimation,
    beacon,
    doubleBlink,
    longPulse,
    heartbeat,
    blink,
};

struct IndicatorPatternPhase {
    bool illuminated;
    int durationMilliseconds;
};

std::optional<IndicatorPattern> parseIndicatorPattern(const std::string &value) {
    if (value == "steady") return IndicatorPattern::steady;
    if (value == "firmware_animation") return IndicatorPattern::firmwareAnimation;
    if (value == "beacon") return IndicatorPattern::beacon;
    if (value == "doubleBlink") return IndicatorPattern::doubleBlink;
    if (value == "longPulse") return IndicatorPattern::longPulse;
    if (value == "heartbeat") return IndicatorPattern::heartbeat;
    if (value == "blink") return IndicatorPattern::blink;
    return std::nullopt;
}

const char *indicatorPatternName(IndicatorPattern pattern) {
    switch (pattern) {
    case IndicatorPattern::steady: return "steady";
    case IndicatorPattern::firmwareAnimation: return "firmware_animation";
    case IndicatorPattern::beacon: return "beacon";
    case IndicatorPattern::doubleBlink: return "doubleBlink";
    case IndicatorPattern::longPulse: return "longPulse";
    case IndicatorPattern::heartbeat: return "heartbeat";
    case IndicatorPattern::blink: return "blink";
    }
    return "steady";
}

const std::vector<IndicatorPatternPhase> &indicatorPatternPhases(IndicatorPattern pattern) {
    static const std::vector<IndicatorPatternPhase> steady = {{true, 0}};
    static const std::vector<IndicatorPatternPhase> contactPulse = {
        {true, 150}, {false, 130}, {true, 150}, {false, 1'270},
    };
    static const std::vector<IndicatorPatternPhase> beacon = {{true, 180}, {false, 1320}};
    static const std::vector<IndicatorPatternPhase> doubleBlink = {{true, 140}, {false, 110}, {true, 140}, {false, 610}};
    static const std::vector<IndicatorPatternPhase> longPulse = {{true, 800}, {false, 200}};
    static const std::vector<IndicatorPatternPhase> heartbeat = {{true, 300}, {false, 700}};
    static const std::vector<IndicatorPatternPhase> blink = {{true, 400}, {false, 400}};
    switch (pattern) {
    case IndicatorPattern::steady: return steady;
    case IndicatorPattern::firmwareAnimation: return contactPulse;
    case IndicatorPattern::beacon: return beacon;
    case IndicatorPattern::doubleBlink: return doubleBlink;
    case IndicatorPattern::longPulse: return longPulse;
    case IndicatorPattern::heartbeat: return heartbeat;
    case IndicatorPattern::blink: return blink;
    }
    return steady;
}

struct BridgeCommand {
    BridgeCommandType type = BridgeCommandType::invalid;
    std::string commandID;
    double pitch = 0;
    double pan = 0;
    int durationMilliseconds = 0;
    int value = 0;
    int temperatureKelvin = 0;
    bool whiteBalanceAutomatic = true;
    float zoom = 1.0f;
    IndicatorPattern indicatorPattern = IndicatorPattern::steady;
    std::optional<Tiny3FixedRGB> indicatorRGB;
    std::optional<NativeTargetBox> nativeTarget;
    bool exposureLocked = false;
    bool focusAutomatic = true;
    int focusPosition = 0;
    bool absoluteExposureAutomatic = true;
    int absoluteExposureShutterCode = 0;
    bool facePriorityEnabled = false;
    int antiFlickerMode = Device::PowerLineFreqAuto;
    CameraImageTuning imageTuning;
    NativeHumanTrackingPolicy nativeTrackingPolicy;
};

bool validCommandID(const std::string &value) {
    return !value.empty()
        && value.size() <= 64
        && std::all_of(value.begin(), value.end(), [](unsigned char character) {
            return std::isalnum(character) || character == '-' || character == '_';
        });
}

bool validFirmwareIndicatorStateID(DiscoveryResult::Profile profile, int stateID) {
    switch (profile) {
    case DiscoveryResult::Profile::tiny2Lite:
        return stateID == 16 || stateID == 17 || stateID == 18
            || stateID == 54 || stateID == 57;
    case DiscoveryResult::Profile::tiny3Lite:
        return stateID == 16 || stateID == 17 || stateID == 54 || stateID == 57;
    }
    return false;
}

bool isSupportedTiny3DirectRGB(
    DiscoveryResult::Profile profile,
    const Tiny3FixedRGB &color
) {
    if (profile != DiscoveryResult::Profile::tiny3Lite) return false;
    return color == kTiny3SemanticGreen
        || color == kTiny3SemanticYellow
        || color == kTiny3SemanticBlue;
}

bool parseImageTuningValue(const std::string &token, std::optional<int32_t> &value) {
    if (token == "keep") {
        value.reset();
        return true;
    }
    try {
        size_t consumed = 0;
        const int32_t parsed = std::stoi(token, &consumed);
        if (consumed != token.size() || parsed < 0 || parsed > 100) return false;
        value = parsed;
        return true;
    } catch (...) {
        return false;
    }
}

bool parseNativeHumanTrackingGain(const std::string &token, std::optional<float> &value) {
    if (token == "keep") {
        value.reset();
        return true;
    }
    try {
        size_t parsedLength = 0;
        const float gain = std::stof(token, &parsedLength);
        if (parsedLength != token.size() || !validNativeHumanTrackingGain(gain)) return false;
        value = gain;
        return true;
    } catch (...) {
        return false;
    }
}

BridgeCommand parseBridgeCommand(
    const std::string &line,
    DiscoveryResult::Profile profile,
    const DeviceCapabilities &capabilities
) {
    std::istringstream input(line);
    std::string verb;
    std::string commandID;
    std::string extra;
    if (!(input >> verb >> commandID) || !validCommandID(commandID)) return {};
    if (verb == "native_start") {
        std::string xToken;
        if (!(input >> xToken)) return {BridgeCommandType::nativeStart, commandID};
        NativeTargetBox target;
        try {
            size_t consumed = 0;
            target.x = std::stod(xToken, &consumed);
            if (consumed != xToken.size()) return {};
        } catch (...) {
            return {};
        }
        if (!(input >> target.y >> target.width >> target.height) || (input >> extra)
            || !std::isfinite(target.x) || !std::isfinite(target.y)
            || !std::isfinite(target.width) || !std::isfinite(target.height)
            || target.x < 0 || target.y < 0 || target.width <= 0 || target.height <= 0
            || target.x + target.width > 1 || target.y + target.height > 1) {
            return {};
        }
        BridgeCommand command;
        command.type = BridgeCommandType::nativeStart;
        command.commandID = commandID;
        command.nativeTarget = target;
        return command;
    }
    if (verb == "external_velocity") {
        double pitch = 0;
        double pan = 0;
        if (!(input >> pitch >> pan) || (input >> extra) || !std::isfinite(pitch) || !std::isfinite(pan)) return {};
        if (std::abs(pitch) > 90 || std::abs(pan) > 180) return {BridgeCommandType::externalVelocityOutOfRange, commandID, pitch, pan};
        return {BridgeCommandType::externalVelocity, commandID, pitch, pan};
    }
    if (verb == "external_position") {
        double pitch = 0;
        double pan = 0;
        if (!(input >> pitch >> pan) || (input >> extra) || !std::isfinite(pitch) || !std::isfinite(pan)) return {};
        if (std::abs(pitch) > 90 || std::abs(pan) > 120) return {BridgeCommandType::externalPositionOutOfRange, commandID, pitch, pan};
        return {BridgeCommandType::externalPosition, commandID, pitch, pan};
    }
    if (verb == "external_pulse") {
        double pitch = 0;
        double pan = 0;
        int durationMilliseconds = 0;
        if (!(input >> pitch >> pan >> durationMilliseconds) || (input >> extra)
            || !std::isfinite(pitch) || !std::isfinite(pan)
            || std::abs(pitch) > 90 || std::abs(pan) > 180
            || durationMilliseconds < 1 || durationMilliseconds > 180) return {};
        return {BridgeCommandType::externalPulse, commandID, pitch, pan, durationMilliseconds};
    }
    if (verb == "camera_zoom") {
        float zoom = 0;
        if (!(input >> zoom) || (input >> extra) || !std::isfinite(zoom)
            || zoom < 1.0f || zoom > 2.0f) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::cameraZoom;
        command.commandID = commandID;
        command.zoom = zoom;
        return command;
    }
    if (verb == "audio_mode") {
        int mode = -1;
        if (!(input >> mode) || (input >> extra)
            || !capabilities.selectableAudioModes
            || mode < Device::AudioModeOmni || mode >= Device::AudioModeButt) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::audioMode;
        command.commandID = commandID;
        command.value = mode;
        return command;
    }
    if (verb == "audio_input_gain") {
        int percent = -1;
        if (!(input >> percent) || (input >> extra) || percent < 0 || percent > 100) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::audioInputGain;
        command.commandID = commandID;
        command.value = percent;
        return command;
    }
    if (verb == "camera_white_balance") {
        std::string mode;
        if (!(input >> mode)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::cameraWhiteBalance;
        command.commandID = commandID;
        if (mode == "auto") {
            if (input >> extra) return {};
            return command;
        }
        if (mode == "manual") {
            int temperatureKelvin = 0;
            if (!(input >> temperatureKelvin) || (input >> extra)
                || temperatureKelvin < 2'000 || temperatureKelvin > 9'000) return {};
            command.whiteBalanceAutomatic = false;
            command.temperatureKelvin = temperatureKelvin;
            return command;
        }
        return {};
    }
    if (verb == "camera_ae_lock") {
        int locked = -1;
        if (!(input >> locked) || (input >> extra) || (locked != 0 && locked != 1)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::cameraExposureLock;
        command.commandID = commandID;
        command.exposureLocked = locked == 1;
        return command;
    }
    if (verb == "camera_focus") {
        std::string mode;
        if (!(input >> mode)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::cameraFocus;
        command.commandID = commandID;
        if (mode == "auto") {
            if (input >> extra) return {};
            return command;
        }
        if (mode == "manual") {
            int position = 0;
            if (!(input >> position) || (input >> extra) || position < 0 || position > 100) return {};
            command.focusAutomatic = false;
            command.focusPosition = position;
            return command;
        }
        return {};
    }
    if (verb == "camera_absolute_exposure") {
        std::string mode;
        if (!(input >> mode)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::cameraAbsoluteExposure;
        command.commandID = commandID;
        if (mode == "auto") {
            if (input >> extra) return {};
            return command;
        }
        if (mode == "manual") {
            int shutterCode = 0;
            if (!(input >> shutterCode) || (input >> extra) || shutterCode < 0 || shutterCode > 100) return {};
            command.absoluteExposureAutomatic = false;
            command.absoluteExposureShutterCode = shutterCode;
            return command;
        }
        return {};
    }
    if (verb == "camera_face_priority") {
        int enabled = -1;
        if (!(input >> enabled) || (input >> extra) || (enabled != 0 && enabled != 1)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::cameraFacePriority;
        command.commandID = commandID;
        command.facePriorityEnabled = enabled == 1;
        return command;
    }
    if (verb == "camera_anti_flicker") {
        int mode = -1;
        if (!(input >> mode) || (input >> extra)
            || mode < Device::PowerLineFreqOff || mode > Device::PowerLineFreqAuto) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::cameraAntiFlicker;
        command.commandID = commandID;
        command.antiFlickerMode = mode;
        return command;
    }
    if (verb == "camera_image_tuning") {
        std::string brightness;
        std::string contrast;
        std::string hue;
        std::string saturation;
        std::string sharpness;
        if (!(input >> brightness >> contrast >> hue >> saturation >> sharpness) || (input >> extra)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::cameraImageTuning;
        command.commandID = commandID;
        if (!parseImageTuningValue(brightness, command.imageTuning.brightness)
            || !parseImageTuningValue(contrast, command.imageTuning.contrast)
            || !parseImageTuningValue(hue, command.imageTuning.hue)
            || !parseImageTuningValue(saturation, command.imageTuning.saturation)
            || !parseImageTuningValue(sharpness, command.imageTuning.sharpness)
            || !command.imageTuning.containsAdjustment()) return {};
        return command;
    }
    if (verb == "native_tracking_policy") {
        int speedMode = -1;
        int motionTracking = -1;
        int foreTarget = -1;
        int adaptiveComposition = -1;
        int adaptivePanGain = -1;
        int adaptivePitchGain = -1;
        std::string panGain;
        std::string pitchGain;
        if (!(input >> speedMode >> motionTracking >> foreTarget >> adaptiveComposition >> adaptivePanGain >> adaptivePitchGain >> panGain >> pitchGain) || (input >> extra)
            || !validNativeHumanTrackingSpeedMode(speedMode)
            || (motionTracking != 0 && motionTracking != 1)
            || (foreTarget != 0 && foreTarget != 1)
            || (adaptiveComposition != 0 && adaptiveComposition != 1)
            || (adaptivePanGain != 0 && adaptivePanGain != 1)
            || (adaptivePitchGain != 0 && adaptivePitchGain != 1)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::nativeHumanTrackingPolicy;
        command.commandID = commandID;
        if (!parseNativeHumanTrackingGain(panGain, command.nativeTrackingPolicy.panGain)
            || !parseNativeHumanTrackingGain(pitchGain, command.nativeTrackingPolicy.pitchGain)) return {};
        const bool hasManualGain = command.nativeTrackingPolicy.panGain || command.nativeTrackingPolicy.pitchGain;
        if (hasManualGain && (!command.nativeTrackingPolicy.panGain || !command.nativeTrackingPolicy.pitchGain
            || adaptivePanGain == 1 || adaptivePitchGain == 1)) return {};
        command.nativeTrackingPolicy = NativeHumanTrackingPolicy {
            speedMode,
            motionTracking == 1,
            foreTarget == 1,
            adaptiveComposition == 1,
            adaptivePanGain == 1,
            adaptivePitchGain == 1,
            command.nativeTrackingPolicy.panGain,
            command.nativeTrackingPolicy.pitchGain,
        };
        return command;
    }
    if (verb == "camera_fov") {
        int degrees = 0;
        if (!(input >> degrees) || (input >> extra) || !fovTypeForDegrees(degrees)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::cameraFieldOfView;
        command.commandID = commandID;
        command.value = degrees;
        return command;
    }
    if (verb == "doa_follow") {
        int enabled = -1;
        if (!(input >> enabled) || (input >> extra)
            || !capabilities.soundLocalization
            || (enabled != 0 && enabled != 1)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::doaFollow;
        command.commandID = commandID;
        command.value = enabled;
        return command;
    }
    if (verb == "indicator_set" || verb == "indicator_clear") {
        int stateID = -1;
        if (!(input >> stateID) || (input >> extra)) return {};
        // Raw state IDs are deliberately not a general command surface. Each
        // product may expose only its firmware-confirmed status entries.
        if (!capabilities.firmwareIndicatorPalette || !validFirmwareIndicatorStateID(profile, stateID)) return {};
        BridgeCommand command;
        command.type = verb == "indicator_set"
            ? BridgeCommandType::indicatorSet
            : BridgeCommandType::indicatorClear;
        command.commandID = commandID;
        command.value = stateID;
        return command;
    }
    if (verb == "indicator_brightness") {
        int brightness = -1;
        if (!(input >> brightness) || (input >> extra) || brightness < 0 || brightness > 3) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::indicatorBrightness;
        command.commandID = commandID;
        command.value = brightness;
        return command;
    }
    if (verb == "indicator_enabled") {
        int enabled = -1;
        if (!(input >> enabled) || (input >> extra) || (enabled != 0 && enabled != 1)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::indicatorEnabled;
        command.commandID = commandID;
        command.value = enabled;
        return command;
    }
    if (verb == "indicator_enforce") {
        int stateID = -1;
        std::string patternName;
        if (!(input >> stateID >> patternName) || (input >> extra)) return {};
        if (!capabilities.firmwareIndicatorPalette || !validFirmwareIndicatorStateID(profile, stateID)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::indicatorEnforce;
        command.commandID = commandID;
        command.value = stateID;
        const auto pattern = parseIndicatorPattern(patternName);
        if (!pattern) return {};
        command.indicatorPattern = *pattern;
        return command;
    }
    if (verb == "indicator_reconcile") {
        int stateID = -1;
        std::string patternName;
        if (!(input >> stateID >> patternName) || (input >> extra)
            || !capabilities.firmwareIndicatorPalette || !validFirmwareIndicatorStateID(profile, stateID)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::indicatorReconcile;
        command.commandID = commandID;
        command.value = stateID;
        const auto pattern = parseIndicatorPattern(patternName);
        if (!pattern) return {};
        command.indicatorPattern = *pattern;
        return command;
    }
    if (verb == "indicator_rgb_clear") {
        if (input >> extra || profile != DiscoveryResult::Profile::tiny3Lite) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::indicatorRGBClear;
        command.commandID = commandID;
        return command;
    }
    if (verb == "indicator_rgb_enforce" || verb == "indicator_rgb_reconcile") {
        int red = -1;
        int green = -1;
        int blue = -1;
        std::string patternName;
        if (!(input >> red >> green >> blue >> patternName) || (input >> extra)
            || red < 0 || red > 255 || green < 0 || green > 255 || blue < 0 || blue > 255) return {};
        const Tiny3FixedRGB color {
            static_cast<uint8_t>(red),
            static_cast<uint8_t>(green),
            static_cast<uint8_t>(blue),
        };
        if (!isSupportedTiny3DirectRGB(profile, color)) return {};
        const auto pattern = parseIndicatorPattern(patternName);
        if (!pattern) return {};
        BridgeCommand command;
        command.type = verb == "indicator_rgb_enforce"
            ? BridgeCommandType::indicatorRGBEnforce
            : BridgeCommandType::indicatorRGBReconcile;
        command.commandID = commandID;
        command.indicatorRGB = color;
        command.indicatorPattern = *pattern;
        return command;
    }
    if (verb == "shutdown") return (input >> extra) ? BridgeCommand {} : BridgeCommand {BridgeCommandType::shutdown, commandID};
    if (input >> extra) return {};
    if (verb == "heartbeat") return {BridgeCommandType::heartbeat, commandID};
    if (verb == "external_stop") return {BridgeCommandType::externalStop, commandID};
    if (verb == "manual_stop") return {BridgeCommandType::manualStop, commandID};
    if (verb == "recenter") return {BridgeCommandType::recenter, commandID};
    return {};
}

class IndicatorSession {
public:
    IndicatorSession(std::shared_ptr<Device> device, Trace &trace, DeviceCapabilities capabilities)
        : device_(std::move(device)), trace_(trace), capabilities_(capabilities) {
        readBaseline();
    }

    ~IndicatorSession() {
        restore();
    }

    void set(int stateID, const std::string &commandID) noexcept {
        if (!requireFirmwarePalette("set_state", commandID)) return;
        activate(stateID, IndicatorPattern::steady, "set_state", commandID);
    }

    void clear(int stateID, const std::string &commandID) noexcept {
        if (!requireFirmwarePalette("clear_state", commandID)) return;
        trace_.event("indicator.command", "soma", "clear_state", 0, "state_id=" + std::to_string(stateID), commandID);
        if (desiredState_ && *desiredState_ == stateID) {
            desiredState_.reset();
            pattern_ = IndicatorPattern::steady;
            patternPhaseIndex_ = 0;
            pulseVisible_ = false;
            nextPulseTransition_.reset();
        }
        const bool visibilityRestored = restorePulseLEDVisibility();
        int result = RM_RET_ERR;
        if (visibilityRestored) {
            try { result = device_->sysMgClearIndicatorStateR(static_cast<uint8_t>(stateID)); } catch (...) {}
        }
        if (result == RM_RET_OK && activeState_ && *activeState_ == stateID) activeState_.reset();
        trace_.event(
            "indicator.ack",
            result == RM_RET_OK ? "firmware" : "fault",
            result == RM_RET_OK ? "state_cleared" : "clear_rejected",
            result,
            "state_id=" + std::to_string(stateID),
            commandID
        );
    }

    void setBrightness(int brightness, const std::string &commandID) noexcept {
        if (!requireBasicControl("set_brightness", commandID)) return;
        trace_.event("indicator.command", "soma", "set_brightness", 0, "brightness=" + std::to_string(brightness), commandID);
        const int result = callSetBrightness(static_cast<uint8_t>(brightness));
        if (result == RM_RET_OK) {
            requestedBrightness_ = static_cast<uint8_t>(brightness);
            brightnessChanged_ = true;
            pulseBrightnessDimmed_ = false;
        }
        trace_.event(
            "indicator.ack",
            result == RM_RET_OK ? "soma" : "fault",
            result == RM_RET_OK ? "brightness_active" : "brightness_rejected",
            result,
            "brightness=" + std::to_string(brightness),
            commandID
        );
    }

    void setEnabled(bool enabled, const std::string &commandID) noexcept {
        if (!requireBasicControl("set_enabled", commandID)) return;
        trace_.event(
            "indicator.command",
            "soma",
            "set_enabled",
            0,
            std::string("enabled=") + (enabled ? "true" : "false"),
            commandID
        );
        const int result = callSetEnabled(enabled);
        if (result == RM_RET_OK) {
            enabledChanged_ = true;
            pulseLEDDisabled_ = !enabled;
        }
        trace_.event(
            "indicator.ack",
            result == RM_RET_OK ? "soma" : "fault",
            result == RM_RET_OK ? "enabled_active" : "enabled_rejected",
            result,
            std::string("enabled=") + (enabled ? "true" : "false"),
            commandID
        );
    }

    void enforce(int stateID, IndicatorPattern pattern, const std::string &commandID) noexcept {
        if (!requireFirmwarePalette("enforce_state", commandID)) return;
        activate(stateID, pattern, "enforce_state", commandID);
    }

    void reconcile(int stateID, IndicatorPattern pattern, const std::string &commandID) noexcept {
        if (!requireFirmwarePalette("reconcile_state", commandID)) return;
        activate(stateID, pattern, "reconcile_state", commandID);
    }

    void enforceRGB(Tiny3FixedRGB color, IndicatorPattern pattern, const std::string &commandID) noexcept {
        if (!requireTiny3DirectRGB(color, "enforce_rgb", commandID)) return;
        activateRGB(color, pattern, "enforce_rgb", commandID);
    }

    void reconcileRGB(Tiny3FixedRGB color, IndicatorPattern pattern, const std::string &commandID) noexcept {
        if (!requireTiny3DirectRGB(color, "reconcile_rgb", commandID)) return;
        activateRGB(color, pattern, "reconcile_rgb", commandID);
    }

    void clearRGB(const std::string &commandID) noexcept {
        if (!desiredRGB_ && !activeRGB_) {
            trace_.event("indicator.ack", "soma", "rgb_already_cleared", RM_RET_OK, "presentation_cleared=true", commandID);
            return;
        }
        trace_.event("indicator.command", "soma", "clear_rgb", 0, "presentation_cleared=true", commandID);
        desiredRGB_.reset();
        pattern_ = IndicatorPattern::steady;
        patternPhaseIndex_ = 0;
        pulseVisible_ = false;
        nextPulseTransition_.reset();
        const bool visibilityRestored = restorePulseLEDVisibility();
        int result = RM_RET_ERR;
        if (visibilityRestored) {
            result = callSetEnabled(false);
            if (result == RM_RET_OK) {
                pulseLEDDisabled_ = true;
                pulseChangedEnabled_ = true;
                activeRGB_.reset();
            }
        }
        trace_.event(
            "indicator.ack",
            result == RM_RET_OK ? "firmware" : "fault",
            result == RM_RET_OK ? "rgb_cleared" : "rgb_clear_rejected",
            result,
            "presentation_cleared=true; baseline_restored=" + std::string(result == RM_RET_OK ? "true" : "false"),
            commandID
        );
    }

    /// A camera AI mode transition may overwrite the segmented LED with its
    /// firmware status animation. Reapply the already-selected semantic
    /// presentation without changing the presentation state or pulse phase.
    void reassertAfterCameraModeTransition(const std::string &commandID) noexcept {
        if (!desiredState_ && !desiredRGB_) return;
        const bool visibilityRestored = restorePulseLEDVisibility();
        int result = RM_RET_ERR;
        std::string presentation;
        if (visibilityRestored && desiredRGB_) {
            presentation = "rgb=" + rgbDescription(*desiredRGB_);
            result = callTiny3FixedRGB(*desiredRGB_);
            if (result == RM_RET_OK) activeRGB_ = desiredRGB_;
        } else if (visibilityRestored && desiredState_) {
            presentation = "state_id=" + std::to_string(*desiredState_);
            {
                std::lock_guard<std::mutex> lock(sdkMutex);
                try { result = device_->sysMgSetIndicatorStateR(static_cast<uint8_t>(*desiredState_)); } catch (...) {}
            }
            if (result == RM_RET_OK) activeState_ = desiredState_;
        } else {
            presentation = desiredRGB_
                ? "rgb=" + rgbDescription(*desiredRGB_)
                : "state_id=" + std::to_string(*desiredState_);
        }
        trace_.event(
            "indicator.ack",
            result == RM_RET_OK ? "soma" : "fault",
            result == RM_RET_OK ? "presentation_reasserted_after_ai_transition" : "presentation_reassertion_rejected",
            result,
            presentation + "; led_enabled=" + (visibilityRestored ? "true" : "restore_failed"),
            commandID
        );
    }

    std::optional<Clock::time_point> nextWakeup() const noexcept {
        return nextPulseTransition_;
    }

    void tick(Clock::time_point now) noexcept {
        if (pattern_ == IndicatorPattern::steady
            || (!desiredState_ && !desiredRGB_)
            || !nextPulseTransition_ || now < *nextPulseTransition_) return;

        const std::string presentation = desiredRGB_
            ? "rgb=" + rgbDescription(*desiredRGB_)
            : "state_id=" + std::to_string(*desiredState_);
        const auto &phases = indicatorPatternPhases(pattern_);
        const size_t nextPhaseIndex = (patternPhaseIndex_ + 1) % phases.size();
        const auto &nextPhase = phases[nextPhaseIndex];
        if (!nextPhase.illuminated) {
            // State clearing and LED enable control both hand the segmented
            // bar back to the camera firmware. A pulse must retain the
            // selected state and only lower its brightness for the dark phase.
            trace_.event("indicator.command", "soma", "pulse_off", 0, presentation);
            const int result = callSetBrightness(0);
            if (result == RM_RET_OK) {
                pulseBrightnessDimmed_ = true;
                brightnessChanged_ = true;
                pulseVisible_ = false;
                patternPhaseIndex_ = nextPhaseIndex;
                nextPulseTransition_ = now + std::chrono::milliseconds(nextPhase.durationMilliseconds);
            } else {
                nextPulseTransition_ = now + std::chrono::milliseconds(kPulseRetryMilliseconds);
            }
            trace_.event(
                "indicator.ack",
                result == RM_RET_OK ? "soma" : "fault",
                result == RM_RET_OK ? "pulse_off" : "pulse_off_rejected",
                result,
                presentation + "; brightness=0; presentation_retained=true"
            );
            return;
        }

        trace_.event("indicator.command", "soma", "pulse_on", 0, presentation);
        const bool enabled = restorePulseLEDVisibility();
        int presentationResult = RM_RET_ERR;
        if (enabled) {
            if (desiredRGB_) {
                presentationResult = callTiny3FixedRGB(*desiredRGB_);
            } else {
                try { presentationResult = device_->sysMgSetIndicatorStateR(static_cast<uint8_t>(*desiredState_)); } catch (...) {}
            }
        }
        if (enabled && presentationResult == RM_RET_OK) {
            if (desiredRGB_) activeRGB_ = *desiredRGB_;
            else activeState_ = *desiredState_;
            pulseVisible_ = true;
            patternPhaseIndex_ = nextPhaseIndex;
            nextPulseTransition_ = now + std::chrono::milliseconds(nextPhase.durationMilliseconds);
        } else {
            nextPulseTransition_ = now + std::chrono::milliseconds(kPulseRetryMilliseconds);
        }
            trace_.event(
                "indicator.ack",
            enabled && presentationResult == RM_RET_OK ? "soma" : "fault",
            enabled && presentationResult == RM_RET_OK ? "pulse_on" : "pulse_on_rejected",
            enabled ? presentationResult : RM_RET_ERR,
            presentation
                + "; presentation_brightness=" + (enabled ? std::to_string(pulseBrightness()) : "restore_failed")
                + "; presentation_set=" + (presentationResult == RM_RET_OK ? "true" : "false")
            );
    }

    void restore() noexcept {
        if (restored_) return;
        restored_ = true;
        bool clearSucceeded = true;
        const bool visibilityRestored = restorePulseLEDVisibility();
        clearSucceeded = clearSucceeded && visibilityRestored;
        if (capabilities_.firmwareIndicatorPalette && visibilityRestored && activeState_) {
            int result = RM_RET_ERR;
            try { result = device_->sysMgClearIndicatorStateR(static_cast<uint8_t>(*activeState_)); } catch (...) {}
            clearSucceeded = clearSucceeded && result == RM_RET_OK;
        }
        if (visibilityRestored && activeRGB_) activeRGB_.reset();
        activeState_.reset();
        desiredState_.reset();
        activeRGB_.reset();
        desiredRGB_.reset();
        pattern_ = IndicatorPattern::steady;
        patternPhaseIndex_ = 0;
        pulseVisible_ = false;
        nextPulseTransition_.reset();
        bool globalsSucceeded = true;
        if (brightnessChanged_ && baselineBrightness_) {
            globalsSucceeded = callSetBrightness(*baselineBrightness_) == RM_RET_OK && globalsSucceeded;
        }
        if ((enabledChanged_ || pulseChangedEnabled_) && baselineEnabled_) {
            globalsSucceeded = callSetEnabled(*baselineEnabled_) == RM_RET_OK && globalsSucceeded;
        }
        trace_.event(
            "indicator.ack",
            clearSucceeded && globalsSucceeded ? "firmware" : "fault",
            clearSucceeded && globalsSucceeded ? "restored" : "restore_incomplete",
            clearSucceeded && globalsSucceeded ? RM_RET_OK : RM_RET_ERR,
            std::string("soma_states_cleared=") + (clearSucceeded ? "true" : "false")
                + "; globals_restored=" + (globalsSucceeded ? "true" : "false")
        );
    }

private:
    static constexpr int kPulseRetryMilliseconds = 160;

    bool requireFirmwarePalette(const std::string &operation, const std::string &commandID) noexcept {
        if (capabilities_.firmwareIndicatorPalette) return true;
        trace_.event(
            "indicator.ack",
            "firmware",
            "palette_unverified_for_profile",
            RM_RET_ERR,
            "profile=" + std::string(capabilities_.identifier) + "; operation=" + operation,
            commandID
        );
        return false;
    }

    bool requireTiny3DirectRGB(
        Tiny3FixedRGB color,
        const std::string &operation,
        const std::string &commandID
    ) noexcept {
        if (capabilities_.directIndicatorRGB && isSupportedTiny3DirectRGB(DiscoveryResult::Profile::tiny3Lite, color)) return true;
        trace_.event(
            "indicator.ack",
            "firmware",
            "fixed_rgb_unavailable_for_profile",
            RM_RET_ERR,
            "profile=" + std::string(capabilities_.identifier) + "; operation=" + operation
                + "; rgb=" + rgbDescription(color),
            commandID
        );
        return false;
    }

    bool requireBasicControl(const std::string &operation, const std::string &commandID) noexcept {
        if (capabilities_.indicatorEnableAndBrightness) return true;
        trace_.event(
            "indicator.ack",
            "firmware",
            "basic_control_unsupported",
            RM_RET_ERR,
            "profile=" + std::string(capabilities_.identifier) + "; operation=" + operation,
            commandID
        );
        return false;
    }

    static std::string rgbDescription(Tiny3FixedRGB color) {
        return std::to_string(color.red) + "," + std::to_string(color.green) + "," + std::to_string(color.blue);
    }

    void activateRGB(
        Tiny3FixedRGB color,
        IndicatorPattern pattern,
        const std::string &operation,
        const std::string &commandID
    ) noexcept {
        const bool sameActiveColor = desiredRGB_ && activeRGB_
            && *desiredRGB_ == color && *activeRGB_ == color;
        const bool beginContactPulse = pattern == IndicatorPattern::firmwareAnimation
            && pattern_ != IndicatorPattern::firmwareAnimation;
        if (sameActiveColor && !beginContactPulse) {
            const bool visibilityRestored = restorePulseLEDVisibility();
            pattern_ = pattern;
            patternPhaseIndex_ = 0;
            nextPulseTransition_.reset();
            trace_.event(
                "indicator.ack",
                visibilityRestored ? "soma" : "fault",
                visibilityRestored ? "rgb_already_active" : "rgb_restore_rejected",
                visibilityRestored ? RM_RET_OK : RM_RET_ERR,
                "rgb=" + rgbDescription(color) + "; pattern=" + indicatorPatternName(pattern)
                    + "; no_reassertion; brightness_restored=" + (visibilityRestored ? "true" : "false"),
                commandID
            );
            return;
        }

        trace_.event(
            "indicator.command",
            "soma",
            operation,
            0,
            "rgb=" + rgbDescription(color) + "; pattern=" + indicatorPatternName(pattern),
            commandID
        );
        const bool visibilityRestored = restorePulseLEDVisibility();
        bool priorCleared = true;
        if (visibilityRestored && activeState_) {
            int clearResult = RM_RET_ERR;
            try { clearResult = device_->sysMgClearIndicatorStateR(static_cast<uint8_t>(*activeState_)); } catch (...) {}
            priorCleared = clearResult == RM_RET_OK;
            if (priorCleared) activeState_.reset();
        }

        desiredState_.reset();
        desiredRGB_ = color;
        pattern_ = pattern;
        patternPhaseIndex_ = 0;
        nextPulseTransition_.reset();
        int setResult = visibilityRestored ? callTiny3FixedRGB(color) : RM_RET_ERR;
        if (setResult == RM_RET_OK) activeRGB_ = color;
        pulseVisible_ = activeRGB_ && *activeRGB_ == color;
        if (pulseVisible_ && pattern_ != IndicatorPattern::steady) {
            nextPulseTransition_ = Clock::now() + std::chrono::milliseconds(indicatorPatternPhases(pattern_).front().durationMilliseconds);
        }
        const bool succeeded = visibilityRestored && priorCleared && setResult == RM_RET_OK;
        trace_.event(
            "indicator.ack",
            succeeded ? "soma" : "fault",
            succeeded ? "rgb_active" : "rgb_transition_incomplete",
            succeeded ? RM_RET_OK : RM_RET_ERR,
            "rgb=" + rgbDescription(color)
                + "; pattern=" + indicatorPatternName(pattern)
                + "; led_enabled=" + (visibilityRestored ? "true" : "restore_failed")
                + "; previous_state_cleared=" + (priorCleared ? "true" : "false")
                + "; rgb_sent=" + (setResult == RM_RET_OK ? "true" : "false"),
            commandID
        );
    }

    void activate(int stateID, IndicatorPattern pattern, const std::string &operation, const std::string &commandID) noexcept {
        const bool desiredMatches = desiredState_ && *desiredState_ == stateID && pattern_ == pattern;
        if (desiredMatches && (pattern != IndicatorPattern::steady || (activeState_ && *activeState_ == stateID))) {
            trace_.event(
                "indicator.ack",
                "soma",
                "state_already_active",
                RM_RET_OK,
                "state_id=" + std::to_string(stateID)
                    + "; pattern=" + indicatorPatternName(pattern)
                    + "; no_reassertion",
                commandID
            );
            return;
        }

        trace_.event(
            "indicator.command",
            "soma",
            operation,
            0,
            "state_id=" + std::to_string(stateID)
                + "; pattern=" + indicatorPatternName(pattern),
            commandID
        );
        const bool visibilityRestored = restorePulseLEDVisibility();
        bool priorCleared = true;
        const bool startsFirmwareAnimation = pattern == IndicatorPattern::firmwareAnimation;
        if (visibilityRestored && activeState_
            && (*activeState_ != stateID || startsFirmwareAnimation)) {
            int clearResult = RM_RET_ERR;
            try { clearResult = device_->sysMgClearIndicatorStateR(static_cast<uint8_t>(*activeState_)); } catch (...) {}
            priorCleared = clearResult == RM_RET_OK;
            if (priorCleared) activeState_.reset();
        }

        activeRGB_.reset();
        desiredRGB_.reset();
        desiredState_ = stateID;
        pattern_ = pattern;
        patternPhaseIndex_ = 0;
        nextPulseTransition_.reset();
        int setResult = visibilityRestored ? RM_RET_OK : RM_RET_ERR;
        if (visibilityRestored && !activeState_) {
            setResult = RM_RET_ERR;
            try { setResult = device_->sysMgSetIndicatorStateR(static_cast<uint8_t>(stateID)); } catch (...) {}
            if (setResult == RM_RET_OK) activeState_ = stateID;
        }
        pulseVisible_ = activeState_ && *activeState_ == stateID;
        if (pulseVisible_ && pattern_ != IndicatorPattern::steady
            && pattern_ != IndicatorPattern::firmwareAnimation) {
            nextPulseTransition_ = Clock::now() + std::chrono::milliseconds(indicatorPatternPhases(pattern_).front().durationMilliseconds);
        }
        const bool succeeded = visibilityRestored && priorCleared && setResult == RM_RET_OK;
        trace_.event(
            "indicator.ack",
            succeeded ? "soma" : "fault",
            succeeded ? "state_active" : "state_transition_incomplete",
            succeeded ? RM_RET_OK : RM_RET_ERR,
            "state_id=" + std::to_string(stateID)
                + "; pattern=" + indicatorPatternName(pattern)
                + "; led_enabled=" + (visibilityRestored ? "true" : "restore_failed")
                + "; previous_state_cleared=" + (priorCleared ? "true" : "false")
                + "; physical_state_set=" + (setResult == RM_RET_OK ? "true" : "false"),
            commandID
        );
    }

    using GetEnabled = int (*)(Device *, bool &);
    using SetEnabled = int (*)(Device *, bool);
    using GetBrightness = int (*)(Device *, uint8_t &);
    using SetBrightness = int (*)(Device *, uint8_t);

    template <typename Function>
    static Function symbol(const char *name) noexcept {
        return reinterpret_cast<Function>(dlsym(RTLD_DEFAULT, name));
    }

    void readBaseline() noexcept {
        bool enabled = false;
        uint8_t brightness = 0;
        const auto getEnabled = symbol<GetEnabled>("_ZN6Device19sysMgGetLedEnabledRERb");
        const auto getBrightness = symbol<GetBrightness>("_ZN6Device22sysMgGetLedBrightnessRERh");
        int enabledResult = RM_RET_ERR;
        int brightnessResult = RM_RET_ERR;
        if (getEnabled || getBrightness) {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try {
                if (getEnabled) enabledResult = getEnabled(device_.get(), enabled);
                if (getBrightness) brightnessResult = getBrightness(device_.get(), brightness);
            } catch (...) {
                enabledResult = RM_RET_ERR;
                brightnessResult = RM_RET_ERR;
            }
        }
        if (enabledResult == RM_RET_OK) baselineEnabled_ = enabled;
        if (brightnessResult == RM_RET_OK) baselineBrightness_ = brightness;
        trace_.event(
            "indicator.capability",
            "firmware",
            capabilities_.firmwareIndicatorPalette ? "rgb_palette_available" : "basic_led_control_available",
            enabledResult == RM_RET_OK && brightnessResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
            "profile=" + std::string(capabilities_.identifier)
                + "; arbitrary_rgb=false; firmware_palette="
                + (capabilities_.firmwareIndicatorPalette ? "true" : "false")
                + "; enabled="
                + (baselineEnabled_ ? (*baselineEnabled_ ? std::string("true") : std::string("false")) : std::string("unavailable"))
                + "; brightness="
                + (baselineBrightness_ ? std::to_string(*baselineBrightness_) : std::string("unavailable"))
        );
    }

    int callSetEnabled(bool enabled) noexcept {
        const auto function = symbol<SetEnabled>("_ZN6Device19sysMgSetLedEnabledREb");
        if (!function) return RM_RET_ERR;
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { return function(device_.get(), enabled); } catch (...) { return RM_RET_ERR; }
    }

    int callSetBrightness(uint8_t brightness) noexcept {
        const auto function = symbol<SetBrightness>("_ZN6Device22sysMgSetLedBrightnessREh");
        if (!function) return RM_RET_ERR;
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { return function(device_.get(), brightness); } catch (...) { return RM_RET_ERR; }
    }

    int callTiny3FixedRGB(Tiny3FixedRGB color) noexcept {
        std::string failure;
        auto message = makeTiny3NativePaletteMessage(device_.get(), color, failure);
        if (!message || !message->sendSync) return RM_RET_ERR;
        std::array<uint8_t, kTiny3FrameCapacity> response {};
        std::lock_guard<std::mutex> lock(sdkMutex);
        try {
            return message->sendSync(
                message->devicePrivate,
                message->bytes.data(),
                response.data(),
                1,
                false
            );
        } catch (...) {
            return RM_RET_ERR;
        }
    }

    bool restorePulseLEDVisibility() noexcept {
        if (pulseLEDDisabled_) {
            const int result = callSetEnabled(true);
            if (result != RM_RET_OK) return false;
            pulseLEDDisabled_ = false;
            pulseChangedEnabled_ = true;
        }
        if (!pulseBrightnessDimmed_) return true;
        const int result = callSetBrightness(pulseBrightness());
        if (result != RM_RET_OK) return false;
        pulseBrightnessDimmed_ = false;
        brightnessChanged_ = true;
        return true;
    }

    uint8_t pulseBrightness() const noexcept {
        if (requestedBrightness_) return *requestedBrightness_;
        if (baselineBrightness_) return *baselineBrightness_;
        return 3;
    }

    std::shared_ptr<Device> device_;
    Trace &trace_;
    DeviceCapabilities capabilities_;
    std::optional<int> activeState_;
    std::optional<int> desiredState_;
    std::optional<Tiny3FixedRGB> activeRGB_;
    std::optional<Tiny3FixedRGB> desiredRGB_;
    IndicatorPattern pattern_ = IndicatorPattern::steady;
    size_t patternPhaseIndex_ = 0;
    bool pulseVisible_ = false;
    bool pulseLEDDisabled_ = false;
    bool pulseChangedEnabled_ = false;
    bool pulseBrightnessDimmed_ = false;
    std::optional<Clock::time_point> nextPulseTransition_;
    std::optional<bool> baselineEnabled_;
    std::optional<uint8_t> baselineBrightness_;
    std::optional<uint8_t> requestedBrightness_;
    bool brightnessChanged_ = false;
    bool enabledChanged_ = false;
    bool restored_ = false;
};

std::optional<std::string> readBridgeLine() noexcept {
    std::string line;
    line.reserve(128);
    while (true) {
        char character = 0;
        const ssize_t count = ::read(STDIN_FILENO, &character, 1);
        if (count == 0) return std::nullopt;
        if (count < 0) {
            if (errno == EINTR) continue;
            return std::nullopt;
        }
        if (character == '\n') return line;
        if (character == '\r') continue;
        // All valid scalar bridge commands are far shorter than this. Keep
        // consuming an oversized line so the next command retains framing,
        // then let the existing parser reject it.
        if (line.size() < 512) line.push_back(character);
    }
}

/// The OBSBOT's built-in hand-gesture controls (a raised hand selects a target
/// and starts its own tracking, gestures also trigger zoom/record) are
/// independent of SOMA's attention controller and can move the gimbal out from
/// under the L0 motor authority at any moment. Disable every gesture function
/// at startup so the camera only moves when SOMA commands it.
bool disableHandGestures(const std::shared_ptr<Device> &device, Trace &trace) noexcept {
    // aiSetGestureCtrlIndividualR gesture IDs: 0 target, 1 zoom,
    // 2 dynamic zoom, 3 dynamic zoom direction, 4 record.
    const int gestureIDs[] = {0, 1, 2, 3, 4};
    int failures = 0;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        for (const int gestureID : gestureIDs) {
            int result = RM_RET_ERR;
            try { result = device->aiSetGestureCtrlIndividualR(gestureID, false); } catch (...) {}
            if (result != RM_RET_OK) ++failures;
        }
    }
    const bool confirmed = failures == 0;
    trace.event(
        "camera.ack",
        confirmed ? "manual" : "fault",
        confirmed ? "gestures_disabled" : "gesture_disable_incomplete",
        confirmed ? RM_RET_OK : RM_RET_ERR,
        "disabled_gesture_ids=0,1,2,3,4; failures=" + std::to_string(failures),
        "startup-gesture-off"
    );
    return confirmed;
}

/// A dedicated thread that keeps the pose stream flowing regardless of what
/// the bridge loop is doing. The synchronous SDK attitude read takes ~70ms and
/// bridge work (velocity calls, mode switches, blocking stdin reads) can stall
/// the loop for far longer; the runtime's coverage scan decelerates whenever
/// the pose stream goes quiet. The reporter owns no other SDK state and every
/// device call is serialized by sdkMutex, so it is safe to run concurrently.
class AttitudeReporter {
public:
    explicit AttitudeReporter(std::shared_ptr<Device> device)
        : device_(std::move(device)), thread_([this] { run(); }) {}

    ~AttitudeReporter() {
        stop_ = true;
        if (thread_.joinable()) thread_.join();
    }

private:
    void run() {
        auto nextHealthReport = Clock::now();
        std::optional<GimbalHealth> lastHealth;
        auto lastHealthReport = Clock::time_point::min();
        while (!stop_) {
            if (const auto attitude = readGimbalAttitude(device_)) emitGimbalAttitude(*attitude);
            const auto now = Clock::now();
            if (now >= nextHealthReport) {
                const auto health = readGimbalHealth(device_);
                const bool changed = !lastHealth || !hasSameGimbalHealth(*lastHealth, health);
                if (changed || now - lastHealthReport >= std::chrono::seconds(5)) {
                    emitGimbalHealth(health);
                    lastHealth = health;
                    lastHealthReport = now;
                }
                nextHealthReport = now + std::chrono::seconds(1);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }

    std::shared_ptr<Device> device_;
    std::atomic_bool stop_ = false;
    std::thread thread_;
};

int runBridgeServer(
    const std::shared_ptr<Device> &device,
    DiscoveryResult::Profile profile,
    Trace &trace,
    int durationSeconds,
    bool calibrationMode,
    bool profileCalibratedMotion
) {
    constexpr auto nativeWatchdog = std::chrono::milliseconds(750);
    constexpr auto externalWatchdog = std::chrono::milliseconds(700);
    const DeviceCapabilities &capabilities = capabilitiesFor(profile);
    if (!setDeviceRunStatus(device, Device::DevStatusRun, trace, "bridge-wake-1")) return 4;
    bool permitsProfileCalibratedMotion = profileCalibratedMotion
        && profile == DiscoveryResult::Profile::tiny3Lite
        && capabilities.boundedCalibrationPulses;
    emitDeviceCapabilities(device, capabilities);
    const bool needsRuntimeAttitudeReference = capabilities.requiresMeasuredAttitudeFrame
        && (calibrationMode || permitsProfileCalibratedMotion);
    if (needsRuntimeAttitudeReference) {
        // A normal runtime needs a coordinate reference, not a physical home.
        // Re-homing every bridge launch makes an otherwise healthy live system
        // pull its attention back to centre after any recoverable helper exit.
        // The current measured pose is an equally valid zero for the calibrated
        // velocity and image-axis transforms.  Only an explicit calibration
        // operation is allowed to command a physical home position.
        if (!calibrationMode) {
            if (const auto measured = readGimbalAttitude(device)) {
                emitGimbalHome(*measured);
                trace.event(
                    "camera.ack",
                    "manual",
                    "profile_pose_reference_ready",
                    RM_RET_OK,
                    "raw_attitude_reference=measured_current_pose; physical_recenter=false",
                    "runtime-pose-reference-1"
                );
            } else {
                permitsProfileCalibratedMotion = false;
                trace.event(
                    "camera.ack",
                    "manual",
                    "profile_pose_reference_deferred",
                    RM_RET_ERR,
                    "attitude_unavailable; external_motion_withheld; physical_recenter=false",
                    "runtime-pose-reference-1"
                );
            }
        } else {
            const bool centerAccepted = requestCenter(device, profile, trace, "calibration-home-1");
            if (!centerAccepted) {
                if (calibrationMode) return 4;
                permitsProfileCalibratedMotion = false;
                trace.event(
                    "camera.ack",
                    "manual",
                    "profile_home_deferred",
                    RM_RET_ERR,
                    "center_command_unconfirmed; external_motion_withheld; native_tracking_and_perception_remain_available",
                    "calibration-home-1"
                );
            } else {
                const auto home = waitForSettledCenter(device);
                if (!home) {
                    requestManualStop(device, profile, trace, "calibration_home_unconfirmed", "calibration-home-stop-1", "manual");
                    if (calibrationMode) return 4;
                    permitsProfileCalibratedMotion = false;
                    trace.event(
                        "camera.ack",
                        "manual",
                        "profile_home_deferred",
                        RM_RET_ERR,
                        "attitude_anchor_timeout; external_motion_withheld; native_tracking_and_perception_remain_available",
                        "calibration-home-1"
                    );
                } else {
                    emitGimbalHome(*home);
                    trace.event(
                        "camera.ack",
                        "manual",
                        "calibration_home_ready",
                        RM_RET_OK,
                        "raw_attitude_reference=measured_after_center",
                        "calibration-home-1"
                    );
                }
            }
        }
    }
    if (profile == DiscoveryResult::Profile::tiny2Lite) {
        if (!configureFixedCameraZoom(device, trace)) return 5;
        disableHandGestures(device, trace);
        configureConversationAudioProcessing(device, trace);
    } else if (profile == DiscoveryResult::Profile::tiny3Lite) {
        // Tiny 3 Lite exposes the same optical zoom getters/setters, but a
        // transient firmware timeout must not take the entire perception loop
        // down.  The subsequent imaging read publishes the actual factor.
        configureFixedCameraZoom(device, trace);
        configureConversationAudioProcessing(device, trace);
    } else {
        trace.event(
            "camera.capability",
            "firmware",
            "settings_preserved",
            RM_RET_OK,
            "profile=" + std::string(capabilities.identifier)
                + "; motor_calibrated=false; audio_mode_preserved=true; gesture_settings_preserved=true"
        );
    }
    inspectAudioFrontEnd(device, capabilities, trace);
    inspectImagingFrontEnd(device, capabilities, trace);
    inspectNativeTrackingFrontEnd(device, profile, trace);
    if (const auto fieldOfView = cameraHorizontalFieldOfViewDegrees(device)) emitHorizontalFieldOfView(*fieldOfView);
    if (const auto attitude = readGimbalAttitude(device)) emitGimbalAttitude(*attitude);
    IndicatorSession indicator(device, trace, capabilities);
    trace.event(
        "camera.owner",
        "manual",
        "bridge_ready",
        RM_RET_OK,
        "profile=" + std::string(capabilities.identifier)
            + "; awaiting_local_attention_commands; motor_calibrated="
            + (capabilities.calibratedMotorControl ? "true" : "false")
            + "; bounded_calibration="
            + (calibrationMode && capabilities.boundedCalibrationPulses ? "true" : "false")
            + "; profile_calibrated_motion="
            + (permitsProfileCalibratedMotion ? "true" : "false")
    );
    {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_NATIVE_BRIDGE_READY\n" << std::flush;
    }
    // Start the pose reporter after the one-shot startup reads so the first
    // sample is not duplicated; it runs until this function returns.
    AttitudeReporter attitudeReporter(device);
    bool nativeTracking = false;
    std::string nativeCommandID;
    NativeHumanTrackingPolicy nativeTrackingPolicy;
    auto lastHeartbeat = Clock::now();
    bool externalControl = false;
    auto lastExternalCommand = Clock::now();
    struct ExternalVelocity {
        double pitch = 0;
        double pan = 0;

        bool matches(const BridgeCommand &command) const noexcept {
            return pitch == command.pitch && pan == command.pan;
        }
    };
    std::optional<ExternalVelocity> appliedExternalVelocity;
    std::optional<Clock::time_point> externalPulseDeadline;
    std::string externalPulseStopCommandID;
    const bool continuous = durationSeconds == 0;
    const auto deadline = Clock::now() + std::chrono::seconds(durationSeconds);

    while ((continuous || Clock::now() < deadline) && !interrupted) {
        pollfd descriptor {STDIN_FILENO, POLLIN, 0};
        int pollTimeoutMilliseconds = externalControl ? 20 : 100;
        if (externalControl && externalPulseDeadline) {
            const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(*externalPulseDeadline - Clock::now()).count();
            pollTimeoutMilliseconds = static_cast<int>(std::clamp<int64_t>(remaining, 0, 100));
        }
        if (const auto indicatorWakeup = indicator.nextWakeup()) {
            const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(*indicatorWakeup - Clock::now()).count();
            pollTimeoutMilliseconds = std::min(
                pollTimeoutMilliseconds,
                static_cast<int>(std::clamp<int64_t>(remaining, 0, 100))
            );
        }
        const int polled = ::poll(&descriptor, 1, pollTimeoutMilliseconds);
        if (polled > 0 && (descriptor.revents & POLLIN)) {
            const auto line = readBridgeLine();
            if (!line) break;
            BridgeCommand command = parseBridgeCommand(*line, profile, capabilities);
            // Direct motion calls are synchronous in the Tiny SDK and take
            // longer than one camera/control period. Vision and the smooth
            // exploration loop can therefore publish several replacements
            // while one SDK call is in flight. Drain only consecutive direct
            // motion commands and retain the newest; ownership, stop, and
            // shutdown commands remain ordered barriers.
            const auto isReplaceableDirectMotion = [](BridgeCommandType type) {
                return type == BridgeCommandType::externalVelocity
                    || type == BridgeCommandType::externalPosition;
            };
            if (isReplaceableDirectMotion(command.type)) {
                while (true) {
                    pollfd pending {STDIN_FILENO, POLLIN, 0};
                    if (::poll(&pending, 1, 0) <= 0 || !(pending.revents & POLLIN)) break;
                    const auto newerLine = readBridgeLine();
                    if (!newerLine) break;
                    const BridgeCommand newer = parseBridgeCommand(*newerLine, profile, capabilities);
                    if (isReplaceableDirectMotion(newer.type)) {
                        command = newer;
                        continue;
                    }
                    // A release, shutdown, calibration pulse, or ownership
                    // handoff is an ordered barrier and must win immediately.
                    command = newer;
                    break;
                }
            }
            switch (command.type) {
            case BridgeCommandType::nativeStart:
                if (externalControl) {
                    const bool stopped = requestManualStop(
                        device,
                        profile,
                        trace,
                        "external_yield_for_native",
                        "yield-" + command.commandID,
                        "external"
                    );
                    externalControl = false;
                    if (!stopped) return 4;
                    // The Tiny acknowledges manual mode before the previous
                    // direct speed command has physically settled. Starting AI
                    // immediately after that ACK often remains in mode 0.
                    std::this_thread::sleep_for(std::chrono::milliseconds(350));
                } else if (!nativeTracking) {
                    // A retry after a failed/stopped handoff must re-establish
                    // the manual (AiWorkModeNone) state first. The device's AI
                    // state machine can wedge after a stop-while-tracking: a
                    // direct AiWorkModeHuman request is acknowledged (RM_RET_OK)
                    // but the camera stays in mode 0 forever. Cycling through
                    // None with a confirmed manual status resets it.
                    const bool manual = requestManualStop(
                        device,
                        profile,
                        trace,
                        "reinit_for_native",
                        "reinit-" + command.commandID,
                        "external"
                    );
                    if (!manual) return 4;
                    std::this_thread::sleep_for(std::chrono::milliseconds(350));
                }
                if (!nativeTracking) {
                    nativeTracking = requestNativeHumanTracking(
                        device,
                        profile,
                        trace,
                        command.commandID,
                        "cleanup-" + command.commandID,
                        command.nativeTarget,
                        nativeTrackingPolicy,
                        [&indicator, &command](const std::string &phase) {
                            indicator.reassertAfterCameraModeTransition(
                                "indicator-" + phase + "-" + command.commandID
                            );
                        }
                    );
                    nativeCommandID = nativeTracking ? command.commandID : "";
                } else if (command.commandID != nativeCommandID) {
                    trace.event("camera.ack", "fault", "owner_busy", RM_RET_ERR, "native_tracking_already_active", command.commandID);
                }
                lastHeartbeat = Clock::now();
                break;
            case BridgeCommandType::heartbeat:
                if (nativeTracking && command.commandID == nativeCommandID) {
                    lastHeartbeat = Clock::now();
                } else {
                    trace.event("camera.ack", "fault", "heartbeat_rejected", RM_RET_ERR, "no_matching_native_command", command.commandID);
                }
                break;
            case BridgeCommandType::externalVelocity:
            case BridgeCommandType::externalPosition:
            case BridgeCommandType::externalPulse:
                {
                const bool isPermittedCalibrationPulse = calibrationMode
                    && capabilities.boundedCalibrationPulses
                    && command.type == BridgeCommandType::externalPulse
                    && std::abs(command.pitch) <= 25
                    && std::abs(command.pan) <= 18
                    && command.durationMilliseconds <= 180;
                if (!capabilities.calibratedMotorControl
                    && !permitsProfileCalibratedMotion
                    && !isPermittedCalibrationPulse) {
                    trace.event("camera.ack", "manual", "motion_calibration_required", RM_RET_ERR, "profile=" + std::string(capabilities.identifier), command.commandID);
                    break;
                }
                if (nativeTracking) {
                    const bool stopped = requestManualStop(
                        device,
                        profile,
                        trace,
                        "native_yield_for_external",
                        "yield-" + command.commandID
                    );
                    nativeTracking = false;
                    nativeCommandID.clear();
                    if (!stopped) return 4;
                }
                // Direct-speed commands are setpoints, not pulses.  The
                // runtime refreshes its watchdog every perception cycle, but
                // reissuing an identical setpoint asks the device to restart
                // the same synchronous command.  Keep the transport lease
                // fresh without adding motion latency or controller jitter.
                if (command.type == BridgeCommandType::externalVelocity
                    && externalControl
                    && appliedExternalVelocity
                    && appliedExternalVelocity->matches(command)) {
                    lastExternalCommand = Clock::now();
                    externalPulseDeadline.reset();
                    externalPulseStopCommandID.clear();
                    break;
                }
                externalControl = command.type == BridgeCommandType::externalPosition
                    ? requestExternalPosition(
                        device,
                        profile,
                        trace,
                        command.commandID,
                        command.pitch,
                        command.pan,
                        externalControl
                    )
                    : requestExternalVelocity(
                        device,
                        profile,
                        trace,
                        capabilities,
                        command.commandID,
                        command.pitch,
                        command.pan,
                        externalControl
                    );
                if (!externalControl) return 4;
                lastExternalCommand = Clock::now();
                if (command.type == BridgeCommandType::externalPulse) {
                    appliedExternalVelocity.reset();
                    externalPulseDeadline = lastExternalCommand + std::chrono::milliseconds(command.durationMilliseconds);
                    externalPulseStopCommandID = "pulse-stop-" + command.commandID;
                } else {
                    appliedExternalVelocity = command.type == BridgeCommandType::externalVelocity
                        ? std::optional<ExternalVelocity>(ExternalVelocity {command.pitch, command.pan})
                        : std::nullopt;
                    externalPulseDeadline.reset();
                    externalPulseStopCommandID.clear();
                }
                break;
                }
            case BridgeCommandType::cameraZoom:
                if (!setCameraOpticalZoom(device, trace, command.zoom, command.commandID)) {
                    trace.event(
                        "camera.capability",
                        "firmware",
                        "optical_zoom_rejected",
                        RM_RET_ERR,
                        "profile=" + std::string(capabilities.identifier),
                        command.commandID
                    );
                }
                break;
            case BridgeCommandType::audioMode:
                setCameraAudioMode(device, profile, trace, command.value, command.commandID);
                break;
            case BridgeCommandType::audioInputGain:
                setCameraAudioInputGain(device, profile, trace, command.value, command.commandID);
                break;
            case BridgeCommandType::cameraWhiteBalance:
                setCameraWhiteBalance(
                    device,
                    trace,
                    command.whiteBalanceAutomatic,
                    command.temperatureKelvin,
                    command.commandID
                );
                break;
            case BridgeCommandType::cameraExposureLock:
                setCameraExposureLock(device, trace, command.exposureLocked, command.commandID);
                break;
            case BridgeCommandType::cameraFocus:
                setCameraFocus(
                    device,
                    trace,
                    command.focusAutomatic,
                    command.focusPosition,
                    command.commandID
                );
                break;
            case BridgeCommandType::cameraAbsoluteExposure:
                setCameraAbsoluteExposure(
                    device,
                    trace,
                    command.absoluteExposureAutomatic,
                    command.absoluteExposureShutterCode,
                    command.commandID
                );
                break;
            case BridgeCommandType::cameraFacePriority:
                setCameraFacePriority(device, trace, command.facePriorityEnabled, command.commandID);
                break;
            case BridgeCommandType::cameraAntiFlicker:
                setCameraAntiFlicker(device, trace, command.antiFlickerMode, command.commandID);
                break;
            case BridgeCommandType::cameraImageTuning:
                setCameraImageTuning(device, trace, command.imageTuning, command.commandID);
                break;
            case BridgeCommandType::nativeHumanTrackingPolicy:
                if (profile != DiscoveryResult::Profile::tiny3Lite) {
                    trace.event(
                        "camera.ack",
                        "fault",
                        "native_tracking_policy_unsupported",
                        RM_RET_ERR,
                        "profile=" + std::string(capabilities.identifier),
                        command.commandID
                    );
                } else if (applyTiny3NativeHumanTrackingPolicy(
                    device,
                    trace,
                    command.nativeTrackingPolicy,
                    command.commandID
                )) {
                    nativeTrackingPolicy = command.nativeTrackingPolicy;
                }
                break;
            case BridgeCommandType::cameraFieldOfView:
                setCameraFieldOfView(device, trace, command.value, command.commandID);
                break;
            case BridgeCommandType::doaFollow:
                setDoaFindBack(device, trace, command.value == 1, command.commandID);
                break;
            case BridgeCommandType::externalVelocityOutOfRange:
                trace.event("camera.ack", "fault", "external_velocity_rejected", RM_RET_ERR, "external_velocity_out_of_range", command.commandID);
                break;
            case BridgeCommandType::externalPositionOutOfRange:
                trace.event("camera.ack", "fault", "external_position_rejected", RM_RET_ERR, "external_position_out_of_range", command.commandID);
                break;
            case BridgeCommandType::externalStop:
                if (externalControl) {
                    const bool stopped = requestManualStop(device, profile, trace, "external_attention_released", command.commandID, "external");
                    externalControl = false;
                    appliedExternalVelocity.reset();
                    externalPulseDeadline.reset();
                    externalPulseStopCommandID.clear();
                    if (!stopped) return 4;
                } else {
                    trace.event("camera.ack", "manual", "manual_active", RM_RET_OK, "already_manual", command.commandID);
                }
                break;
            case BridgeCommandType::manualStop:
                if (nativeTracking || externalControl) {
                    const std::string owner = externalControl ? "external" : "native_ai";
                    const bool stopped = requestManualStop(device, profile, trace, "attention_released", command.commandID, owner);
                    nativeTracking = false;
                    nativeCommandID.clear();
                    externalControl = false;
                    appliedExternalVelocity.reset();
                    externalPulseDeadline.reset();
                    externalPulseStopCommandID.clear();
                    if (!stopped) return 4;
                } else {
                    trace.event("camera.ack", "manual", "manual_active", RM_RET_OK, "already_manual", command.commandID);
                }
                break;
            case BridgeCommandType::recenter:
                if (!capabilities.calibratedMotorControl && !permitsProfileCalibratedMotion) {
                    trace.event("camera.ack", "manual", "motion_calibration_required", RM_RET_ERR, "profile=" + std::string(capabilities.identifier), command.commandID);
                    break;
                }
                if (nativeTracking || externalControl) {
                    const std::string owner = externalControl ? "external" : "native_ai";
                    const bool stopped = requestManualStop(device, profile, trace, "coverage_recenter", "yield-" + command.commandID, owner);
                    nativeTracking = false;
                    nativeCommandID.clear();
                    externalControl = false;
                    appliedExternalVelocity.reset();
                    externalPulseDeadline.reset();
                    externalPulseStopCommandID.clear();
                    if (!stopped) return 4;
                }
                if (!requestCenter(device, profile, trace, command.commandID)) return 4;
                break;
            case BridgeCommandType::indicatorSet:
                indicator.set(command.value, command.commandID);
                break;
            case BridgeCommandType::indicatorClear:
                indicator.clear(command.value, command.commandID);
                break;
            case BridgeCommandType::indicatorBrightness:
                indicator.setBrightness(command.value, command.commandID);
                break;
            case BridgeCommandType::indicatorEnabled:
                indicator.setEnabled(command.value == 1, command.commandID);
                break;
            case BridgeCommandType::indicatorEnforce:
                indicator.enforce(command.value, command.indicatorPattern, command.commandID);
                break;
            case BridgeCommandType::indicatorReconcile:
                indicator.reconcile(command.value, command.indicatorPattern, command.commandID);
                break;
            case BridgeCommandType::indicatorRGBEnforce:
                if (command.indicatorRGB) indicator.enforceRGB(*command.indicatorRGB, command.indicatorPattern, command.commandID);
                break;
            case BridgeCommandType::indicatorRGBReconcile:
                if (command.indicatorRGB) indicator.reconcileRGB(*command.indicatorRGB, command.indicatorPattern, command.commandID);
                break;
            case BridgeCommandType::indicatorRGBClear:
                indicator.clearRGB(command.commandID);
                break;
            case BridgeCommandType::shutdown:
                {
                    const std::string owner = externalControl ? "external" : "native_ai";
                    if (nativeTracking || externalControl) {
                        const bool stopped = requestManualStop(device, profile, trace, "bridge_shutdown", command.commandID, owner);
                        if (!stopped) {
                            trace.event(
                                "camera.ack",
                                "fault",
                                "shutdown_release_unconfirmed",
                                RM_RET_ERR,
                                "continuing_to_rest_pose=true",
                                command.commandID
                            );
                        }
                    } else {
                        trace.event("camera.ack", "manual", "manual_active", RM_RET_OK, "bridge_shutdown_manual", command.commandID);
                    }
                    return parkAtRestPoseAndSleep(device, trace, command.commandID) ? 0 : 4;
                }
            case BridgeCommandType::invalid:
                trace.event("camera.ack", "fault", "bridge_command_rejected", RM_RET_ERR, "invalid_local_command");
                break;
            }
        }

        if (externalControl && externalPulseDeadline && Clock::now() >= *externalPulseDeadline) {
            const bool stopped = requestManualStop(
                device,
                profile,
                trace,
                "external_pulse_elapsed",
                externalPulseStopCommandID,
                "external"
            );
            externalControl = false;
            appliedExternalVelocity.reset();
            externalPulseDeadline.reset();
            externalPulseStopCommandID.clear();
            if (!stopped) return 4;
        }
        indicator.tick(Clock::now());
        // Attitude reporting is owned by AttitudeReporter on its own thread;
        // the bridge loop must never gate the pose stream on its own latency.
        if (nativeTracking && Clock::now() - lastHeartbeat > nativeWatchdog) {
            const bool stopped = requestManualStop(device, profile, trace, "attention_watchdog_expired", "watchdog-stop-1");
            nativeTracking = false;
            nativeCommandID.clear();
            if (!stopped) return 4;
        }
        if (externalControl && Clock::now() - lastExternalCommand > externalWatchdog) {
            const bool stopped = requestManualStop(device, profile, trace, "external_watchdog_expired", "external-watchdog-stop-1", "external");
            externalControl = false;
            appliedExternalVelocity.reset();
            externalPulseDeadline.reset();
            externalPulseStopCommandID.clear();
            if (!stopped) return 4;
        }
    }

    if (nativeTracking || externalControl) {
        return requestManualStop(
            device,
            profile,
            trace,
            interrupted ? "signal_received" : continuous ? "bridge_input_closed" : "duration_elapsed",
            "manual-timebox-1",
            externalControl ? "external" : "native_ai"
        ) ? 0 : 4;
    }
    trace.event("camera.ack", "manual", "manual_active", RM_RET_OK, interrupted ? "signal_received_manual" : continuous ? "bridge_input_closed_manual" : "duration_elapsed_manual");
    return 0;
}

class EmergencyManualStopGuard {
public:
    EmergencyManualStopGuard(
        std::shared_ptr<Device> device,
        const DiscoveryResult::Profile profile,
        Trace &trace
    )
        : device_(std::move(device)), profile_(profile), trace_(trace) {}

    ~EmergencyManualStopGuard() {
        if (!armed_) return;
        requestManualStop(device_, profile_, trace_, "exceptional_exit", "manual-stop-1");
    }

    void disarm() {
        armed_ = false;
    }

private:
    std::shared_ptr<Device> device_;
    DiscoveryResult::Profile profile_;
    Trace &trace_;
    bool armed_ = true;
};

}  // namespace

int main(int argc, char **argv) {
    bool devicesWereOpened = false;
    try {
        std::signal(SIGINT, handleSignal);
        std::signal(SIGTERM, handleSignal);
        const Options options = parseOptions(argc, argv);
        if (options.list) {
            devicesWereOpened = true;
            const bool listed = listDevices();
            Devices::get().close();
            devicesWereOpened = false;
            return listed ? 0 : 2;
        }

        Trace trace(options.outputPath, options.traceMaximumBytes, options.traceRetainedFiles);
        trace.event("camera.owner", "manual", "discovering", 0, "motion_control_requested");
        devicesWereOpened = true;
        auto discovery = waitForSupportedDevice();
        if (!discovery.device) {
            trace.event(
                "camera.ack",
                "fault",
                discovery.interrupted ? "discovery_interrupted" : "device_unavailable",
                RM_RET_ERR,
                discovery.interrupted
                    ? "device control endpoint was not discovered"
                    : "No supported OBSBOT device was discovered within 10 seconds; connect_failure=" + discoveryFailure()
            );
            Devices::get().close();
            devicesWereOpened = false;
            return discovery.interrupted ? 130 : 2;
        }
        if (options.manualStop) {
            const bool stopped = requestManualStop(
                discovery.device,
                discovery.profile,
                trace,
                "explicit_manual_stop",
                "manual-stop-1",
                "manual"
            );
            // Release the final Device handle before closing the SDK singleton.
            // The Tiny 3 SDK's teardown thread may otherwise race a retained
            // `Device` destructor after an emergency manual stop.
            discovery.device.reset();
            Devices::get().close();
            devicesWereOpened = false;
            return stopped ? 0 : 4;
        }

        if (options.doaFindBack) {
            const bool supported = discovery.profile == DiscoveryResult::Profile::tiny3Lite;
            const bool configured = supported && setDoaFindBack(
                discovery.device,
                trace,
                *options.doaFindBack
            );
            if (!supported) {
                trace.event(
                    "audio.doa",
                    "manual",
                    "sound_source_tracking_unavailable",
                    RM_RET_ERR,
                    "profile=tiny_2_lite",
                    "doa-find-back-1"
                );
            }
            discovery.device.reset();
            Devices::get().close();
            devicesWereOpened = false;
            return configured ? 0 : 4;
        }

        const auto &device = discovery.device;
        EmergencyManualStopGuard emergencyStop(device, discovery.profile, trace);

        if (options.serve) {
            const int result = runBridgeServer(
                device,
                discovery.profile,
                trace,
                options.durationSeconds,
                options.allowDeviceCalibration,
                options.allowProfileCalibratedMotion
            );
            emergencyStop.disarm();
            Devices::get().close();
            devicesWereOpened = false;
            return result;
        }

        if (options.center) {
            if (!requestCenter(device, discovery.profile, trace, "center-1")) {
                emergencyStop.disarm();
                Devices::get().close();
                devicesWereOpened = false;
                return 4;
            }
            const auto deadline = Clock::now() + std::chrono::seconds(options.durationSeconds);
            while (Clock::now() < deadline && !interrupted) {
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
            const bool stopped = requestManualStop(
                device,
                discovery.profile,
                trace,
                interrupted ? "signal_received" : "center_complete",
                "center-stop-1",
                "manual"
            );
            emergencyStop.disarm();
            Devices::get().close();
            devicesWereOpened = false;
            return stopped ? 0 : 4;
        }

        const bool activated = requestNativeHumanTracking(
            device,
            discovery.profile,
            trace,
            "native-human-1",
            "manual-stop-1"
        );
        if (!activated) {
            emergencyStop.disarm();
            Devices::get().close();
            devicesWereOpened = false;
            return 4;
        }

        const auto deadline = Clock::now() + std::chrono::seconds(options.durationSeconds);
        while ((options.durationSeconds == 0 || Clock::now() < deadline) && !interrupted) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        const bool stopped = requestManualStop(
            device,
            discovery.profile,
            trace,
            interrupted ? "signal_received" : "duration_elapsed",
            "manual-stop-1"
        );
        emergencyStop.disarm();
        Devices::get().close();
        devicesWereOpened = false;
        return stopped ? 0 : 4;
    } catch (const std::exception &error) {
        if (devicesWereOpened) Devices::get().close();
        std::cerr << "soma-native-track: " << error.what() << '\n';
        return 1;
    }
}
