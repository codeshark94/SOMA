#include "OpenOBSBOTContract.hpp"
#include "OpenOBSBOTUVCTransport.hpp"

#include <mach/mach_time.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
std::atomic_bool interrupted = false;

void handleSignal(int) noexcept { interrupted = true; }

uint64_t monotonicNanoseconds() noexcept {
    mach_timebase_info_data_t timebase {};
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.denom == 0) return 0;
    return static_cast<uint64_t>(
        (static_cast<__uint128_t>(mach_absolute_time()) * timebase.numer) / timebase.denom
    );
}

std::string jsonEscaped(const std::string &value) {
    std::ostringstream output;
    for (const unsigned char character : value) {
        switch (character) {
        case '"': output << "\\\""; break;
        case '\\': output << "\\\\"; break;
        case '\n': output << "\\n"; break;
        case '\r': output << "\\r"; break;
        case '\t': output << "\\t"; break;
        default:
            if (character < 0x20) {
                output << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                       << static_cast<int>(character) << std::dec;
            } else {
                output << character;
            }
        }
    }
    return output.str();
}

class Trace final {
public:
    Trace(std::string path, uint64_t maximumBytes, int retainedFiles)
        : basePath_(std::move(path)), maximumBytes_(maximumBytes), retainedFiles_(retainedFiles) {
        if (!basePath_.parent_path().empty()) {
            std::filesystem::create_directories(basePath_.parent_path());
        }
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
        int result,
        const std::string &message,
        const std::string &commandID = ""
    ) {
        std::ostringstream line;
        line << "{\"event\":\"" << jsonEscaped(event)
             << "\",\"monotonic_ns\":" << monotonicNanoseconds()
             << ",\"owner\":\"" << jsonEscaped(owner)
             << "\",\"state\":\"" << jsonEscaped(state)
             << "\",\"result_code\":" << result
             << ",\"message\":\"" << jsonEscaped(message) << "\"";
        if (!commandID.empty()) line << ",\"command_id\":\"" << jsonEscaped(commandID) << "\"";
        line << "}\n";
        const std::string encoded = line.str();
        if (maximumBytes_ > 0 && bytesWritten_ > 0
            && bytesWritten_ + encoded.size() > maximumBytes_) {
            stream_.close();
            open(segmentPath(++sequence_));
            prune();
        }
        stream_ << encoded << std::flush;
        bytesWritten_ += encoded.size();
    }

private:
    using Segment = std::pair<uint64_t, std::filesystem::path>;

    void open(const std::filesystem::path &path) {
        currentPath_ = path;
        stream_.open(path, std::ios::out | std::ios::trunc);
        if (!stream_) throw std::runtime_error("unable to open gimbal trace: " + path.string());
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
        const std::string prefix = basePath_.stem().string() + '-';
        const std::string extension = basePath_.extension().string();
        for (const auto &entry : std::filesystem::directory_iterator(directory)) {
            if (!entry.is_regular_file()) continue;
            const std::string filename = entry.path().filename().string();
            if (filename.size() <= prefix.size() + extension.size()
                || filename.compare(0, prefix.size(), prefix) != 0
                || filename.compare(filename.size() - extension.size(), extension.size(), extension) != 0) {
                continue;
            }
            const std::string rawSequence = filename.substr(
                prefix.size(),
                filename.size() - prefix.size() - extension.size()
            );
            if (rawSequence.empty()
                || !std::all_of(rawSequence.begin(), rawSequence.end(), [](unsigned char character) {
                    return std::isdigit(character) != 0;
                })) {
                continue;
            }
            try {
                segments.emplace_back(std::stoull(rawSequence), entry.path());
            } catch (...) {}
        }
        std::sort(segments.begin(), segments.end(), [](const Segment &left, const Segment &right) {
            return left.first < right.first;
        });
        return segments;
    }

    void prune() {
        const auto segments = matchingSegments();
        const size_t excess = segments.size() > static_cast<size_t>(retainedFiles_)
            ? segments.size() - static_cast<size_t>(retainedFiles_)
            : 0;
        for (size_t index = 0; index < excess; ++index) {
            std::error_code error;
            std::filesystem::remove(segments[index].second, error);
        }
    }

    std::filesystem::path basePath_;
    std::filesystem::path currentPath_;
    uint64_t maximumBytes_;
    int retainedFiles_;
    uint64_t sequence_ = 0;
    uint64_t bytesWritten_ = 0;
    std::ofstream stream_;
};

