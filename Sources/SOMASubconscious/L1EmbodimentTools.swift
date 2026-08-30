import Foundation
import SOMACore

/// In-process endpoint for L1's semantic embodiment tools. It shares the L2
/// MCP request model but has no access to velocity, device packets, or image transport.
/// The handler is installed only after the L0 motor adapter exists.
final class L1EmbodimentToolRelay: @unchecked Sendable {
    typealias Submitter = @Sendable (CognitiveEmbodimentRequest) -> EmbodimentShadowDecision?
    typealias SnapshotProvider = @Sendable () -> EmbodimentShadowSnapshot?
    typealias CaptureResultProvider = @Sendable (String, UInt64) -> EmbodimentViewResource?

    private let lock = NSLock()
    private var submitter: Submitter?
    private var snapshotProvider: SnapshotProvider?
    private var captureResultProvider: CaptureResultProvider?

    func install(
        submitter: @escaping Submitter,
        snapshotProvider: @escaping SnapshotProvider,
        captureResultProvider: @escaping CaptureResultProvider
    ) {
        lock.lock()
        self.submitter = submitter
        self.snapshotProvider = snapshotProvider
        self.captureResultProvider = captureResultProvider
        lock.unlock()
    }

    func stop() {
        lock.lock()
        submitter = nil
        snapshotProvider = nil
        captureResultProvider = nil
        lock.unlock()
    }

    func submit(_ request: CognitiveEmbodimentRequest) -> EmbodimentShadowDecision? {
        lock.lock()
        let submitter = self.submitter
        lock.unlock()
        return submitter?(request)
    }

    func snapshot() -> EmbodimentShadowSnapshot? {
        lock.lock()
        let snapshotProvider = self.snapshotProvider
        lock.unlock()
        return snapshotProvider?()
    }

