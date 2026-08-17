#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cctype>
#include <chrono>
#include <csignal>
#include <cmath>
#include <cstdlib>
#include <dlfcn.h>
#include <fstream>
#include <filesystem>
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

void handleSignal(int) {
    interrupted = true;
}

struct Options {
    bool allowMotion = false;
    bool list = false;
    bool serve = false;
    bool center = false;
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
        } else if (argument == "--list") {
            options.list = true;
        } else if (argument == "--serve") {
            options.serve = true;
        } else if (argument == "--center") {
            options.center = true;
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
            std::cout << "Usage: soma-native-track --list | --allow-camera-motion --duration <0=continuous|1-30> --output <trace.jsonl> [--trace-max-megabytes MB --trace-retained-files count] [--serve|--center]\n";
            std::exit(0);
        } else {
            throw std::runtime_error("Unknown argument: " + argument);
        }
    }
    if (options.durationSeconds < 0 || options.durationSeconds > 30) {
        throw std::runtime_error("--duration must be 0 (continuous) or between 1 and 30 seconds");
    }
    if (options.list && (options.serve || options.center)) {
        throw std::runtime_error("--list cannot be combined with a motion mode");
    }
    if (options.serve && options.center) {
        throw std::runtime_error("Choose either --serve or --center");
    }
    if (options.center && options.durationSeconds == 0) {
        throw std::runtime_error("--center requires a positive duration for the move to complete");
    }
    if (!options.list && !options.allowMotion) {
        throw std::runtime_error("--allow-camera-motion is required to enable native tracking");
    }
    if (!options.list && !options.durationSpecified) {
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
    bool interrupted;
};