struct Options {
    bool serve = false;
    bool manualStop = false;
    bool center = false;
    bool parkSleep = false;
    bool allowMotion = false;
    int durationSeconds = 0;
    std::string outputPath;
    uint64_t traceMaximumBytes = 32 * 1024 * 1024;
    int traceRetainedFiles = 4;
};

Options parseOptions(int argc, char **argv) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        if (argument == "--serve") options.serve = true;
        else if (argument == "--manual-stop") options.manualStop = true;
        else if (argument == "--center") options.center = true;
        else if (argument == "--park-sleep") options.parkSleep = true;
        else if (argument == "--allow-camera-motion") options.allowMotion = true;
        else if (argument == "--allow-profile-calibrated-motion") {}
        else if (argument == "--duration" && index + 1 < argc) options.durationSeconds = std::stoi(argv[++index]);
        else if (argument == "--output" && index + 1 < argc) options.outputPath = argv[++index];
        else if (argument == "--trace-max-megabytes" && index + 1 < argc) {
            options.traceMaximumBytes = static_cast<uint64_t>(std::stoull(argv[++index])) * 1024 * 1024;
        } else if (argument == "--trace-retained-files" && index + 1 < argc) {
            options.traceRetainedFiles = std::stoi(argv[++index]);
        } else {
            throw std::runtime_error("unsupported open-bridge argument: " + argument);
        }
    }
    if (options.outputPath.empty()) throw std::runtime_error("--output is required");
    if (!options.allowMotion) throw std::runtime_error("--allow-camera-motion is required");
    if (options.traceRetainedFiles < 1 || options.traceRetainedFiles > 32) {
        throw std::runtime_error("trace retention must be 1...32");
    }
    return options;
}

std::vector<std::string> fields(const std::string &line) {
    std::istringstream stream(line);
    std::vector<std::string> values;
    for (std::string value; stream >> value;) values.push_back(value);
    return values;
}

struct IndicatorPhase {
    bool illuminated;
    int milliseconds;
};

std::vector<IndicatorPhase> phasesFor(const std::string &pattern) {
    if (pattern == "firmware_animation") return {{true, 150}, {false, 130}, {true, 150}, {false, 1270}};
    if (pattern == "beacon") return {{true, 180}, {false, 1320}};
    if (pattern == "doubleBlink") return {{true, 140}, {false, 110}, {true, 140}, {false, 610}};
    if (pattern == "longPulse") return {{true, 800}, {false, 200}};
    if (pattern == "heartbeat") return {{true, 300}, {false, 700}};
    if (pattern == "blink") return {{true, 400}, {false, 400}};
    return {{true, 0}};
}

class IndicatorPresenter final {
public:
    IndicatorPresenter(soma::OpenOBSBOTUVCTransport &transport, Trace &trace)
        : transport_(transport), trace_(trace), pulseWithEnable_(
            transport.profile() == soma::OBSBOTOpenDeviceProfile::tiny3Lite
        ) {}

    void setBrightness(int brightness, const std::string &commandID) {
        brightness_ = std::clamp(brightness, 0, 3);
        const int result = transport_.setIndicatorBrightness(static_cast<uint8_t>(brightness_));
        trace_.event("indicator.ack", "soma", result == 0 ? "brightness_set" : "brightness_rejected", result,
                     "brightness=" + std::to_string(brightness_) + "; transport=open_uvc_xu", commandID);
    }

    void setEnabled(bool enabled, const std::string &commandID) {
        enabled_ = enabled;
        const int result = transport_.setIndicatorEnabled(enabled);
        trace_.event("indicator.ack", "soma", result == 0 ? "enabled_set" : "enabled_rejected", result,
                     "enabled=" + std::string(enabled ? "true" : "false") + "; transport=open_uvc_xu", commandID);
    }

    void clear(int stateID, const std::string &commandID) {
        const int result = transport_.clearIndicatorState(static_cast<uint8_t>(stateID));
        if (desiredState_ == stateID) desiredState_.reset();
        phases_.clear();
        trace_.event("indicator.ack", "soma", result == 0 ? "state_cleared" : "state_clear_rejected", result,
                     "state_id=" + std::to_string(stateID) + "; transport=open_uvc_xu", commandID);
    }