    /// This bounded wait is confined to the L1 tool round. L0 keeps running on
    /// its own queue while the semantic capture settles and encodes.
    func waitForCapture(
        requestID: String,
        leaseExpiresAtNS: UInt64,
        maximumWaitMilliseconds: UInt64 = 15_000
    ) -> EmbodimentViewResource? {
        let now = DispatchTime.now().uptimeNanoseconds
        let maximumWaitNS = maximumWaitMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        let deadline = min(
            leaseExpiresAtNS,
            maximumWaitNS.overflow ? UInt64.max : now.addingReportingOverflow(maximumWaitNS.partialValue).partialValue
        )
        while DispatchTime.now().uptimeNanoseconds < deadline {
            lock.lock()
            let captureResultProvider = self.captureResultProvider
            lock.unlock()
            guard let resource = captureResultProvider?(requestID, DispatchTime.now().uptimeNanoseconds) else {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            switch resource.state {
            case .ready, .failed, .expired:
                return resource
            case .pendingAlignment, .awaitingFrame, .encoding:
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return nil
    }
}

/// Adapts L1's flat Ollama tool schema to the same semantic lease contract
/// exposed to L2 through soma-embodiment. It intentionally returns only scalar
/// scene and arbitration state; pixels stay behind explicit capture resources.
final class L1EmbodimentToolGateway: @unchecked Sendable {
    private let relay: L1EmbodimentToolRelay
    private let ownerID = "l1.situational_attention"
    private let priority: UInt8 = 60
    private let visualLock = NSLock()
    private var pendingCaptureVisuals: [L1VisualResource] = []

    init(relay: L1EmbodimentToolRelay) {
        self.relay = relay
    }

    var definitions: [OllamaToolDefinition] {
        [
            tool("inspect_scene", "Read the current scalar scene inventory: scene IDs, detector labels, kind, confidence, whether an entity is currently observed, and existing semantic bindings. Use this before selecting a specific visual target. It never returns an image.", [
                "reason": property("Why a current scene inventory is necessary")
            ], required: ["reason"]),
            tool("register_attention_target", "Bind one L1 semantic target to a currently observed scene_id. Use inspect_scene first; scene_id and label must refer to the same current detector entity. Registration alone does not move the camera.", [
                "target_reference": property("Stable L1 target reference, for example target:reading-book"),
                "scene_id": property("Current scene_id from inspect_scene"),
                "label": property("Detector label from inspect_scene"),
                "expected_kind": property("human, object, or unknown"),
                "selection_log_prior": numberProperty("Interest log-prior from -12 to 12"),
                "reason": property("Why this target should be registered")
            ], required: ["target_reference", "scene_id", "label", "reason"]),
            tool("set_target_attention", "Set L1's probabilistic interest and persistence policy for one registered target. This shapes L1's target policy but does not itself command motion; call track_attention_target when observation is needed now.", [
                "target_reference": property("Registered target_reference"),
                "selection_log_prior": numberProperty("Interest log-prior from -12 to 12"),
                "tracking_commitment": numberProperty("Persistence from 0 to 1"),
                "selection_temperature": numberProperty("Optional exploration temperature from 0.1 to 5"),
                "novelty_strength": numberProperty("Optional novelty weight from 0 to 1"),
                "habituation_strength": numberProperty("Optional habituation weight from 0 to 1"),
                "reason": property("Why this interest policy is appropriate")
            ], required: ["target_reference", "selection_log_prior", "tracking_commitment", "reason"]),
            tool("track_attention_target", "Lease L0 tracking for a registered target. Optional framing places the target in a requested normalized image region; L0 computes calibrated spherical aim, route planning, feedback, and limits. Do not use this for generic scanning.", [
                "target_reference": property("Registered target_reference"),
                "motion_style": property("precise, smooth, attentive, curious, playful, or cautious"),
                "reacquire_if_occluded": booleanProperty("Whether L0 may keep the semantic target through a brief occlusion"),
                "framing_x": numberProperty("Optional normalized desired frame x"),
                "framing_y": numberProperty("Optional normalized desired frame y"),
                "framing_width": numberProperty("Optional normalized desired frame width"),
                "framing_height": numberProperty("Optional normalized desired frame height"),
                "lease_ms": numberProperty("Optional bounded tracking lease in milliseconds, maximum 600000"),
                "reason": property("Specific observation question this tracking serves")
            ], required: ["target_reference", "motion_style", "reacquire_if_occluded", "reason"]),
            tool("capture_target_view", "Ask L0 to move to a registered target or explicit spherical bearing, wait for a settled frame, then produce one short-lived narrow-FOV view. field_of_view_degrees is a digital observation crop, not an optical zoom command.", [
                "target_reference": property("Optional registered target_reference"),
                "azimuth_degrees": numberProperty("Optional gimbal-home-relative azimuth when no target is used"),
                "elevation_degrees": numberProperty("Optional gimbal-home-relative elevation when no target is used"),
                "field_of_view_degrees": numberProperty("Desired digital field of view, 5 to 86 degrees"),
                "reason": property("Why a settled narrow view is needed")
            ], required: ["field_of_view_degrees", "reason"]),
            tool("set_camera_optical_zoom", "Set the camera's physical sensor crop for a concrete detail-observation purpose. L0 verifies the active device's reported zoom before spatial evidence uses it. Use 1.0 to restore the wide view; do not use this merely to scan.", [
                "factor": numberProperty("Requested physical zoom factor from 1.0 to 2.0"),
                "reason": property("Specific detail-observation purpose")
            ], required: ["factor", "reason"]),
            tool("set_audio_capture_mode", "Select how the active hardware listens for a concrete task. spatial_stereo preserves binaural direction evidence; conversation_front is forward beamforming for a person already in front of the camera. L0 verifies the selected device mode before relying on it.", [
                "mode": property("spatial_stereo, conversation_front, ambient_omni, rear, bidirectional, or music"),
                "reason": property("Specific listening purpose")
            ], required: ["mode", "reason"]),
            tool("set_audio_input_gain", "Set microphone input gain for a specific listening task. This changes only input level: it neither changes spatial capture mode nor takes a gimbal lease. L0 verifies the firmware readback before accepting the result.", [
                "percent": numberProperty("Integer microphone input gain from 0 through 100"),
                "reason": property("Specific listening purpose")
            ], required: ["percent", "reason"]),
            tool("set_camera_white_balance", "Set camera white balance for a concrete visual task. auto keeps adaptive color; manual locks a Kelvin temperature so panorama strips or repeated observations share stable color. L0 verifies the firmware-reported setting.", [
                "mode": property("auto or manual"),
                "temperature_kelvin": numberProperty("Required from 2000 to 9000 only when mode is manual"),
                "reason": property("Specific visual-observation purpose")
            ], required: ["mode", "reason"]),
            tool("set_camera_exposure_lock", "Hold or release the camera's current automatic exposure for a concrete visual-observation task. Lock exposure only when stable brightness matters, such as a panorama strip; release it after the task so normal perception can adapt to the room.", [
                "locked": booleanProperty("true holds current exposure; false restores automatic exposure"),
                "reason": property("Specific visual-observation purpose")
            ], required: ["locked", "reason"]),
            tool("set_camera_focus", "Set autofocus back to automatic mode, or hold one measured manual focus position for a specific close inspection. Manual focus is not a target-selection command and does not move the gimbal.", [
                "mode": property("auto or manual"),
                "position": numberProperty("Required integer from 0 through 100 only when mode is manual"),
                "reason": property("Specific visual-observation purpose")
            ], required: ["mode", "reason"]),
            tool("set_camera_absolute_exposure", "Return shutter control to automatic mode, or set one firmware shutter code for a specifically justified visual task. L0 checks the active camera's measured supported code range before applying it.", [
                "mode": property("auto or manual"),
                "shutter_code": numberProperty("Required integer only when mode is manual; the active Tiny 3 Lite reports 10 through 42"),
                "reason": property("Specific visual-observation purpose")
            ], required: ["mode", "reason"]),
            tool("set_camera_face_priority", "Enable or disable the camera firmware's face-priority autofocus and auto-exposure. Keep it enabled for human interaction unless a non-face observation needs neutral imaging.", [
                "enabled": booleanProperty("Whether face-priority autofocus and auto-exposure are enabled"),
                "reason": property("Specific visual-observation purpose")
            ], required: ["enabled", "reason"]),
            tool("set_camera_anti_flicker", "Select the camera mains-frequency mode for a concrete visual-observation task. Use the local line frequency when lighting bands are visible; use auto when it is unknown.", [
                "mode": property("off, hz_50, hz_60, or auto"),
                "reason": property("Specific visual-observation purpose")
            ], required: ["mode", "reason"]),
            tool("set_camera_image_tuning", "Set one or more image-pipeline controls for a concrete observation. Every requested field is range-checked, applied atomically, read back, and restored if any firmware step fails. Omit fields that should stay unchanged.", [
                "brightness": numberProperty("Optional value from 0 through 100"),
                "contrast": numberProperty("Optional value from 0 through 100"),
                "hue": numberProperty("Optional value from 0 through 100"),
                "saturation": numberProperty("Optional value from 0 through 100"),
                "sharpness": numberProperty("Optional value from 0 through 100"),
                "reason": property("Specific visual-observation purpose")
            ], required: ["reason"]),
            tool("set_native_human_tracking_policy", "Configure the Tiny 3 native human tracker for an active or future human target. Use fast motion and fore-target retention for responsive social tracking. Fixed pan and pitch gains must be supplied together and require both adaptive gain controls to be disabled.", [
                "speed": property("super_lazy, lazy, slow, fast, or crazy"),
                "motion_tracking": booleanProperty("Whether native motion tracking remains enabled"),
                "fore_target": booleanProperty("Whether native tracking retains the target through a brief occlusion"),
                "adaptive_composition": booleanProperty("Whether nearby people may alter the selected target's composition"),
                "adaptive_pan_gain": booleanProperty("Whether firmware automatically adapts pan tracking gain"),
                "adaptive_pitch_gain": booleanProperty("Whether firmware automatically adapts pitch tracking gain"),
                "pan_gain": numberProperty("Optional fixed pan tracking gain from 0.1 through 1.0; requires pitch_gain and disabled adaptive gains"),
                "pitch_gain": numberProperty("Optional fixed pitch tracking gain from 0.1 through 1.0; requires pan_gain and disabled adaptive gains"),
                "reason": property("Specific social or observation purpose")
            ], required: ["speed", "motion_tracking", "fore_target", "adaptive_composition", "reason"]),
            tool("set_camera_field_of_view", "Set a firmware-calibrated optical field of view for a concrete visual task: 86 wide, 78 medium, or 65 narrow degrees. L0 updates spherical projection from the confirmed camera value; use a narrower view only when it improves a specific observation.", [
                "degrees": numberProperty("One of 86, 78, or 65"),
                "reason": property("Specific visual-observation purpose")
            ], required: ["degrees", "reason"]),
            tool("orient_attention", "Lease a calibrated L0 orientation toward one spherical direction. L0 owns route planning, feedback, joint limits, and stopping.", [
                "azimuth_degrees": numberProperty("Gimbal-home-relative azimuth from -180 to 180"),
                "elevation_degrees": numberProperty("Gimbal-home-relative elevation from -90 to 90"),
                "motion_style": property("precise, smooth, attentive, curious, playful, or cautious"),
                "reason": property("Specific observation question this orientation serves")
            ], required: ["azimuth_degrees", "elevation_degrees", "motion_style", "reason"]),
            tool("explore_attention", "Lease a probabilistic L0 survey around one spherical region. Use only for a concrete information gap after no current semantic target can answer it.", [
                "mode": property("probabilistic_coverage, novelty_seeking, memory_gap, target_biased, or directed_survey"),
                "azimuth_degrees": numberProperty("Optional region center azimuth"),
                "elevation_degrees": numberProperty("Optional region center elevation"),
                "azimuth_radius_degrees": numberProperty("Optional region azimuth radius, 1 to 180"),
                "elevation_radius_degrees": numberProperty("Optional region elevation radius, 1 to 90"),
                "novelty_strength": numberProperty("Optional novelty weight from 0 to 1"),
                "memory_gap_strength": numberProperty("Optional memory-gap weight from 0 to 1"),
                "motion_continuity": numberProperty("Optional continuity weight from 0 to 1"),
                "tempo": numberProperty("Optional tempo from 0 to 1"),
                "reason": property("Concrete unresolved information gap")
            ], required: ["mode", "reason"]),
            tool("release_attention", "Release L1's active camera lease, target registrations, and target attention policy when the observation purpose is complete.", [
                "reason": property("Why the L1 embodiment purpose is complete")
            ], required: ["reason"]),
        ]
    }

    func execute(name: String, arguments: String) -> String? {
        guard Self.toolNames.contains(name) else { return nil }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = string(args, "reason") else {
            return Self.json(["ok": false, "error": "missing_reason"])
        }
        switch name {
        case "inspect_scene":
            return sceneInventory()
        case "register_attention_target":
            guard let reference = string(args, "target_reference"),
                  let sceneID = string(args, "scene_id"),
                  let label = string(args, "label") else {
                return Self.json(["ok": false, "error": "missing_target_reference_scene_id_or_label"])
            }
            let expectedKind = string(args, "expected_kind").flatMap(AttentionTargetKind.init(rawValue:))
            let registration = SemanticTargetRegistration(
                targetReference: reference,
                sceneID: sceneID,
                label: label,
                expectedKind: expectedKind,
                initialSelectionLogPrior: number(args, "selection_log_prior") ?? 0
            )
            return submit(reason: reason, durationMilliseconds: 120_000, operation: .registerTarget(registration))
        case "set_target_attention":
            guard let reference = string(args, "target_reference"),
                  let logPrior = number(args, "selection_log_prior"),
                  let commitment = number(args, "tracking_commitment") else {
                return Self.json(["ok": false, "error": "missing_target_policy"])
            }
            let policy = AttentionPolicyGoal(
                targets: [.init(
                    targetReference: reference,
                    selectionLogPrior: logPrior,
                    trackingCommitment: commitment
                )],
                selectionTemperature: number(args, "selection_temperature") ?? 1,
                noveltyStrength: number(args, "novelty_strength") ?? 0.5,
                habituationStrength: number(args, "habituation_strength") ?? 0.5
            )
            return submit(reason: reason, durationMilliseconds: 120_000, operation: .setAttentionPolicy(policy))
        case "track_attention_target":
            guard let reference = string(args, "target_reference"),
                  let motionStyle = string(args, "motion_style").flatMap(EmbodimentMotionStyle.init(rawValue:)),
                  let reacquire = boolean(args, "reacquire_if_occluded") else {
                return Self.json(["ok": false, "error": "missing_tracking_goal"])
            }
            let parsedFraming = normalizedRect(args)
            if let error = parsedFraming.error {
                return Self.json(["ok": false, "error": error])
            }
            let framing = parsedFraming.value
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 15_000),
                operation: .trackTarget(.init(
                    targetReference: reference,
                    framing: framing,
                    reacquireIfOccluded: reacquire,
                    motionStyle: motionStyle
                ))
            )
        case "capture_target_view":
            return captureTargetView(arguments: args, reason: reason)
        case "set_camera_optical_zoom":
            guard let factor = number(args, "factor"), factor.isFinite, factor >= 1, factor <= 2 else {
                return Self.json(["ok": false, "error": "optical_zoom_factor_must_be_1_to_2"])
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setOpticalZoom(.init(factor: factor))
            )
        case "set_audio_capture_mode":
            guard let mode = string(args, "mode").flatMap(MicrophoneCaptureMode.init(rawValue:)) else {
                return Self.json(["ok": false, "error": "invalid_audio_capture_mode"])
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setAudioCaptureMode(.init(mode: mode))
            )
        case "set_audio_input_gain":
            guard let value = number(args, "percent"), value.isFinite,
                  value.rounded() == value, (0...100).contains(Int(value)) else {
                return Self.json(["ok": false, "error": "audio_input_gain_must_be_0_to_100"])
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setAudioInputGain(.init(percent: Int(value)))
            )
        case "set_camera_white_balance":
            guard let mode = string(args, "mode").flatMap(CameraWhiteBalanceMode.init(rawValue:)) else {
                return Self.json(["ok": false, "error": "invalid_camera_white_balance_mode"])
            }
            let temperatureKelvin: Int?
            switch mode {
            case .auto:
                guard number(args, "temperature_kelvin") == nil else {
                    return Self.json(["ok": false, "error": "automatic_white_balance_does_not_take_temperature"])
                }
                temperatureKelvin = nil
            case .manual:
                guard let temperature = number(args, "temperature_kelvin"),
                      temperature.isFinite,
                      temperature.rounded() == temperature,
                      (2_000...9_000).contains(Int(temperature)) else {
                    return Self.json(["ok": false, "error": "manual_white_balance_temperature_must_be_2000_to_9000"])
                }
                temperatureKelvin = Int(temperature)
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setCameraWhiteBalance(.init(mode: mode, temperatureKelvin: temperatureKelvin))
            )
        case "set_camera_exposure_lock":
            guard let locked = boolean(args, "locked") else {
                return Self.json(["ok": false, "error": "missing_camera_exposure_lock_state"])
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setCameraExposureLock(.init(locked: locked))
            )
        case "set_camera_focus":
            guard let mode = string(args, "mode").flatMap(CameraFocusMode.init(rawValue:)) else {
                return Self.json(["ok": false, "error": "invalid_camera_focus_mode"])
            }
            let position: Int?
            switch mode {
            case .auto:
                guard number(args, "position") == nil else {
                    return Self.json(["ok": false, "error": "automatic_focus_does_not_take_position"])
                }
                position = nil
            case .manual:
                guard let value = number(args, "position"), value.isFinite,
                      value.rounded() == value, (0...100).contains(Int(value)) else {
                    return Self.json(["ok": false, "error": "manual_focus_position_must_be_0_to_100"])
                }
                position = Int(value)
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setCameraFocus(.init(mode: mode, position: position))
            )
        case "set_camera_absolute_exposure":
            guard let mode = string(args, "mode").flatMap(CameraAbsoluteExposureMode.init(rawValue:)) else {
                return Self.json(["ok": false, "error": "invalid_camera_absolute_exposure_mode"])
            }
            let shutterCode: Int?
            switch mode {
            case .auto:
                guard number(args, "shutter_code") == nil else {
                    return Self.json(["ok": false, "error": "automatic_exposure_does_not_take_shutter_code"])
                }
                shutterCode = nil
            case .manual:
                guard let value = number(args, "shutter_code"), value.isFinite,
                      value.rounded() == value, (0...100).contains(Int(value)) else {
                    return Self.json(["ok": false, "error": "manual_exposure_shutter_code_must_be_0_to_100"])
                }
                shutterCode = Int(value)
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setCameraAbsoluteExposure(.init(mode: mode, shutterCode: shutterCode))
            )
        case "set_camera_face_priority":
            guard let enabled = boolean(args, "enabled") else {
                return Self.json(["ok": false, "error": "missing_camera_face_priority_state"])
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setCameraFacePriority(.init(enabled: enabled))
            )
        case "set_camera_anti_flicker":
            guard let mode = string(args, "mode").flatMap(CameraAntiFlickerMode.init(rawValue:)) else {
                return Self.json(["ok": false, "error": "invalid_camera_anti_flicker_mode"])
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setCameraAntiFlicker(.init(mode: mode))
            )
        case "set_camera_image_tuning":
            let brightness = imageTuningValue(args, "brightness")
            let contrast = imageTuningValue(args, "contrast")
            let hue = imageTuningValue(args, "hue")
            let saturation = imageTuningValue(args, "saturation")
            let sharpness = imageTuningValue(args, "sharpness")
            let values = [brightness, contrast, hue, saturation, sharpness]
            guard values.allSatisfy(\.valid), values.contains(where: { $0.value != nil }) else {
                return Self.json(["ok": false, "error": "camera_image_tuning_requires_one_integer_0_to_100"])
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setCameraImageTuning(.init(
                    brightness: brightness.value,
                    contrast: contrast.value,
                    hue: hue.value,
                    saturation: saturation.value,
                    sharpness: sharpness.value
                ))
            )
        case "set_native_human_tracking_policy":
            guard let speed = string(args, "speed").flatMap(NativeHumanTrackingSpeed.init(rawValue:)),
                  let motionTracking = boolean(args, "motion_tracking"),
                  let foreTarget = boolean(args, "fore_target"),
                  let adaptiveComposition = boolean(args, "adaptive_composition") else {
                return Self.json(["ok": false, "error": "invalid_native_human_tracking_policy"])
            }
            let adaptivePanGain = boolean(args, "adaptive_pan_gain") ?? false
            let adaptivePitchGain = boolean(args, "adaptive_pitch_gain") ?? false
            let panGain = number(args, "pan_gain")
            let pitchGain = number(args, "pitch_gain")
            let hasManualGain = panGain != nil || pitchGain != nil
            guard !hasManualGain || (
                panGain != nil && pitchGain != nil
                    && panGain!.isFinite && pitchGain!.isFinite
                    && (0.1...1.0).contains(panGain!) && (0.1...1.0).contains(pitchGain!)
                    && !adaptivePanGain && !adaptivePitchGain
            ) else {
                return Self.json(["ok": false, "error": "manual_native_tracking_gains_require_both_axes_0_1_to_1_0_and_adaptive_gains_disabled"])
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setNativeHumanTrackingPolicy(.init(
                    speed: speed,
                    motionTracking: motionTracking,
                    foreTarget: foreTarget,
                    adaptiveComposition: adaptiveComposition,
                    adaptivePanGain: adaptivePanGain,
                    adaptivePitchGain: adaptivePitchGain,
                    panGain: panGain,
                    pitchGain: pitchGain
                ))
            )
        case "set_camera_field_of_view":
            guard let degrees = number(args, "degrees"),
                  degrees.isFinite,
                  degrees.rounded() == degrees,
                  [65, 78, 86].contains(Int(degrees)) else {
                return Self.json(["ok": false, "error": "camera_field_of_view_must_be_65_78_or_86"])
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 5_000),
                operation: .setCameraFieldOfView(.init(degrees: Int(degrees)))
            )
        case "orient_attention":
            guard let bearing = bearing(args),
                  let motionStyle = string(args, "motion_style").flatMap(EmbodimentMotionStyle.init(rawValue:)) else {
                return Self.json(["ok": false, "error": "missing_orientation_goal"])
            }
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 12_000),
                operation: .orient(.init(bearing: bearing, motionStyle: motionStyle))
            )
        case "explore_attention":
            guard let mode = string(args, "mode").flatMap(ExplorationMode.init(rawValue:)) else {
                return Self.json(["ok": false, "error": "invalid_exploration_mode"])
            }
            let center = bearing(args)
            let azimuthRadius = number(args, "azimuth_radius_degrees")
            let elevationRadius = number(args, "elevation_radius_degrees")
            let regions: [SphericalSearchRegion]
            if let center, let azimuthRadius, let elevationRadius {
                regions = [.init(
                    center: center,
                    azimuthRadiusDegrees: azimuthRadius,
                    elevationRadiusDegrees: elevationRadius,
                    preference: 1
                )]
            } else if center != nil || azimuthRadius != nil || elevationRadius != nil {
                return Self.json(["ok": false, "error": "exploration_region_requires_center_and_both_radii"])
            } else {
                regions = []
            }
            let policy = ExplorationPolicyGoal(
                mode: mode,
                regions: regions,
                noveltyStrength: number(args, "novelty_strength") ?? 0.5,
                memoryGapStrength: number(args, "memory_gap_strength") ?? 0.5,
                motionContinuity: number(args, "motion_continuity") ?? 0.8,
                tempo: number(args, "tempo") ?? 0.5
            )
            return submit(
                reason: reason,
                durationMilliseconds: duration(args, fallback: 20_000),
                operation: .explore(policy)
            )
        case "release_attention":
            return submit(reason: reason, durationMilliseconds: 1_000, operation: .release)
        default:
            return nil
        }
    }

    /// Returns the one short-lived image produced by the immediately preceding
    /// capture tool call. The local path is never included in the model-facing
    /// tool result or in the scalar runtime trace.
    func consumeCaptureVisual() -> [L1VisualResource] {
        visualLock.lock()
        defer { visualLock.unlock() }
        guard !pendingCaptureVisuals.isEmpty else { return [] }
        return [pendingCaptureVisuals.removeFirst()]
    }

    private func captureTargetView(arguments: [String: Any], reason: String) -> String {
        let targetReference = string(arguments, "target_reference")
        let bearing = bearing(arguments)
        guard targetReference != nil || bearing != nil else {
            return Self.json(["ok": false, "error": "missing_target_reference_or_bearing"])
        }
        guard let requestedFOV = number(arguments, "field_of_view_degrees"),
              requestedFOV >= 5,
              requestedFOV <= 86 else {
            return Self.json(["ok": false, "error": "field_of_view_degrees_must_be_5_to_86"])
        }
        let durationMilliseconds = duration(arguments, fallback: 12_000)
        guard let submission = submitDecision(
            reason: reason,
            durationMilliseconds: durationMilliseconds,
            operation: .captureView(.init(
                targetReference: targetReference,
                bearing: bearing,
                fieldOfViewDegrees: requestedFOV
            ))
        ) else {
            return Self.json(["ok": false, "error": "l0_embodiment_unavailable"])
        }
        let decision = submission.decision
        guard decision.status != .rejected else {
            return decisionPayload(decision)
        }
        guard decision.snapshot.physicalActuationEnabled else {
            return Self.json([
                "ok": false,
                "error": "capture_target_view_requires_physical_l0_adapter",
                "request_id": decision.requestID,
            ])
        }
        guard let resource = relay.waitForCapture(
            requestID: decision.requestID,
            leaseExpiresAtNS: submission.leaseExpiresAtNS
        ) else {
            return Self.json([
                "ok": false,
                "error": "capture_wait_timeout",
                "request_id": decision.requestID,
            ])
        }
        guard resource.state == .ready,
              let imagePath = resource.imagePath,
              FileManager.default.isReadableFile(atPath: imagePath),
              let resourceExpiresAtNS = resource.resourceExpiresAtNS else {
            return Self.json([
                "ok": false,
                "error": resource.failureReason ?? resource.state.rawValue,
                "request_id": decision.requestID,
            ])
        }
        let remainingNS = resourceExpiresAtNS > DispatchTime.now().uptimeNanoseconds
            ? resourceExpiresAtNS - DispatchTime.now().uptimeNanoseconds
            : 0
        let visual = L1VisualResource(
            resourceID: "embodiment_capture:\(decision.requestID)",
            projection: .currentView,
            localPath: imagePath,
            expiresAt: Date().addingTimeInterval(TimeInterval(remainingNS) / 1_000_000_000)
        )
        visualLock.lock()
        pendingCaptureVisuals.append(visual)
        visualLock.unlock()
        return Self.json([
            "ok": true,
            "request_id": decision.requestID,
            "view_state": "ready",
            "view_resource_id": visual.resourceID,
            "width": resource.width ?? 0,
            "height": resource.height ?? 0,
            "field_of_view_degrees": resource.fieldOfViewDegrees ?? requestedFOV,
        ])
    }

    private func submit(
        reason: String,
        durationMilliseconds: UInt64,
        operation: CognitiveEmbodimentOperation
    ) -> String {
        guard let submission = submitDecision(
            reason: reason,
            durationMilliseconds: durationMilliseconds,
            operation: operation
        ) else {
            return Self.json(["ok": false, "error": "l0_embodiment_unavailable"])
        }
        return decisionPayload(submission.decision)
    }

    private func submitDecision(
        reason: String,
        durationMilliseconds: UInt64,
        operation: CognitiveEmbodimentOperation
    ) -> (decision: EmbodimentShadowDecision, leaseExpiresAtNS: UInt64)? {
        let now = DispatchTime.now().uptimeNanoseconds
        let lease = EmbodimentLease(
            ownerID: ownerID,
            priority: priority,
            issuedAtNS: now,
            durationMilliseconds: durationMilliseconds,
            cancellationToken: "l1-cancel-\(UUID().uuidString.lowercased())"
        )
        let request = CognitiveEmbodimentRequest(
            requestID: "l1-embodiment-\(UUID().uuidString.lowercased())",
            layer: .l1,
            reason: reason,
            evidenceIDs: ["l1_tool:\(operation.kind.rawValue)"],
            lease: lease,
            operation: operation
        )
        guard let decision = relay.submit(request) else { return nil }
        return (decision, lease.expiresAtNS)
    }

    private func decisionPayload(_ decision: EmbodimentShadowDecision) -> String {
        let binding = decision.snapshot.targetBindings.first {
            $0.targetReference == decision.snapshot.activeTargetReference
        }
        var payload: [String: Any] = [
            "ok": decision.status != EmbodimentShadowStatus.rejected,
            "status": decision.status.rawValue,
            "operation": decision.operation.rawValue,
            "decision_reason": decision.reason,
            "request_id": decision.requestID,
            "physical_actuation_enabled": decision.snapshot.physicalActuationEnabled,
        ]
        if let binding {
            payload["binding_status"] = binding.status.rawValue
            payload["bound_scene_id"] = binding.sceneID ?? ""
            payload["binding_confidence"] = binding.posteriorProbability
        }
        return Self.json(payload)
    }

    private func sceneInventory() -> String {
        guard let snapshot = relay.snapshot() else {
            return Self.json(["ok": false, "error": "l0_embodiment_unavailable"])
        }
        let entities: [[String: Any]] = snapshot.sceneEntities.prefix(24).map { entity in
            var value: [String: Any] = [
                "scene_id": entity.sceneID,
                "kind": entity.kind.rawValue,
                "label": entity.label ?? "unlabeled",
                "confidence": entity.confidence,
                "observed_now": entity.observedThisFrame,
                "action_eligible": entity.actionEligible,
                "spatial_confidence": entity.spatialConfidence,
                "last_seen_ms": entity.lastSeenMilliseconds,
            ]
            if let bearing = entity.bearing {
                value["azimuth_degrees"] = bearing.azimuthDegrees
                value["elevation_degrees"] = bearing.elevationDegrees
            }
            return value
        }
        let bindings: [[String: Any]] = snapshot.targetBindings.prefix(24).map {
            [
                "target_reference": $0.targetReference,
                "scene_id": $0.sceneID ?? "",
                "status": $0.status.rawValue,
                "posterior_probability": $0.posteriorProbability,
                "observed_now": $0.observedThisFrame,
            ]
        }
        return Self.json([
            "ok": true,
            "mode": snapshot.mode,
            "active_request_id": snapshot.activeRequestID ?? "",
            "active_operation": snapshot.activeOperation?.rawValue ?? "",
            "scene_entities": entities,
            "bindings": bindings,
        ])
    }

    private func duration(_ args: [String: Any], fallback: UInt64) -> UInt64 {
        guard let value = number(args, "lease_ms"), value.isFinite else { return fallback }
        return UInt64(min(max(value.rounded(.towardZero), 1), 600_000))
    }

    private func bearing(_ args: [String: Any]) -> GimbalRelativeBearing? {
        guard let azimuth = number(args, "azimuth_degrees"),
              let elevation = number(args, "elevation_degrees") else { return nil }
        return GimbalRelativeBearing(azimuthDegrees: azimuth, elevationDegrees: elevation)
    }

    private func normalizedRect(_ args: [String: Any]) -> (value: NormalizedRect?, error: String?) {
        let values = [
            number(args, "framing_x"),
            number(args, "framing_y"),
            number(args, "framing_width"),
            number(args, "framing_height"),
        ]
        guard values.contains(where: { $0 != nil }) else { return (nil, nil) }
        guard let x = values[0], let y = values[1], let width = values[2], let height = values[3],
              x >= 0, y >= 0, width > 0, height > 0, x + width <= 1, y + height <= 1 else {
            return (nil, "framing_requires_four_normalized_values")
        }
        return (.init(x: x, y: y, width: width, height: height), nil)
    }

    private func string(_ args: [String: Any], _ key: String) -> String? {
        guard let value = args[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(240))
    }

    private func number(_ args: [String: Any], _ key: String) -> Double? {
        if let number = args[key] as? NSNumber { return number.doubleValue }
        if let text = args[key] as? String { return Double(text) }
        return nil
    }

    private func boolean(_ args: [String: Any], _ key: String) -> Bool? {
        if let value = args[key] as? Bool { return value }
        if let value = args[key] as? NSNumber { return value.boolValue }
        if let value = args[key] as? String {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private func imageTuningValue(_ args: [String: Any], _ key: String) -> (valid: Bool, value: Int?) {
        guard args[key] != nil else { return (true, nil) }
        guard let value = number(args, key), value.isFinite,
              value.rounded() == value, (0...100).contains(Int(value)) else {
            return (false, nil)
        }
        return (true, Int(value))
    }

    private static let toolNames: Set<String> = [
        "inspect_scene", "register_attention_target", "set_target_attention",
        "track_attention_target", "capture_target_view", "orient_attention",
        "explore_attention", "set_camera_optical_zoom", "set_audio_capture_mode", "set_audio_input_gain", "set_camera_white_balance", "set_camera_exposure_lock", "set_camera_focus", "set_camera_absolute_exposure", "set_camera_face_priority", "set_camera_anti_flicker", "set_camera_image_tuning", "set_native_human_tracking_policy", "set_camera_field_of_view", "release_attention",
    ]

    private func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: OllamaToolDefinition.Function.Property],
        required: [String]
    ) -> OllamaToolDefinition {
        .init(function: .init(
            name: name,
            description: description,
            parameters: .init(properties: properties, required: required)
        ))
    }

    private func property(_ description: String) -> OllamaToolDefinition.Function.Property {
        .init(type: "string", description: description)
    }

    private func numberProperty(_ description: String) -> OllamaToolDefinition.Function.Property {
        .init(type: "number", description: description)
    }

    private func booleanProperty(_ description: String) -> OllamaToolDefinition.Function.Property {
        .init(type: "boolean", description: description)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return #"{\"ok\":false,\"error\":\"encoding_failed\"}"#
        }
        return value
    }
}
