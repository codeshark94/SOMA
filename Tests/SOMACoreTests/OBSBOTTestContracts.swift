import SOMACore

func tiny2LiteTestContract() -> OBSBOTDeviceContract {
    OBSBOTDeviceContract.parse(
        "SOMA_OBSBOT_CAPABILITY contract=2 profile=tiny_2_lite product_type=15 "
            + "native_bridge=true motor_calibrated=true bounded_calibration_pulses=false "
            + "native_human_tracking=true indicator_palette=true indicator_default_green=false indicator_direct_rgb=false "
            + "indicator_direct_rgb_mask=0 indicator_basic=true indicator_pulse_transport=1 selectable_audio_modes=false "
            + "supported_audio_mode_mask=0 sound_localization=false requires_measured_attitude_frame=false "
            + "native_tracking_transport=1 indicator_yellow_state_id=16 indicator_green_state_id=54 "
            + "indicator_blue_state_id=57 maximum_pan_degrees_per_second=180 "
            + "maximum_pitch_degrees_per_second=90 nominal_wide_horizontal_fov_degrees=67.2 "
            + "firmware=test serial=TINY2"
    )!
}

func tiny3LiteTestContract() -> OBSBOTDeviceContract {
    OBSBOTDeviceContract.parse(
        "SOMA_OBSBOT_CAPABILITY contract=2 profile=tiny_3_lite product_type=19 "
            + "native_bridge=true motor_calibrated=false bounded_calibration_pulses=true "
            + "native_human_tracking=true indicator_palette=true indicator_default_green=false indicator_direct_rgb=false "
            + "indicator_direct_rgb_mask=0 indicator_basic=true indicator_pulse_transport=2 selectable_audio_modes=true "
            + "supported_audio_mode_mask=55 sound_localization=true requires_measured_attitude_frame=true "
            + "native_tracking_transport=2 indicator_yellow_state_id=16 indicator_green_state_id=54 "
            + "indicator_blue_state_id=57 maximum_pan_degrees_per_second=90 "
            + "maximum_pitch_degrees_per_second=45 nominal_wide_horizontal_fov_degrees=72 "
            + "firmware=6.5.10.1 serial=TINY3"
    )!
}
