#pragma once

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>

namespace soma {

enum class OpenOBSBOTControlState {
    healthy,
    degraded,
    reconnecting,
    restoring,
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
    }
    return "degraded";
}

} // namespace soma
