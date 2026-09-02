#pragma once

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace soma {

constexpr int32_t openOBSBOTFunctionalMotionStall = -7001;

enum class OpenOBSBOTFunctionalRecoveryOutcome {
    runStateRestored,
    physicalReconnectRequired,
    failed,
};

enum class OpenOBSBOTMotionStallDisposition {
    resumeAfterVerifiedProbe,
    awaitPhysicalReconnect,
    recoverControlEndpoint,
};

inline OpenOBSBOTMotionStallDisposition openOBSBOTMotionStallDisposition(
    OpenOBSBOTFunctionalRecoveryOutcome outcome
) noexcept {
    switch (outcome) {
    case OpenOBSBOTFunctionalRecoveryOutcome::runStateRestored:
        return OpenOBSBOTMotionStallDisposition::resumeAfterVerifiedProbe;
    case OpenOBSBOTFunctionalRecoveryOutcome::physicalReconnectRequired:
        return OpenOBSBOTMotionStallDisposition::awaitPhysicalReconnect;
    case OpenOBSBOTFunctionalRecoveryOutcome::failed:
        return OpenOBSBOTMotionStallDisposition::recoverControlEndpoint;
    }
    return OpenOBSBOTMotionStallDisposition::recoverControlEndpoint;
}

inline bool openOBSBOTRequiresFunctionalRecovery(int32_t reason) noexcept {
    return reason == openOBSBOTFunctionalMotionStall;
}

struct OpenOBSBOTVelocityTransition {
    float pitch = 0;
    float pan = 0;
    bool pitchNeutralized = false;
    bool panNeutralized = false;
    bool settling = false;

    bool neutralized() const noexcept {
        return pitchNeutralized || panNeutralized;
    }
};

/// Converts a stream of attitude samples into physical-settle evidence. A
/// command acknowledgement cannot advance a lifecycle transition; the gimbal
/// must remain within the measured motion envelope for consecutive samples.
class OpenOBSBOTPoseStabilityGate final {
public:
    bool observe(double pitch, double pan) noexcept {
        if (!std::isfinite(pitch) || !std::isfinite(pan)) {
            reset();
            return false;
        }
        if (!lastPose_) {
            lastPose_ = PoseSample {pitch, pan};
            return false;
        }
        const double motion = std::hypot(
            pitch - lastPose_->pitch,
            pan - lastPose_->pan
        );
        lastPose_ = PoseSample {pitch, pan};
        if (motion <= settledMotionDegrees) {
            ++stablePoseIntervals_;
        } else {
            stablePoseIntervals_ = 0;
        }
        return stablePoseIntervals_ >= requiredStablePoseIntervals;
    }

    void reset() noexcept {
        stablePoseIntervals_ = 0;
        lastPose_.reset();
    }

private:
    struct PoseSample {
        double pitch;
        double pan;
    };

    size_t stablePoseIntervals_ = 0;
    std::optional<PoseSample> lastPose_;
    static constexpr double settledMotionDegrees = 0.35;
    static constexpr size_t requiredStablePoseIntervals = 2;
};

/// Enforces the motor boundary invariant that an axis must pass through a
/// neutral command before its velocity changes sign. Higher-level controllers
/// normally slew through zero, but this guard also covers direct L1/L2/MCP
/// commands before they reach the device firmware.
class OpenOBSBOTVelocityTransitionGuard final {
public:
    OpenOBSBOTVelocityTransition apply(float pitch, float pan) noexcept {
        if (settling_) {
            return OpenOBSBOTVelocityTransition {0, 0, false, false, true};
        }
        OpenOBSBOTVelocityTransition transition {
            pitch,
            pan,
            crossesZero(previousPitch_, pitch),
            crossesZero(previousPan_, pan),
            false,
        };
        const bool pitchStopped = previousPitch_ != 0 && pitch == 0;
        const bool panStopped = previousPan_ != 0 && pan == 0;
        if (transition.neutralized() || pitchStopped || panStopped) {
            transition.pitchNeutralized = transition.pitchNeutralized || pitchStopped;
            transition.panNeutralized = transition.panNeutralized || panStopped;
            transition.pitch = 0;
            transition.pan = 0;
            transition.settling = true;
            settling_ = true;
            poseStability_.reset();
        }
        previousPitch_ = transition.pitch;
        previousPan_ = transition.pan;
        return transition;
    }

    void observe(double pitch, double pan) noexcept {
        if (!settling_) return;
        if (poseStability_.observe(pitch, pan)) {
            settling_ = false;
            poseStability_.reset();
        }
    }

    void clear() noexcept {
        previousPitch_ = 0;
        previousPan_ = 0;
        settling_ = false;
        poseStability_.reset();
    }

    bool settling() const noexcept { return settling_; }

private:
    static bool crossesZero(float previous, float requested) noexcept {
        return std::isfinite(previous) && std::isfinite(requested)
            && previous != 0 && requested != 0
            && std::signbit(previous) != std::signbit(requested);
    }

    float previousPitch_ = 0;
    float previousPan_ = 0;
    bool settling_ = false;
    OpenOBSBOTPoseStabilityGate poseStability_;
};

/// A functional motor fault may only be cleared by observing a new USB device
/// registry entry. Elapsed time and successful endpoint traffic are not
/// evidence that the camera's motor controller has restarted.
class OpenOBSBOTPhysicalReconnectLatch final {
public:
    void engage(uint64_t registryEntryID) noexcept {
        engaged_ = true;
        failedRegistryEntryID_ = registryEntryID;
    }

    bool observe(uint64_t registryEntryID) noexcept {
        if (!engaged_ || registryEntryID == 0 || failedRegistryEntryID_ == 0
            || registryEntryID == failedRegistryEntryID_) {
            return false;
        }
        engaged_ = false;
        failedRegistryEntryID_ = 0;
        return true;
    }

    bool engaged() const noexcept { return engaged_; }
    uint64_t failedRegistryEntryID() const noexcept { return failedRegistryEntryID_; }

private:
    bool engaged_ = false;
    uint64_t failedRegistryEntryID_ = 0;
};

enum class OpenOBSBOTMotionObservation {
    idle,
    monitoring,
    progress,
    stalled,
};

/// Verifies that accepted velocity writes produce measured gimbal motion.
/// USB control transfers can succeed while the camera firmware ignores the
/// command, so transport success alone is not actuator success.
class OpenOBSBOTMotionWatchdog final {
public:
    using Clock = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;

    void setIntent(
        double pitchVelocity,
        double panVelocity,
        double pitchLimit,
        double panLimit,
        TimePoint now = Clock::now()
    ) noexcept {
        const double magnitude = std::hypot(pitchVelocity, panVelocity);
        if (!std::isfinite(magnitude) || magnitude < minimumCommandDegreesPerSecond) {
            clear();
            return;
        }
        // Smooth controllers rotate the velocity vector over several small
        // updates. Comparing only adjacent commands misses a gradual reversal
        // and carries the old stall deadline into a new movement episode.
        // Compare against the intent that established the measured baseline.
        const bool directionChanged = baseline_
            && (baseline_->pitchVelocity * pitchVelocity
                + baseline_->panVelocity * panVelocity) <= 0;
        pitchVelocity_ = pitchVelocity;
        panVelocity_ = panVelocity;
        pitchLimit_ = std::abs(pitchLimit);
        panLimit_ = std::abs(panLimit);
        if (!active_ || directionChanged) {
            active_ = true;
            baseline_.reset();
        }
    }

    OpenOBSBOTMotionObservation observe(
        double pitch,
        double pan,
        TimePoint now = Clock::now()
    ) noexcept {
        if (!active_ || !std::isfinite(pitch) || !std::isfinite(pan)) {
            return OpenOBSBOTMotionObservation::idle;
        }
        const bool pitchExpected = axisCanMove(pitch, pitchVelocity_, pitchLimit_);
        const bool panExpected = axisCanMove(pan, panVelocity_, panLimit_);
        if (!pitchExpected && !panExpected) {
            baseline_.reset();
            return OpenOBSBOTMotionObservation::idle;
        }
        if (!baseline_) {
            baseline_ = Sample {pitch, pan, pitchVelocity_, panVelocity_, now};
            return OpenOBSBOTMotionObservation::monitoring;
        }
        const double pitchDelta = pitchExpected ? pitch - baseline_->pitch : 0;
        const double panDelta = panExpected ? pan - baseline_->pan : 0;
        if (std::hypot(pitchDelta, panDelta) >= minimumObservedMotionDegrees) {
            baseline_ = Sample {pitch, pan, pitchVelocity_, panVelocity_, now};
            return OpenOBSBOTMotionObservation::progress;
        }
        if (now - baseline_->observedAt >= stallWindow) {
            clear();
            return OpenOBSBOTMotionObservation::stalled;
        }
        return OpenOBSBOTMotionObservation::monitoring;
    }

    void clear() noexcept {
        active_ = false;
        baseline_.reset();
        pitchVelocity_ = 0;
        panVelocity_ = 0;
    }

    bool active() const noexcept { return active_; }

private:
    struct Sample {
        double pitch;
        double pan;
        double pitchVelocity;
        double panVelocity;
        TimePoint observedAt;
    };

    static bool axisCanMove(double position, double velocity, double limit) noexcept {
        if (std::abs(velocity) < minimumCommandDegreesPerSecond) return false;
        return !(limit > 0
            && std::abs(position) >= limit - jointLimitMarginDegrees
            && position * velocity > 0);
    }

    static constexpr double minimumCommandDegreesPerSecond = 4.0;
    static constexpr double minimumObservedMotionDegrees = 0.35;
    static constexpr double jointLimitMarginDegrees = 2.0;
    static constexpr std::chrono::milliseconds stallWindow {700};

    bool active_ = false;
    double pitchVelocity_ = 0;
    double panVelocity_ = 0;
    double pitchLimit_ = 0;
    double panLimit_ = 0;
    std::optional<Sample> baseline_;
};

enum class OpenOBSBOTControlState {
    healthy,
    degraded,
    reconnecting,
    restoring,
    awaitingPhysicalReconnect,
};

enum class OpenOBSBOTRecoveryAttemptOutcome {
    notAttempted,
    reopenFailed,
    readProbeFailed,
    writeProbeFailed,
    endpointValidated,
};

struct OpenOBSBOTRecoveryAttempt {
    OpenOBSBOTRecoveryAttemptOutcome outcome = OpenOBSBOTRecoveryAttemptOutcome::notAttempted;
    int32_t ioReturn = 0;

    bool attempted() const noexcept {
        return outcome != OpenOBSBOTRecoveryAttemptOutcome::notAttempted;
    }

    bool endpointValidated() const noexcept {
        return outcome == OpenOBSBOTRecoveryAttemptOutcome::endpointValidated;
    }
};

struct OpenOBSBOTRecoverySnapshot {
    OpenOBSBOTControlState state = OpenOBSBOTControlState::degraded;
    int32_t lastIOReturn = 0;
    size_t consecutiveFailures = 0;
    uint64_t generation = 0;
    uint64_t retryAfterMilliseconds = 0;
};

/// Circuit breaker for the USB control plane. The media stream is independent;
/// a failed XU transfer must therefore quiesce only actuator writes while the
/// control endpoint is rebound and verified.
class OpenOBSBOTRecoveryPolicy final {
public:
    using Clock = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;

    void noteHealthy(TimePoint now = Clock::now()) noexcept {
        state_ = OpenOBSBOTControlState::healthy;
        consecutiveFailures_ = 0;
        retryAt_ = now;
    }

    void noteFailure(int32_t ioReturn, TimePoint now = Clock::now()) noexcept {
        lastIOReturn_ = ioReturn;
        ++consecutiveFailures_;
        state_ = OpenOBSBOTControlState::degraded;
        retryAt_ = now + retryDelay(consecutiveFailures_);
    }

    void notePhysicalReconnectRequired(
        int32_t ioReturn,
        TimePoint now = Clock::now()
    ) noexcept {
        lastIOReturn_ = ioReturn;
        ++consecutiveFailures_;
        state_ = OpenOBSBOTControlState::awaitingPhysicalReconnect;
        retryAt_ = now;
    }

    bool noteDeviceReconnected(TimePoint now = Clock::now()) noexcept {
        if (state_ != OpenOBSBOTControlState::awaitingPhysicalReconnect) return false;
        state_ = OpenOBSBOTControlState::degraded;
        retryAt_ = now;
        return true;
    }

    bool beginRecovery(TimePoint now = Clock::now()) noexcept {
        if (state_ != OpenOBSBOTControlState::degraded || now < retryAt_) return false;
        state_ = OpenOBSBOTControlState::reconnecting;
        return true;
    }

    void noteEndpointValidated(TimePoint now = Clock::now()) noexcept {
        state_ = OpenOBSBOTControlState::restoring;
        retryAt_ = now;
    }

    bool commitRecovery(TimePoint now = Clock::now()) noexcept {
        if (state_ != OpenOBSBOTControlState::restoring) return false;
        noteHealthy(now);
        return true;
    }

    OpenOBSBOTRecoverySnapshot snapshot(
        uint64_t generation,
        TimePoint now = Clock::now()
    ) const noexcept {
        const auto remaining = retryAt_ > now
            ? std::chrono::duration_cast<std::chrono::milliseconds>(retryAt_ - now).count()
            : 0;
        return {
            state_,
            lastIOReturn_,
            consecutiveFailures_,
            generation,
            static_cast<uint64_t>(std::max<int64_t>(remaining, 0)),
        };
    }

    static std::chrono::milliseconds retryDelay(size_t consecutiveFailures) noexcept {
        constexpr int64_t delays[] {100, 250, 500, 1000, 2000, 5000};
        constexpr size_t delayCount = sizeof(delays) / sizeof(delays[0]);
        const size_t index = consecutiveFailures == 0
            ? 0
            : std::min(consecutiveFailures - 1, delayCount - 1);
        return std::chrono::milliseconds(delays[index]);
    }

private:
    OpenOBSBOTControlState state_ = OpenOBSBOTControlState::degraded;
    int32_t lastIOReturn_ = 0;
    size_t consecutiveFailures_ = 0;
    TimePoint retryAt_ = TimePoint::min();
};

template <typename Reopen, typename ReadProbe, typename WriteProbe, typename Close, typename Now>
OpenOBSBOTRecoveryAttempt attemptOpenOBSBOTRecovery(
    OpenOBSBOTRecoveryPolicy &policy,
    Reopen reopen,
    ReadProbe readProbe,
    WriteProbe writeProbe,
    Close close,
    Now now,
    OpenOBSBOTRecoveryPolicy::TimePoint attemptAt
) {
    if (!policy.beginRecovery(attemptAt)) return {};

    const int32_t reopenResult = reopen();
    if (reopenResult != 0) {
        close();
        policy.noteFailure(reopenResult, now());
        return {OpenOBSBOTRecoveryAttemptOutcome::reopenFailed, reopenResult};
    }
    const int32_t readResult = readProbe();
    if (readResult != 0) {
        close();
        policy.noteFailure(readResult, now());
        return {OpenOBSBOTRecoveryAttemptOutcome::readProbeFailed, readResult};
    }
    const int32_t writeResult = writeProbe();
    if (writeResult != 0) {
        close();
        policy.noteFailure(writeResult, now());
        return {OpenOBSBOTRecoveryAttemptOutcome::writeProbeFailed, writeResult};
    }
    policy.noteEndpointValidated(now());
    return {OpenOBSBOTRecoveryAttemptOutcome::endpointValidated, 0};
}

inline bool openOBSBOTIntentIsFresh(
    OpenOBSBOTRecoveryPolicy::TimePoint deadline,
    OpenOBSBOTRecoveryPolicy::TimePoint now = OpenOBSBOTRecoveryPolicy::Clock::now()
) noexcept {
    return now < deadline;
}

inline const char *openOBSBOTControlStateName(OpenOBSBOTControlState state) noexcept {
    switch (state) {
    case OpenOBSBOTControlState::healthy: return "healthy";
    case OpenOBSBOTControlState::degraded: return "degraded";
    case OpenOBSBOTControlState::reconnecting: return "reconnecting";
    case OpenOBSBOTControlState::restoring: return "restoring";
    case OpenOBSBOTControlState::awaitingPhysicalReconnect:
        return "awaiting_physical_reconnect";
    }
    return "degraded";
}

} // namespace soma