DiscoveryResult waitForTiny2Lite() {
    auto &devices = Devices::get();
    prepareDiscovery(devices);
    const auto deadline = Clock::now() + std::chrono::seconds(10);
    while (Clock::now() < deadline) {
        if (interrupted) return {nullptr, true};
        const std::string serial = discoveredSerial();
        if (!serial.empty()) {
            const auto device = devices.getDevBySn(serial);
            if (device && device->productType() == ObsbotProdTiny2Lite) return {device, false};
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return {nullptr, false};
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

bool configureFixedCameraZoom(const std::shared_ptr<Device> &device, Trace &trace) noexcept {
    int autoZoomResult = RM_RET_ERR;
    int zoomResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { autoZoomResult = device->aiSetAiAutoZoomR(false); } catch (...) {}
        try { zoomResult = device->cameraSetZoomAbsoluteR(1.0f); } catch (...) {}
    }
    std::optional<float> zoom;
    const auto deadline = Clock::now() + std::chrono::milliseconds(1'500);
    while (Clock::now() < deadline && !interrupted) {
        zoom = cameraZoomFactor(device);
        if (zoom && std::abs(*zoom - 1.0f) <= 0.02f) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    const bool confirmed = zoomResult == RM_RET_OK && zoom && std::abs(*zoom - 1.0f) <= 0.02f;
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

void emitNativeTrackingState(const std::string &state, const std::string &commandID) noexcept;

bool requestManualStop(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    const std::string &reason,
    const std::string &commandID,
    const std::string &controllingOwner = "native_ai"
) noexcept {
    trace.event("camera.command", controllingOwner, "manual_sent", 0, reason, commandID);
    int stopResult = RM_RET_ERR;
    int stopMotionResult = RM_RET_ERR;
    bool deactivated = false;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { stopResult = device->cameraSetAiModeU(Device::AiWorkModeNone); } catch (...) {}
        try { stopMotionResult = device->aiSetGimbalStop(); } catch (...) {}
    }
    try { deactivated = waitForMode(device, Device::AiWorkModeNone, 2'000); } catch (...) {}
    try {
        trace.event(
            "camera.ack",
            deactivated ? "manual" : "fault",
            deactivated ? "manual_active" : "stop_unconfirmed",
            stopResult == RM_RET_OK && stopMotionResult == RM_RET_OK && deactivated ? RM_RET_OK : RM_RET_ERR,
            "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device)) + "; gimbal_stop_result=" + std::to_string(stopMotionResult),
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
    return stopResult == RM_RET_OK && stopMotionResult == RM_RET_OK && deactivated;
}

struct GimbalAttitude {
    double pitch;
    double pan;
    uint64_t monotonicNS;
};

std::optional<GimbalAttitude> readGimbalAttitude(const std::shared_ptr<Device> &device) noexcept {
    std::lock_guard<std::mutex> lock(sdkMutex);
    float xyz[3] = {};
    int result = RM_RET_ERR;
    try { result = device->gimbalGetAttitudeInfoR(xyz); } catch (...) {}
    if (result != RM_RET_OK || !std::isfinite(xyz[1]) || !std::isfinite(xyz[2])) return std::nullopt;
    mach_timebase_info_data_t timebase {};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return std::nullopt;
    const auto nanoseconds = static_cast<uint64_t>(
        (static_cast<__uint128_t>(mach_absolute_time()) * timebase.numer) / timebase.denom
    );
    return GimbalAttitude {xyz[1], xyz[2], nanoseconds};
}

void emitGimbalAttitude(const GimbalAttitude &attitude) noexcept {
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_GIMBAL_ATTITUDE pitch=" << attitude.pitch
                  << " pan=" << attitude.pan
                  << " monotonic_ns=" << attitude.monotonicNS << "\n" << std::flush;
    } catch (...) {}
}

void emitHorizontalFieldOfView(int degrees) noexcept {
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_GIMBAL_FOV degrees=" << degrees << "\n" << std::flush;
    } catch (...) {}
}

void emitNativeTrackingState(const std::string &state, const std::string &commandID) noexcept {
    try {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_NATIVE_TRACKING state=" << state
                  << " command_id=" << commandID << "\n" << std::flush;
    } catch (...) {}
}

bool requestExternalVelocity(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    const std::string &commandID,
    double pitch,
    double pan,
    bool alreadyExternal
) noexcept {
    if (!std::isfinite(pitch) || !std::isfinite(pan) || std::abs(pitch) > 90 || std::abs(pan) > 180) {
        trace.event("camera.ack", "fault", "external_velocity_rejected", RM_RET_ERR, "external_velocity_out_of_range", commandID);
        return false;
    }
    const auto attitude = readGimbalAttitude(device);
    if (attitude) {
        emitGimbalAttitude(*attitude);
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
        int aiResult = RM_RET_ERR;
        bool manual = false;
        {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try { aiResult = device->cameraSetAiModeU(Device::AiWorkModeNone); } catch (...) {}
        }
        try { manual = waitForMode(device, Device::AiWorkModeNone, 2'000); } catch (...) {}
        if (aiResult != RM_RET_OK || !manual) {
            trace.event("camera.ack", "fault", "external_acquire_unconfirmed", RM_RET_ERR, "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device)), commandID);
            requestManualStop(device, trace, "external_acquire_failed", "cleanup-" + commandID, "external");
            return false;
        }
    }
    int speedResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { speedResult = device->aiSetGimbalSpeedCtrlR(pitch, pan); } catch (...) {}
    }
    trace.event(
        "camera.ack",
        speedResult == RM_RET_OK ? "external" : "fault",
        speedResult == RM_RET_OK ? "external_active" : "external_speed_rejected",
        speedResult,
        "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device))
            + (attitude
                ? "; pitch_degrees=" + std::to_string(attitude->pitch) + "; pan_degrees=" + std::to_string(attitude->pan)
                : "; attitude=unavailable"),
        commandID
    );
    if (speedResult != RM_RET_OK) requestManualStop(device, trace, "external_speed_rejected", "cleanup-" + commandID, "external");
    return speedResult == RM_RET_OK;
}

bool requestExternalPosition(
    const std::shared_ptr<Device> &device,
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
    const auto attitude = readGimbalAttitude(device);
    if (attitude) emitGimbalAttitude(*attitude);
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
        int aiResult = RM_RET_ERR;
        bool manual = false;
        {
            std::lock_guard<std::mutex> lock(sdkMutex);
            try { aiResult = device->cameraSetAiModeU(Device::AiWorkModeNone); } catch (...) {}
        }
        try { manual = waitForMode(device, Device::AiWorkModeNone, 2'000); } catch (...) {}
        if (aiResult != RM_RET_OK || !manual) {
            trace.event("camera.ack", "fault", "external_acquire_unconfirmed", RM_RET_ERR, "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device)), commandID);
            requestManualStop(device, trace, "external_acquire_failed", "cleanup-" + commandID, "external");
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
        "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device))
            + (attitude
                ? "; pitch_degrees=" + std::to_string(attitude->pitch) + "; pan_degrees=" + std::to_string(attitude->pan)
                : "; attitude=unavailable"),
        commandID
    );
    if (positionResult != RM_RET_OK) requestManualStop(device, trace, "external_position_rejected", "cleanup-" + commandID, "external");
    return positionResult == RM_RET_OK;
}

bool requestCenter(const std::shared_ptr<Device> &device, Trace &trace, const std::string &commandID) noexcept {
    trace.event("camera.command", "manual", "center_sent", 0, "pitch_degrees=0; yaw_degrees=0", commandID);
    int disableAIResult = RM_RET_ERR;
    int positionResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { disableAIResult = device->cameraSetAiModeU(Device::AiWorkModeNone); } catch (...) {}
        try { positionResult = device->gimbalSetSpeedPositionR(0, 0, 0, 0, 60, 90); } catch (...) {}
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

bool requestNativeHumanTracking(
    const std::shared_ptr<Device> &device,
    Trace &trace,
    const std::string &commandID,
    const std::string &cleanupCommandID
) noexcept {
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
        requestManualStop(device, trace, "start_rejected", cleanupCommandID);
        emitNativeTrackingState("inactive", commandID);
        return false;
    }
    int trackingModeResult = RM_RET_ERR;
    {
        std::lock_guard<std::mutex> lock(sdkMutex);
        try { trackingModeResult = device->aiSetTrackingModeR(Device::AiVTrackMotion); } catch (...) {}
    }
    bool activated = false;
    try { activated = waitForMode(device, Device::AiWorkModeHuman, 2'000); } catch (...) {}
    const int confirmedTrackingMode = verticalTrackingMode(device).value_or(-1);
    trace.event(
        "camera.ack",
        activated ? "native_ai" : "fault",
        activated ? "human_normal_active" : "start_unconfirmed",
        activated ? RM_RET_OK : RM_RET_ERR,
        "camera_status_ai_mode=" + std::to_string(cameraStatusMode(device))
            + "; tracking_mode_set_result=" + std::to_string(trackingModeResult)
            + "; camera_status_vertical_tracking_mode=" + std::to_string(confirmedTrackingMode),
        commandID
    );
    if (!activated) {
        requestManualStop(device, trace, "start_acknowledgement_timed_out", cleanupCommandID);
        emitNativeTrackingState("inactive", commandID);
    } else {
        emitNativeTrackingState("active", commandID);
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
    manualStop,
    recenter,
    indicatorSet,
    indicatorClear,
    indicatorBrightness,
    indicatorEnabled,
    indicatorSpecialPattern,
    indicatorEnforce,
    indicatorReconcile,
    shutdown,
    invalid
};

struct BridgeCommand {
    BridgeCommandType type = BridgeCommandType::invalid;
    std::string commandID;
    double pitch = 0;
    double pan = 0;
    int durationMilliseconds = 0;
    int value = 0;
    bool specialPatternEnabled = false;
};

bool validCommandID(const std::string &value) {
    return !value.empty()
        && value.size() <= 64
        && std::all_of(value.begin(), value.end(), [](unsigned char character) {
            return std::isalnum(character) || character == '-' || character == '_';
        });
}

bool validIndicatorStateID(int stateID) {
    return stateID == 16 || stateID == 17 || stateID == 18
        || stateID == 54 || stateID == 57;
}

BridgeCommand parseBridgeCommand(const std::string &line) {
    std::istringstream input(line);
    std::string verb;
    std::string commandID;
    std::string extra;
    if (!(input >> verb >> commandID) || !validCommandID(commandID)) return {};
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
    if (verb == "indicator_set" || verb == "indicator_clear") {
        int stateID = -1;
        if (!(input >> stateID) || (input >> extra)) return {};
        // These are non-error firmware palette entries verified on Tiny 2
        // Lite. Raw state IDs are deliberately not a general command surface.
        if (!validIndicatorStateID(stateID)) return {};
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
    if (verb == "indicator_special_pattern") {
        int enabled = -1;
        if (!(input >> enabled) || (input >> extra) || (enabled != 0 && enabled != 1)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::indicatorSpecialPattern;
        command.commandID = commandID;
        command.value = enabled;
        return command;
    }
    if (verb == "indicator_enforce") {
        int stateID = -1;
        int specialPatternEnabled = -1;
        if (!(input >> stateID >> specialPatternEnabled) || (input >> extra)
            || (specialPatternEnabled != 0 && specialPatternEnabled != 1)) return {};
        if (!validIndicatorStateID(stateID)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::indicatorEnforce;
        command.commandID = commandID;
        command.value = stateID;
        command.specialPatternEnabled = specialPatternEnabled == 1;
        return command;
    }
    if (verb == "indicator_reconcile") {
        int stateID = -1;
        int specialPatternEnabled = -1;
        if (!(input >> stateID >> specialPatternEnabled) || (input >> extra)
            || !validIndicatorStateID(stateID)
            || (specialPatternEnabled != 0 && specialPatternEnabled != 1)) return {};
        BridgeCommand command;
        command.type = BridgeCommandType::indicatorReconcile;
        command.commandID = commandID;
        command.value = stateID;
        command.specialPatternEnabled = specialPatternEnabled == 1;
        return command;
    }
    if (input >> extra) return {};
    if (verb == "native_start") return {BridgeCommandType::nativeStart, commandID};
    if (verb == "heartbeat") return {BridgeCommandType::heartbeat, commandID};
    if (verb == "external_stop") return {BridgeCommandType::externalStop, commandID};
    if (verb == "manual_stop") return {BridgeCommandType::manualStop, commandID};
    if (verb == "recenter") return {BridgeCommandType::recenter, commandID};
    if (verb == "shutdown") return {BridgeCommandType::shutdown, commandID};
    return {};
}

class IndicatorSession {
public:
    IndicatorSession(std::shared_ptr<Device> device, Trace &trace)
        : device_(std::move(device)), trace_(trace) {
        readBaseline();
        clearResidualPalette();
    }

    ~IndicatorSession() {
        restore();
    }

    void set(int stateID, const std::string &commandID) noexcept {
        trace_.event("indicator.command", "soma", "set_state", 0, "state_id=" + std::to_string(stateID), commandID);
        int result = RM_RET_ERR;
        try { result = device_->sysMgSetIndicatorStateR(static_cast<uint8_t>(stateID)); } catch (...) {}
        if (result == RM_RET_OK) activeStates_.insert(stateID);
        trace_.event(
            "indicator.ack",
            result == RM_RET_OK ? "soma" : "fault",
            result == RM_RET_OK ? "state_active" : "state_rejected",
            result,
            "state_id=" + std::to_string(stateID),
            commandID
        );
    }

    void clear(int stateID, const std::string &commandID) noexcept {
        trace_.event("indicator.command", "soma", "clear_state", 0, "state_id=" + std::to_string(stateID), commandID);
        int result = RM_RET_ERR;
        try { result = device_->sysMgClearIndicatorStateR(static_cast<uint8_t>(stateID)); } catch (...) {}
        if (result == RM_RET_OK) activeStates_.erase(stateID);
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
        trace_.event("indicator.command", "soma", "set_brightness", 0, "brightness=" + std::to_string(brightness), commandID);
        const int result = callSetBrightness(static_cast<uint8_t>(brightness));
        if (result == RM_RET_OK) brightnessChanged_ = true;
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
        trace_.event(
            "indicator.command",
            "soma",
            "set_enabled",
            0,
            std::string("enabled=") + (enabled ? "true" : "false"),
            commandID
        );
        const int result = callSetEnabled(enabled);
        if (result == RM_RET_OK) enabledChanged_ = true;
        trace_.event(
            "indicator.ack",
            result == RM_RET_OK ? "soma" : "fault",
            result == RM_RET_OK ? "enabled_active" : "enabled_rejected",
            result,
            std::string("enabled=") + (enabled ? "true" : "false"),
            commandID
        );
    }

    void setSpecialPattern(bool enabled, const std::string &commandID) noexcept {
        trace_.event(
            "indicator.command",
            "soma",
            "set_special_pattern",
            0,
            std::string("enabled=") + (enabled ? "true" : "false"),
            commandID
        );
        int result = RM_RET_ERR;
        try { result = device_->cameraSetLedCtrlU(enabled); } catch (...) {}
        specialPatternActive_ = enabled;
        trace_.event(
            "indicator.ack",
            result == RM_RET_OK ? "soma" : "fault",
            result == RM_RET_OK ? "special_pattern_updated" : "special_pattern_rejected",
            result,
            std::string("enabled=") + (enabled ? "true" : "false"),
            commandID
        );
    }

    void enforce(int stateID, bool specialPatternEnabled, const std::string &commandID) noexcept {
        trace_.event(
            "indicator.command",
            "soma",
            "enforce_palette",
            0,
            "target_state_id=" + std::to_string(stateID)
                + "; special_pattern=" + (specialPatternEnabled ? "true" : "false"),
            commandID
        );

        bool clearSucceeded = true;
        for (const int candidate : kPaletteStateIDs) {
            if (candidate == stateID) continue;
            int result = RM_RET_ERR;
            try { result = device_->sysMgClearIndicatorStateR(static_cast<uint8_t>(candidate)); } catch (...) {}
            clearSucceeded = clearSucceeded && result == RM_RET_OK;
            if (result == RM_RET_OK) activeStates_.erase(candidate);
        }

        int specialResult = RM_RET_ERR;
        try { specialResult = device_->cameraSetLedCtrlU(specialPatternEnabled); } catch (...) {}
        specialPatternActive_ = specialPatternEnabled;
        int setResult = RM_RET_ERR;
        try { setResult = device_->sysMgSetIndicatorStateR(static_cast<uint8_t>(stateID)); } catch (...) {}
        if (setResult == RM_RET_OK) activeStates_.insert(stateID);

        const bool succeeded = clearSucceeded && specialResult == RM_RET_OK && setResult == RM_RET_OK;
        trace_.event(
            "indicator.ack",
            succeeded ? "soma" : "fault",
            succeeded ? "palette_enforced" : "palette_enforcement_incomplete",
            succeeded ? RM_RET_OK : RM_RET_ERR,
            "target_state_id=" + std::to_string(stateID)
                + "; special_pattern=" + (specialPatternEnabled ? "true" : "false")
                + "; non_target_states_cleared=" + (clearSucceeded ? "true" : "false"),
            commandID
        );
    }

    void reconcile(int stateID, bool specialPatternEnabled, const std::string &commandID) noexcept {
        trace_.event(
            "indicator.command",
            "soma",
            "reconcile_palette",
            0,
            "target_state_id=" + std::to_string(stateID)
                + "; special_pattern=" + (specialPatternEnabled ? "true" : "false"),
            commandID
        );

        bool clearSucceeded = true;
        for (const int candidate : kPaletteStateIDs) {
            if (candidate == stateID) continue;
            int result = RM_RET_ERR;
            try { result = device_->sysMgClearIndicatorStateR(static_cast<uint8_t>(candidate)); } catch (...) {}
            clearSucceeded = clearSucceeded && result == RM_RET_OK;
            if (result == RM_RET_OK) activeStates_.erase(candidate);
        }

        // Recover the colour by clearing any wrong palette states and
        // re-asserting the target state id. But do NOT re-trigger the
        // special-pattern blink gate when it already equals the desired value:
        // re-calling cameraSetLedCtrlU(true) restarts the firmware blink
        // cadence and produces "one blink, long off-gap" instead of continuous
        // blinking. The blink gate is only (re)armed when its desired value
        // actually differs (a genuine colour/blink-mode transition).
        bool specialResultOK = true;
        if (specialPatternActive_ != specialPatternEnabled) {
            int specialResult = RM_RET_ERR;
            try { specialResult = device_->cameraSetLedCtrlU(specialPatternEnabled); } catch (...) {}
            specialResultOK = specialResult == RM_RET_OK;
            if (specialResult == RM_RET_OK) specialPatternActive_ = specialPatternEnabled;
        }
        int setResult = RM_RET_ERR;
        try { setResult = device_->sysMgSetIndicatorStateR(static_cast<uint8_t>(stateID)); } catch (...) {}
        if (setResult == RM_RET_OK) activeStates_.insert(stateID);
        const bool succeeded = clearSucceeded && specialResultOK && setResult == RM_RET_OK;

        trace_.event(
            "indicator.ack",
            succeeded ? "soma" : "fault",
            succeeded ? "palette_reasserted" : "palette_reassertion_incomplete",
            succeeded ? RM_RET_OK : RM_RET_ERR,
            "target_state_id=" + std::to_string(stateID)
                + "; special_pattern=" + (specialPatternEnabled ? "true" : "false")
                + "; non_target_states_cleared=" + (clearSucceeded ? "true" : "false"),
            commandID
        );
    }

    void restore() noexcept {
        if (restored_) return;
        restored_ = true;
        bool clearSucceeded = true;
        for (const int stateID : activeStates_) {
            int result = RM_RET_ERR;
            try { result = device_->sysMgClearIndicatorStateR(static_cast<uint8_t>(stateID)); } catch (...) {}
            clearSucceeded = clearSucceeded && result == RM_RET_OK;
        }
        activeStates_.clear();
        bool globalsSucceeded = true;
        if (brightnessChanged_ && baselineBrightness_) {
            globalsSucceeded = callSetBrightness(*baselineBrightness_) == RM_RET_OK && globalsSucceeded;
        }
        if (enabledChanged_ && baselineEnabled_) {
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
    static constexpr int kPaletteStateIDs[] = {16, 17, 18, 54, 57};

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
        const int enabledResult = getEnabled ? getEnabled(device_.get(), enabled) : RM_RET_ERR;
        const int brightnessResult = getBrightness ? getBrightness(device_.get(), brightness) : RM_RET_ERR;
        if (enabledResult == RM_RET_OK) baselineEnabled_ = enabled;
        if (brightnessResult == RM_RET_OK) baselineBrightness_ = brightness;
        trace_.event(
            "indicator.capability",
            "firmware",
            "rgb_palette_available",
            enabledResult == RM_RET_OK && brightnessResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
            "arbitrary_rgb=false; enabled="
                + (baselineEnabled_ ? (*baselineEnabled_ ? std::string("true") : std::string("false")) : std::string("unavailable"))
                + "; brightness="
                + (baselineBrightness_ ? std::to_string(*baselineBrightness_) : std::string("unavailable"))
        );
    }

    // Indicator states live in device firmware, not in this helper process.
    // A helper restart after a forced service restart therefore cannot infer
    // which of the limited palette states the prior process left active.
    // Clear the whole supported palette once before accepting commands so each
    // subsequent rendering has exactly one firmware state as its owner.
    void clearResidualPalette() noexcept {
        bool cleared = true;
        for (const int stateID : kPaletteStateIDs) {
            int result = RM_RET_ERR;
            try { result = device_->sysMgClearIndicatorStateR(static_cast<uint8_t>(stateID)); } catch (...) {}
            cleared = cleared && result == RM_RET_OK;
        }
        int specialResult = RM_RET_ERR;
        try { specialResult = device_->cameraSetLedCtrlU(false); } catch (...) {}
        specialPatternActive_ = false;
        trace_.event(
            "indicator.ack",
            cleared && specialResult == RM_RET_OK ? "firmware" : "fault",
            cleared && specialResult == RM_RET_OK ? "palette_reset" : "palette_reset_incomplete",
            cleared && specialResult == RM_RET_OK ? RM_RET_OK : RM_RET_ERR,
            std::string("states=16,17,18,54,57; special_pattern=false")
        );
    }


    int callSetEnabled(bool enabled) noexcept {
        const auto function = symbol<SetEnabled>("_ZN6Device19sysMgSetLedEnabledREb");
        if (!function) return RM_RET_ERR;
        try { return function(device_.get(), enabled); } catch (...) { return RM_RET_ERR; }
    }

    int callSetBrightness(uint8_t brightness) noexcept {
        const auto function = symbol<SetBrightness>("_ZN6Device22sysMgSetLedBrightnessREh");
        if (!function) return RM_RET_ERR;
        try { return function(device_.get(), brightness); } catch (...) { return RM_RET_ERR; }
    }

    std::shared_ptr<Device> device_;
    Trace &trace_;
    std::set<int> activeStates_;
    // Desired special-pattern (blink gate) state, used so the periodic reconcile
    // re-asserts the colour (state id) without re-triggering an already-running
    // blink cadence: re-calling cameraSetLedCtrlU(true) restarts the firmware
    // blink and yields "one blink, long off-gap" instead of continuous blinking.
    bool specialPatternActive_ = false;
    std::optional<bool> baselineEnabled_;
    std::optional<uint8_t> baselineBrightness_;
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
        while (!stop_) {
            if (const auto attitude = readGimbalAttitude(device_)) emitGimbalAttitude(*attitude);
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }

    std::shared_ptr<Device> device_;
    std::atomic_bool stop_ = false;
    std::thread thread_;
};

int runBridgeServer(const std::shared_ptr<Device> &device, Trace &trace, int durationSeconds) {
    constexpr auto nativeWatchdog = std::chrono::milliseconds(750);
    constexpr auto externalWatchdog = std::chrono::milliseconds(700);
    if (!configureFixedCameraZoom(device, trace)) return 5;
    disableHandGestures(device, trace);
    if (const auto fieldOfView = cameraHorizontalFieldOfViewDegrees(device)) emitHorizontalFieldOfView(*fieldOfView);
    if (const auto attitude = readGimbalAttitude(device)) emitGimbalAttitude(*attitude);
    IndicatorSession indicator(device, trace);
    trace.event("camera.owner", "manual", "bridge_ready", RM_RET_OK, "awaiting_local_attention_commands");
    {
        std::lock_guard<std::mutex> lock(stderrMutex);
        std::cerr << "SOMA_NATIVE_BRIDGE_READY\n" << std::flush;
    }
    // Start the pose reporter after the one-shot startup reads so the first
    // sample is not duplicated; it runs until this function returns.
    AttitudeReporter attitudeReporter(device);
    bool nativeTracking = false;
    std::string nativeCommandID;
    auto lastHeartbeat = Clock::now();
    bool externalControl = false;
    auto lastExternalCommand = Clock::now();
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
        const int polled = ::poll(&descriptor, 1, pollTimeoutMilliseconds);
        if (polled > 0 && (descriptor.revents & POLLIN)) {
            const auto line = readBridgeLine();
            if (!line) break;
            BridgeCommand command = parseBridgeCommand(*line);
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
                    const BridgeCommand newer = parseBridgeCommand(*newerLine);
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
                }
                if (!nativeTracking) {
                    nativeTracking = requestNativeHumanTracking(
                        device,
                        trace,
                        command.commandID,
                        "cleanup-" + command.commandID
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
                if (nativeTracking) {
                    const bool stopped = requestManualStop(
                        device,
                        trace,
                        "native_yield_for_external",
                        "yield-" + command.commandID
                    );
                    nativeTracking = false;
                    nativeCommandID.clear();
                    if (!stopped) return 4;
                }
                externalControl = command.type == BridgeCommandType::externalPosition
                    ? requestExternalPosition(
                        device,
                        trace,
                        command.commandID,
                        command.pitch,
                        command.pan,
                        externalControl
                    )
                    : requestExternalVelocity(
                        device,
                        trace,
                        command.commandID,
                        command.pitch,
                        command.pan,
                        externalControl
                    );
                if (!externalControl) return 4;
                lastExternalCommand = Clock::now();
                if (command.type == BridgeCommandType::externalPulse) {
                    externalPulseDeadline = lastExternalCommand + std::chrono::milliseconds(command.durationMilliseconds);
                    externalPulseStopCommandID = "pulse-stop-" + command.commandID;
                } else {
                    externalPulseDeadline.reset();
                    externalPulseStopCommandID.clear();
                }
                break;
            case BridgeCommandType::externalVelocityOutOfRange:
                trace.event("camera.ack", "fault", "external_velocity_rejected", RM_RET_ERR, "external_velocity_out_of_range", command.commandID);
                break;
            case BridgeCommandType::externalPositionOutOfRange:
                trace.event("camera.ack", "fault", "external_position_rejected", RM_RET_ERR, "external_position_out_of_range", command.commandID);
                break;
            case BridgeCommandType::externalStop:
                if (externalControl) {
                    const bool stopped = requestManualStop(device, trace, "external_attention_released", command.commandID, "external");
                    externalControl = false;
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
                    const bool stopped = requestManualStop(device, trace, "attention_released", command.commandID, owner);
                    nativeTracking = false;
                    nativeCommandID.clear();
                    externalControl = false;
                    externalPulseDeadline.reset();
                    externalPulseStopCommandID.clear();
                    if (!stopped) return 4;
                } else {
                    trace.event("camera.ack", "manual", "manual_active", RM_RET_OK, "already_manual", command.commandID);
                }
                break;
            case BridgeCommandType::recenter:
                if (nativeTracking || externalControl) {
                    const std::string owner = externalControl ? "external" : "native_ai";
                    const bool stopped = requestManualStop(device, trace, "coverage_recenter", "yield-" + command.commandID, owner);
                    nativeTracking = false;
                    nativeCommandID.clear();
                    externalControl = false;
                    externalPulseDeadline.reset();
                    externalPulseStopCommandID.clear();
                    if (!stopped) return 4;
                }
                if (!requestCenter(device, trace, command.commandID)) return 4;
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
            case BridgeCommandType::indicatorSpecialPattern:
                indicator.setSpecialPattern(command.value == 1, command.commandID);
                break;
            case BridgeCommandType::indicatorEnforce:
                indicator.enforce(command.value, command.specialPatternEnabled, command.commandID);
                break;
            case BridgeCommandType::indicatorReconcile:
                indicator.reconcile(command.value, command.specialPatternEnabled, command.commandID);
                break;
            case BridgeCommandType::shutdown:
                {
                    const std::string owner = externalControl ? "external" : "native_ai";
                    if (nativeTracking || externalControl) {
                        const bool stopped = requestManualStop(device, trace, "bridge_shutdown", command.commandID, owner);
                        if (!stopped) return 4;
                    } else {
                        trace.event("camera.ack", "manual", "manual_active", RM_RET_OK, "bridge_shutdown_manual", command.commandID);
                    }
                    // Park the gimbal at center before sleeping so the camera
                    // rests in a neutral pose instead of freezing wherever it
                    // was last looking. The move is bounded: worst-case travel
                    // (pan +-120deg at 90deg/s, pitch +-90deg at 60deg/s) is
                    // ~1.5s, so a 4s deadline is generous.
                    int centerResult = RM_RET_ERR;
                    {
                        std::lock_guard<std::mutex> lock(sdkMutex);
                        try { centerResult = device->gimbalSetSpeedPositionR(0, 0, 0, 0, 60, 90); } catch (...) {}
                    }
                    if (centerResult == RM_RET_OK) {
                        trace.event("camera.command", "manual", "center_sent", 0, "shutdown_park; pitch_degrees=0; yaw_degrees=0", command.commandID);
                        const auto centerDeadline = Clock::now() + std::chrono::seconds(4);
                        while (Clock::now() < centerDeadline && !interrupted) {
                            std::this_thread::sleep_for(std::chrono::milliseconds(100));
                            const auto attitude = readGimbalAttitude(device);
                            if (attitude && std::abs(attitude->pitch) <= 1.5 && std::abs(attitude->pan) <= 1.5) break;
                        }
                    } else {
                        trace.event("camera.ack", "fault", "center_rejected", centerResult, "shutdown_park_rejected", command.commandID);
                    }
                    // Put the camera into sleep mode so it fully powers down its
                    // AI tracking rather than continuing to follow people after
                    // SOMA has been stopped.
                    int sleepResult = RM_RET_ERR;
                    {
                        std::lock_guard<std::mutex> lock(sdkMutex);
                        try {
                            sleepResult = device->cameraSetDevRunStatusR(Device::DevStatusSleep);
                        } catch (...) {}
                    }
                    trace.event(
                        "camera.ack",
                        sleepResult == RM_RET_OK ? "sleep" : "fault",
                        sleepResult == RM_RET_OK ? "sleep_requested" : "sleep_rejected",
                        sleepResult,
                        "bridge_shutdown_sleep",
                        command.commandID
                    );
                    return 0;
                }
            case BridgeCommandType::invalid:
                trace.event("camera.ack", "fault", "bridge_command_rejected", RM_RET_ERR, "invalid_local_command");
                break;
            }
        }

        if (externalControl && externalPulseDeadline && Clock::now() >= *externalPulseDeadline) {
            const bool stopped = requestManualStop(
                device,
                trace,
                "external_pulse_elapsed",
                externalPulseStopCommandID,
                "external"
            );
            externalControl = false;
            externalPulseDeadline.reset();
            externalPulseStopCommandID.clear();
            if (!stopped) return 4;
        }
        // Attitude reporting is owned by AttitudeReporter on its own thread;
        // the bridge loop must never gate the pose stream on its own latency.
        if (nativeTracking && Clock::now() - lastHeartbeat > nativeWatchdog) {
            const bool stopped = requestManualStop(device, trace, "attention_watchdog_expired", "watchdog-stop-1");
            nativeTracking = false;
            nativeCommandID.clear();
            if (!stopped) return 4;
        }
        if (externalControl && Clock::now() - lastExternalCommand > externalWatchdog) {
            const bool stopped = requestManualStop(device, trace, "external_watchdog_expired", "external-watchdog-stop-1", "external");
            externalControl = false;
            externalPulseDeadline.reset();
            externalPulseStopCommandID.clear();
            if (!stopped) return 4;
        }
    }

    if (nativeTracking || externalControl) {
        return requestManualStop(
            device,
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
    EmergencyManualStopGuard(std::shared_ptr<Device> device, Trace &trace)
        : device_(std::move(device)), trace_(trace) {}

    ~EmergencyManualStopGuard() {
        if (!armed_) return;
        requestManualStop(device_, trace_, "exceptional_exit", "manual-stop-1");
    }

    void disarm() {
        armed_ = false;
    }

private:
    std::shared_ptr<Device> device_;
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
        const auto discovery = waitForTiny2Lite();
        if (!discovery.device) {
            trace.event(
                "camera.ack",
                "fault",
                discovery.interrupted ? "discovery_interrupted" : "device_unavailable",
                RM_RET_ERR,
                discovery.interrupted
                    ? "device control endpoint was not discovered"
                    : "Tiny 2 Lite was not discovered within 10 seconds; connect_failure=" + discoveryFailure()
            );
            Devices::get().close();
            devicesWereOpened = false;
            return discovery.interrupted ? 130 : 2;
        }
        const auto &device = discovery.device;
        EmergencyManualStopGuard emergencyStop(device, trace);

        if (options.serve) {
            const int result = runBridgeServer(device, trace, options.durationSeconds);
            emergencyStop.disarm();
            Devices::get().close();
            devicesWereOpened = false;
            return result;
        }

        if (options.center) {
            if (!requestCenter(device, trace, "center-1")) {
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

        const bool activated = requestNativeHumanTracking(device, trace, "native-human-1", "manual-stop-1");
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
