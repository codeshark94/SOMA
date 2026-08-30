#include "OpenOBSBOTProtocol.hpp"
#include "OpenOBSBOTContract.hpp"

#include <cassert>
#include <cmath>
#include <cstring>
#include <limits>

namespace {

int16_t readI16LE(const std::vector<uint8_t> &bytes, size_t offset) {
    return static_cast<int16_t>(
        static_cast<uint16_t>(bytes[offset])
        | (static_cast<uint16_t>(bytes[offset + 1]) << 8)
    );
}

float readFloatLE(const std::vector<uint8_t> &bytes, size_t offset) {
    const uint32_t bits = static_cast<uint32_t>(bytes[offset])
        | (static_cast<uint32_t>(bytes[offset + 1]) << 8)
        | (static_cast<uint32_t>(bytes[offset + 2]) << 16)
        | (static_cast<uint32_t>(bytes[offset + 3]) << 24);
    float value = 0;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

} // namespace

int main() {
    using soma::OBSBOTOpenDeviceProfile;
    using namespace soma::open_obsbot_protocol;

    assert(vendorID == 0x3564);
    assert(productID(OBSBOTOpenDeviceProfile::tiny2Lite) == 0xFEF9);
    assert(productID(OBSBOTOpenDeviceProfile::tiny3Lite) == 0xFF04);
    const std::string tiny3Contract = soma::openOBSBOTContractLine({
        OBSBOTOpenDeviceProfile::tiny3Lite,
        productID(OBSBOTOpenDeviceProfile::tiny3Lite),
        "test",
    });
    assert(tiny3Contract.find("sound_localization=false") != std::string::npos);
    assert(tiny3Contract.find("sound_localization=true") == std::string::npos);
    assert(isRestPose(-70.0));
    assert(isRestPose(84.0));
    assert(!isRestPose(2.5));
    assert(isRunPose(2.5));
    assert(!isRunPose(70.0));

    const auto tiny2Velocity = externalVelocity(
        OBSBOTOpenDeviceProfile::tiny2Lite,
        12.5f,
        8.25f
    );
    assert(tiny2Velocity);
    assert(tiny2Velocity->command == 0x6484);
    assert(tiny2Velocity->receiver == 0x04);
    assert(tiny2Velocity->payload.size() == 12);
    assert(std::abs(readFloatLE(tiny2Velocity->payload, 4) - 12.5f) < 0.001f);
    assert(std::abs(readFloatLE(tiny2Velocity->payload, 8) + 8.25f) < 0.001f);

    const auto tiny3Velocity = externalVelocity(
        OBSBOTOpenDeviceProfile::tiny3Lite,
        -12.5f,
        8.25f
    );
    assert(tiny3Velocity);
    assert(tiny3Velocity->command == 0x0103);
    assert(tiny3Velocity->receiver == 0x03);
    assert(tiny3Velocity->payload.size() == 6);
    assert(readI16LE(tiny3Velocity->payload, 2) == -1250);
    assert(readI16LE(tiny3Velocity->payload, 4) == 825);
    assert(!externalVelocity(
        OBSBOTOpenDeviceProfile::tiny3Lite,
        std::numeric_limits<float>::quiet_NaN(),
        0
    ));

    const auto tiny2Wake = wakeState(OBSBOTOpenDeviceProfile::tiny2Lite, true);
    const auto tiny3Sleep = wakeState(OBSBOTOpenDeviceProfile::tiny3Lite, false);
    assert(tiny2Wake.command == 0xA0C2 && tiny2Wake.receiver == 0x02);
    assert(tiny2Wake.payload == std::vector<uint8_t> {0});
    assert(tiny3Sleep.command == 0xA0C2 && tiny3Sleep.receiver == 0x02);
    assert(tiny3Sleep.payload == (std::vector<uint8_t> {1, 0, 0, 0}));

    assert(!firmwareRecenter(OBSBOTOpenDeviceProfile::tiny2Lite));
    const auto tiny3Center = firmwareRecenter(OBSBOTOpenDeviceProfile::tiny3Lite);
    assert(tiny3Center && tiny3Center->command == 0x00C3);
    assert(tiny3Center->receiver == 0x03 && tiny3Center->payload.size() == 6);

    assert(!selectHumanTarget(OBSBOTOpenDeviceProfile::tiny2Lite, 0.2f, 0.2f, 0.5f, 0.5f));
    const auto tiny3Target = selectHumanTarget(
        OBSBOTOpenDeviceProfile::tiny3Lite,
        0.2f,
        0.1f,
        0.5f,
        0.7f
    );
    assert(tiny3Target && tiny3Target->command == 0x0684);
    assert(tiny3Target->receiver == 0x04 && tiny3Target->payload.size() == 24);
    assert(readI16LE(tiny3Target->payload, 0) == 3);
    assert(readI16LE(tiny3Target->payload, 2) == 0);
    assert(readI16LE(tiny3Target->payload, 4) == 99);

    const auto tiny3Clear = clearTiny3HumanTarget();
    assert(tiny3Clear.command == 0x0684 && tiny3Clear.payload.size() == 24);
    assert(readI16LE(tiny3Clear.payload, 0) == -1);
    return 0;
}