    void present(int stateID, const std::string &pattern, const std::string &commandID, bool reconcile) {
        const auto nextPhases = phasesFor(pattern);
        const bool unchanged = desiredState_ == stateID && pattern_ == pattern;
        desiredState_ = stateID;
        pattern_ = pattern;
        phases_ = nextPhases;
        if (!reconcile || !unchanged) phaseIndex_ = 0;
        const int stateResult = transport_.setIndicatorState(static_cast<uint8_t>(stateID));
        const bool illuminated = phases_.empty() || phases_[phaseIndex_].illuminated;
        const int brightnessResult = applyIllumination(illuminated);
        schedulePhase();
        const int result = stateResult == 0 && brightnessResult == 0 ? 0 : -1;
        trace_.event("indicator.ack", "soma", result == 0 ? "presentation_submitted" : "presentation_rejected", result,
                     "state_id=" + std::to_string(stateID) + "; pattern=" + pattern
                         + "; transport=open_uvc_xu", commandID);
    }

    void tick() {
        if (!desiredState_ || phases_.size() <= 1 || Clock::now() < nextPhase_) return;
        phaseIndex_ = (phaseIndex_ + 1) % phases_.size();
        applyIllumination(phases_[phaseIndex_].illuminated);
        schedulePhase();
    }

private:
    void schedulePhase() {
        if (phases_.size() <= 1 || phases_[phaseIndex_].milliseconds <= 0) {
            nextPhase_ = Clock::time_point::max();
        } else {
            nextPhase_ = Clock::now() + std::chrono::milliseconds(phases_[phaseIndex_].milliseconds);
        }
    }

    int applyIllumination(bool illuminated) {
        if (pulseWithEnable_) {
            return transport_.setIndicatorEnabled(enabled_ && illuminated);
        }
        return transport_.setIndicatorBrightness(static_cast<uint8_t>(
            enabled_ && illuminated ? brightness_ : 0
        ));
    }

    soma::OpenOBSBOTUVCTransport &transport_;
    Trace &trace_;
    int brightness_ = 3;
    bool enabled_ = true;
    bool pulseWithEnable_ = false;
    std::optional<int> desiredState_;
    std::string pattern_ = "steady";
    std::vector<IndicatorPhase> phases_;
    size_t phaseIndex_ = 0;
    Clock::time_point nextPhase_ = Clock::time_point::max();
};

struct GimbalAttitude {
    double pitch;
    double pan;
};

std::optional<GimbalAttitude> emitAttitude(soma::OpenOBSBOTUVCTransport &transport) {
    double pitch = 0;
    double pan = 0;
    if (transport.readAttitude(pitch, pan) != 0) return std::nullopt;
    std::cerr << std::fixed << std::setprecision(3)
              << "SOMA_GIMBAL_ATTITUDE pitch=" << pitch
              << " pan=" << pan
              << " source=open_uvc_xu"
              << " monotonic_ns=" << monotonicNanoseconds() << '\n' << std::flush;
    return GimbalAttitude {pitch, pan};
}

void emitHome(double pitch, double pan) {
    std::cerr << std::fixed << std::setprecision(3)
              << "SOMA_GIMBAL_HOME pitch=" << pitch
              << " pan=" << pan
              << " source=open_uvc_xu"
              << " monotonic_ns=" << monotonicNanoseconds() << '\n' << std::flush;
}

