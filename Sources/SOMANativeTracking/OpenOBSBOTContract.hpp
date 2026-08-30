#pragma once

#include "OpenOBSBOTUVCTransport.hpp"

#include <string>

namespace soma {

inline const char *openOBSBOTProfileID(OBSBOTOpenDeviceProfile profile) noexcept {
    return profile == OBSBOTOpenDeviceProfile::tiny2Lite ? "tiny_2_lite" : "tiny_3_lite";
}

inline std::string openOBSBOTContractLine(const OpenOBSBOTDeviceIdentity &identity) {
    std::string line = "SOMA_OBSBOT_CAPABILITY contract=2 profile=";
    line += openOBSBOTProfileID(identity.profile);
    if (identity.profile == OBSBOTOpenDeviceProfile::tiny2Lite) {
        line += " native_bridge=true"
            " motor_calibrated=true"
            " bounded_calibration_pulses=false"
            " native_human_tracking=true"
            " indicator_palette=true"
            " indicator_default_green=false"
            " indicator_direct_rgb=false"
            " indicator_direct_rgb_mask=0"
            " indicator_basic=true"
            " indicator_pulse_transport=1"
            " selectable_audio_modes=false"
            " supported_audio_mode_mask=0"
            " sound_localization=false"
            " requires_measured_attitude_frame=false"
            " indicator_base_state_id=-1"
            " indicator_yellow_state_id=16"
            " indicator_green_state_id=54"
            " indicator_blue_state_id=57"
            " maximum_pan_degrees_per_second=180"
            " maximum_pitch_degrees_per_second=90"
            " nominal_wide_horizontal_fov_degrees=67.2"
            " native_tracking_transport=1";
    } else {
        line += " native_bridge=true"
            " motor_calibrated=false"
            " bounded_calibration_pulses=true"
            " native_human_tracking=true"
            " indicator_palette=true"
            " indicator_default_green=false"
            " indicator_direct_rgb=false"
            " indicator_direct_rgb_mask=0"
            " indicator_basic=true"
            " indicator_pulse_transport=2"
            " selectable_audio_modes=true"
            " supported_audio_mode_mask=55"
            " sound_localization=false"
            " requires_measured_attitude_frame=true"
            " indicator_base_state_id=3"
            " indicator_yellow_state_id=16"
            " indicator_green_state_id=54"
            " indicator_blue_state_id=57"
            " maximum_pan_degrees_per_second=90"
            " maximum_pitch_degrees_per_second=45"
            " nominal_wide_horizontal_fov_degrees=72"
            " native_tracking_transport=2";
    }
    line += " firmware=unknown serial=";
    line += identity.serial.empty() ? "unavailable" : identity.serial;
    line += " control_transport=open_uvc_xu";
    return line;
}

} // namespace soma