bool wakeForSession(soma::OpenOBSBOTUVCTransport &transport, Trace &trace) {
    double initialPitch = 0;
    double initialPan = 0;
    const bool hasInitialPose = transport.readAttitude(initialPitch, initialPan) == 0;
    if (transport.setAwake(true) != 0) {
        trace.event("camera.ack", "fault", "wake_rejected", -1,
                    "transport=open_uvc_xu", "bridge-wake-1");
        return false;
    }

    const bool wakingFromRest = hasInitialPose
        && soma::open_obsbot_protocol::isRestPose(initialPitch);
    double finalPitch = initialPitch;
    double finalPan = initialPan;
    bool ready = !wakingFromRest;
    if (wakingFromRest) {
        const auto deadline = Clock::now() + std::chrono::seconds(6);
        int stableSamples = 0;
        while (Clock::now() < deadline && !interrupted) {
            if (transport.readAttitude(finalPitch, finalPan) == 0
                && soma::open_obsbot_protocol::isRunPose(finalPitch)) {
                ++stableSamples;
            } else {
                stableSamples = 0;
            }
            if (stableSamples >= 2) {
                ready = true;
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    } else if (!hasInitialPose) {
        ready = transport.readAttitude(finalPitch, finalPan) == 0;
    }
    if (ready) emitHome(finalPitch, finalPan);
    trace.event(
        "camera.ack",
        ready ? "manual" : "fault",
        ready ? "run_pose_ready" : "wake_pose_timeout",
        ready ? 0 : -1,
        "initial_pitch=" + (hasInitialPose ? std::to_string(initialPitch) : std::string("unavailable"))
            + "; initial_pan=" + (hasInitialPose ? std::to_string(initialPan) : std::string("unavailable"))
            + "; final_pitch=" + std::to_string(finalPitch)
            + "; final_pan=" + std::to_string(finalPan)
            + "; waited_for_rest_exit=" + (wakingFromRest ? "true" : "false")
            + "; transport=open_uvc_xu",
        "bridge-wake-1"
    );
    return ready;
}

void emitNativeTracking(const std::string &state, const std::string &commandID, const std::string &outcome) {
    std::cerr << "SOMA_NATIVE_TRACKING state=" << state
              << " command_id=" << commandID
              << " outcome=" << outcome << '\n' << std::flush;
}

bool parkAndSleep(soma::OpenOBSBOTUVCTransport &transport, Trace &trace, const std::string &commandID) {
    transport.disableHumanTracking();
    transport.stopMotion();
    const int centerResult = transport.center();
    const auto deadline = Clock::now() + std::chrono::seconds(5);
    bool arrived = false;
    while (centerResult == 0 && Clock::now() < deadline) {
        double pitch = 0;
        double pan = 0;
        if (transport.readAttitude(pitch, pan) == 0 && std::hypot(pitch, pan) <= 2.0) {
            arrived = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    const int sleepResult = arrived ? transport.setAwake(false) : -1;
    bool sleeping = false;
    const auto sleepDeadline = Clock::now() + std::chrono::seconds(5);
    while (sleepResult == 0 && Clock::now() < sleepDeadline) {
        double pitch = 0;
        double pan = 0;
        if (transport.readAttitude(pitch, pan) == 0
            && soma::open_obsbot_protocol::isRestPose(pitch)) {
            sleeping = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    trace.event("camera.ack", arrived && sleeping ? "manual" : "fault",
                arrived && sleeping ? "rest_pose_sleeping" : "rest_pose_timeout",
                arrived && sleeping ? 0 : -1,
                "center_result=" + std::to_string(centerResult)
                    + "; sleep_result=" + std::to_string(sleepResult)
                    + "; sleep_pose_verified=" + (sleeping ? "true" : "false")
                    + "; transport=open_uvc_xu", commandID);
    return arrived && sleeping;
}

int runServer(soma::OpenOBSBOTUVCTransport &transport, Trace &trace, const Options &options) {
    if (!wakeForSession(transport, trace)) return 4;
    const auto identity = transport.identity();
    const bool tiny3 = identity.profile == soma::OBSBOTOpenDeviceProfile::tiny3Lite;
    const std::string profileID = soma::openOBSBOTProfileID(identity.profile);
    if (tiny3) {
        const int readyResult = transport.setIndicatorState(3);
        const int idleResult = transport.setIndicatorState(54);
        trace.event(
            "indicator.ack",
            readyResult == 0 && idleResult == 0 ? "soma" : "fault",
            readyResult == 0 && idleResult == 0 ? "baseline_active" : "baseline_rejected",
            readyResult == 0 && idleResult == 0 ? 0 : -1,
            "persistent_state=3; work_state=54; profile=tiny_3_lite; transport=open_uvc_xu",
            "indicator-baseline-1"
        );
    }
    std::cerr << soma::openOBSBOTContractLine(identity) << '\n';
    std::cerr << "SOMA_GIMBAL_FOV degrees=" << (tiny3 ? 72.0 : 67.2) << "\n";
    emitAttitude(transport);
    std::cerr << "SOMA_NATIVE_BRIDGE_READY\n" << std::flush;
    trace.event("camera.owner", "manual", "bridge_ready", 0,
                "profile=" + profileID + "; control_transport=open_uvc_xu; compatibility=none");

    IndicatorPresenter indicator(transport, trace);
    bool nativeTracking = false;
    bool externalControl = false;
    struct PositionTarget {
        double pitch;
        double pan;
        std::string commandID;
        Clock::time_point deadline;
    };
    std::optional<PositionTarget> positionTarget;
    std::string nativeCommandID;
    auto lastHeartbeat = Clock::now();
    auto lastExternalCommand = Clock::now();
    auto nextAttitude = Clock::now();
    std::optional<Clock::time_point> pulseDeadline;
    const auto runtimeDeadline = options.durationSeconds > 0
        ? Clock::now() + std::chrono::seconds(options.durationSeconds)
        : Clock::time_point::max();

    while (!interrupted && Clock::now() < runtimeDeadline) {
        pollfd descriptor {STDIN_FILENO, POLLIN, 0};
        const int polled = ::poll(&descriptor, 1, 10);
        if (polled > 0 && (descriptor.revents & POLLIN)) {
            std::string line;
            if (!std::getline(std::cin, line)) break;
            const auto tokens = fields(line);
            if (tokens.size() < 2) {
                trace.event("camera.ack", "fault", "bridge_command_rejected", -1, "invalid_local_command");
                continue;
            }
            const std::string &verb = tokens[0];
            const std::string &commandID = tokens[1];
            try {
                if (verb == "heartbeat") {
                    if (nativeTracking && commandID == nativeCommandID) lastHeartbeat = Clock::now();
                } else if (verb == "native_start") {
                    if (externalControl) transport.stopMotion();
                    externalControl = false;
                    positionTarget.reset();
                    int result = transport.enableHumanTracking();
                    if (result == 0 && tiny3 && tokens.size() == 6) {
                        result = transport.selectHumanTrackingTarget(
                            std::stof(tokens[2]),
                            std::stof(tokens[3]),
                            std::stof(tokens[4]),
                            std::stof(tokens[5])
                        );
                    }
                    nativeTracking = result == 0;
                    nativeCommandID = nativeTracking ? commandID : "";
                    if (nativeTracking) lastHeartbeat = Clock::now();
                    emitNativeTracking(nativeTracking ? "accepted" : "inactive", commandID,
                                       nativeTracking ? "transport_accepted" : "start_rejected");
                    trace.event("camera.ack", nativeTracking ? "native_ai" : "fault",
                                nativeTracking ? "human_mode_submitted" : "start_rejected", result,
                                "profile=" + profileID
                                    + "; transport=open_uvc_xu; functional_verification=runtime_vision_attitude",
                                commandID);
                } else if ((verb == "external_velocity" || verb == "external_position" || verb == "external_pulse")
                           && tokens.size() >= (verb == "external_pulse" ? 5u : 4u)) {
                    if (nativeTracking) {
                        transport.disableHumanTracking();
                        nativeTracking = false;
                        emitNativeTracking("inactive", nativeCommandID, "external_yield");
                        nativeCommandID.clear();
                    }
                    const float pitch = std::stof(tokens[2]);
                    const float pan = std::stof(tokens[3]);
                    const bool validPosition = verb != "external_position"
                        || (std::abs(pitch) <= 90.0f && std::abs(pan) <= 120.0f);
                    const int result = !validPosition
                        ? -1
                        : (verb == "external_position" ? 0 : transport.setExternalVelocity(pitch, pan));
                    externalControl = result == 0;
                    lastExternalCommand = Clock::now();
                    if (verb == "external_position" && result == 0) {
                        positionTarget = PositionTarget {
                            pitch,
                            pan,
                            commandID,
                            lastExternalCommand + std::chrono::seconds(5),
                        };
                        pulseDeadline.reset();
                    } else if (verb == "external_pulse") {
                        positionTarget.reset();
                        pulseDeadline = lastExternalCommand + std::chrono::milliseconds(std::stoi(tokens[4]));
                    } else {
                        positionTarget.reset();
                        pulseDeadline.reset();
                    }
                    trace.event("camera.ack", result == 0 ? "external" : "fault",
                                result == 0
                                    ? (verb == "external_position" ? "external_position_active" : "external_active")
                                    : (validPosition ? "external_rejected" : "external_position_rejected"),
                                result,
                                "pitch=" + tokens[2] + "; pan=" + tokens[3] + "; transport=open_uvc_xu", commandID);
                } else if (verb == "external_stop" || verb == "manual_stop") {
                    const int trackingResult = transport.disableHumanTracking();
                    const int stopResult = transport.stopMotion();
                    nativeTracking = false;
                    externalControl = false;
                    positionTarget.reset();
                    pulseDeadline.reset();
                    emitNativeTracking("inactive", commandID, "manual");
                    trace.event("camera.ack", "manual", "manual_active",
                                trackingResult == 0 && stopResult == 0 ? 0 : -1,
                                "transport=open_uvc_xu", commandID);
                } else if (verb == "recenter") {
                    transport.disableHumanTracking();
                    transport.stopMotion();
                    nativeTracking = false;
                    externalControl = false;
                    positionTarget.reset();
                    const int result = transport.center();
                    trace.event("camera.ack", result == 0 ? "manual" : "fault",
                                result == 0 ? "center_accepted" : "center_rejected", result,
                                "transport=open_uvc_xu", commandID);
                } else if (verb == "camera_zoom" && tokens.size() == 3) {
                    const int result = transport.setZoomFactor(std::stod(tokens[2]));
                    trace.event("camera.ack", result == 0 ? "firmware" : "fault",
                                result == 0 ? "optical_zoom_active" : "optical_zoom_rejected", result,
                                "factor=" + tokens[2] + "; transport=open_uvc", commandID);
                } else if (verb == "audio_mode" && tokens.size() == 3) {
                    const int result = transport.setAudioMode(0, static_cast<uint8_t>(std::stoi(tokens[2])));
                    trace.event("audio.ack", result == 0 ? "firmware" : "fault",
                                result == 0 ? "audio_mode_submitted" : "audio_mode_rejected", result,
                                "mode=" + tokens[2] + "; profile=" + profileID + "; transport=open_uvc_xu",
                                commandID);
                } else if (verb == "audio_input_gain" && tokens.size() == 3) {
                    const int result = transport.setAudioInputGain(static_cast<int16_t>(std::stoi(tokens[2])));
                    trace.event("audio.ack", result == 0 ? "firmware" : "fault",
                                result == 0 ? "audio_input_gain_active" : "open_transport_operation_unavailable",
                                result, "gain=" + tokens[2] + "; profile=" + profileID, commandID);
                } else if (verb == "doa_follow" && tokens.size() == 3) {
                    const int result = transport.setSoundFollowing(tokens[2] == "1");
                    trace.event("audio.doa", result == 0 ? "firmware" : "fault",
                                result == 0 ? "sound_source_tracking_submitted" : "sound_source_tracking_rejected",
                                result, "enabled=" + tokens[2] + "; profile=" + profileID
                                    + "; transport=open_uvc_xu", commandID);
                } else if (verb == "indicator_enabled" && tokens.size() == 3) {
                    indicator.setEnabled(tokens[2] == "1", commandID);
                } else if (verb == "indicator_brightness" && tokens.size() == 3) {
                    indicator.setBrightness(std::stoi(tokens[2]), commandID);
                } else if (verb == "indicator_set" && tokens.size() == 3) {
                    indicator.present(std::stoi(tokens[2]), "steady", commandID, false);
                } else if (verb == "indicator_clear" && tokens.size() == 3) {
                    indicator.clear(std::stoi(tokens[2]), commandID);
                } else if ((verb == "indicator_enforce" || verb == "indicator_reconcile") && tokens.size() == 4) {
                    indicator.present(std::stoi(tokens[2]), tokens[3], commandID, verb == "indicator_reconcile");
                } else if (verb == "shutdown") {
                    return parkAndSleep(transport, trace, commandID) ? 0 : 4;
                } else if (verb == "camera_white_balance" || verb == "camera_ae_lock"
                           || verb == "camera_focus" || verb == "camera_absolute_exposure"
                           || verb == "camera_face_priority" || verb == "camera_anti_flicker"
                           || verb == "camera_image_tuning" || verb == "native_tracking_policy"
                           || verb == "camera_fov") {
                    trace.event("camera.capability", "firmware", "open_transport_operation_unavailable", -1,
                                "operation=" + verb + "; profile=" + profileID + "; no_fake_success=true",
                                commandID);
                } else {
                    trace.event("camera.ack", "fault", "bridge_command_rejected", -1,
                                "operation=" + verb + "; transport=open_uvc_xu", commandID);
                }
            } catch (...) {
                trace.event("camera.ack", "fault", "bridge_command_rejected", -1,
                            "malformed_operation=" + verb, commandID);
            }
        }

        const auto now = Clock::now();
        if (now >= nextAttitude) {
            const auto attitude = emitAttitude(transport);
            if (positionTarget && now >= positionTarget->deadline) {
                transport.stopMotion();
                trace.event(
                    "camera.ack", "fault", "external_position_timeout", -1,
                    "transport=open_uvc_feedback", positionTarget->commandID
                );
                positionTarget.reset();
                externalControl = false;
            } else if (positionTarget && attitude) {
                const double pitchError = positionTarget->pitch - attitude->pitch;
                const double panError = positionTarget->pan - attitude->pan;
                if (std::hypot(pitchError, panError) <= 0.35) {
                    transport.stopMotion();
                    trace.event(
                        "camera.ack", "external", "external_position_arrived", 0,
                        "pitch=" + std::to_string(attitude->pitch)
                            + "; pan=" + std::to_string(attitude->pan)
                            + "; transport=open_uvc_feedback",
                        positionTarget->commandID
                    );
                    positionTarget.reset();
                    externalControl = false;
                } else {
                    const double pitchLimit = tiny3 ? 45.0 : 90.0;
                    const double panLimit = tiny3 ? 90.0 : 180.0;
                    const float pitchVelocity = static_cast<float>(
                        pitchLimit * std::tanh(pitchError / 18.0)
                    );
                    const float panVelocity = static_cast<float>(
                        panLimit * std::tanh(panError / 25.0)
                    );
                    if (transport.setExternalVelocity(pitchVelocity, panVelocity) != 0) {
                        trace.event(
                            "camera.ack", "fault", "external_position_feedback_failed", -1,
                            "transport=open_uvc_feedback", positionTarget->commandID
                        );
                        positionTarget.reset();
                        externalControl = false;
                    }
                }
            }
            nextAttitude = now + std::chrono::milliseconds(20);
        }
        if (pulseDeadline && now >= *pulseDeadline) {
            transport.stopMotion();
            externalControl = false;
            positionTarget.reset();
            pulseDeadline.reset();
        }
        if (nativeTracking && now - lastHeartbeat > std::chrono::milliseconds(750)) {
            transport.disableHumanTracking();
            transport.stopMotion();
            nativeTracking = false;
            emitNativeTracking("inactive", nativeCommandID, "watchdog_expired");
            nativeCommandID.clear();
        }
        if (externalControl && !positionTarget
            && now - lastExternalCommand > std::chrono::milliseconds(700)) {
            transport.stopMotion();
            externalControl = false;
            positionTarget.reset();
            pulseDeadline.reset();
        }
        indicator.tick();
    }
    transport.disableHumanTracking();
    transport.stopMotion();
    return interrupted ? 130 : 0;
}

} // namespace

int main(int argc, char **argv) {
    try {
        ::signal(SIGINT, handleSignal);
        ::signal(SIGTERM, handleSignal);
        const Options options = parseOptions(argc, argv);
        Trace trace(options.outputPath, options.traceMaximumBytes, options.traceRetainedFiles);
        soma::OpenOBSBOTUVCTransport transport;
        std::string error;
        if (!transport.openDetected(error)) {
            trace.event("camera.ack", "fault", "control_transport_unavailable", -1,
                        "profile=auto; reason=" + error);
            return 2;
        }
        const std::string profileID = soma::openOBSBOTProfileID(transport.profile());
        trace.event("camera.owner", "manual", "control_transport_ready", 0,
                    "profile=" + profileID + "; primary=open_uvc_xu; compatibility=none");
        if (options.manualStop) {
            const int track = transport.disableHumanTracking();
            const int stop = transport.stopMotion();
            return track == 0 && stop == 0 ? 0 : 4;
        }
        if (options.center) return transport.center() == 0 ? 0 : 4;
        if (options.parkSleep) return parkAndSleep(transport, trace, "park-sleep-1") ? 0 : 4;
        if (!options.serve) {
            throw std::runtime_error("--serve, --manual-stop, --center, or --park-sleep is required");
        }
        return runServer(transport, trace, options);
    } catch (const std::exception &error) {
        std::cerr << "soma-native-track: " << error.what() << '\n';
        return 1;
    }
}
