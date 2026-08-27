# OBSBOT Tiny 3 Lite capability matrix

Validated device: OBSBOT Tiny 3 Lite, firmware `6.5.10.1`, USB `3564:ff04`.

This matrix distinguishes host-visible SDK declarations from controls that the
connected firmware accepted and reported back. A declaration is not treated as
a SOMA capability until its active-device behavior has been verified.

| Domain | Control | SOMA path | Evidence | Status |
| --- | --- | --- | --- | --- |
| Gimbal | measured pose | L0 native bridge | `gimbalGetAttitudeInfoR` | active |
| Gimbal | health, limit, warning, and error telemetry | L0 native bridge diagnostics | `gimbalGetAllInfo` exported by the connected `libdev`; live runtime readback returns `result=0`, `warning_flags=0`, and `error_flags=0` | active diagnostic; it observes hardware state and does not issue motor commands |
| Gimbal | pose and velocity commands | L0 route controller | profile-calibrated actuation and firmware ACKs | active |
| Native target tracking | select a human center or face ROI | L0 native bridge | `aiSetSelectedTargetR` and firmware mode transition | active control; physical lock/release validation pending |
| Native target tracking | human, animal, and object control surface: speed, motion retention, fore-target retention, adaptive composition, adaptive pan/pitch gain, fixed pan/pitch gain, auto-zoom, framing offsets, and target limits | firmware inventory | all three target classes are getter-readable on the connected device; fixed gain range `0.1...1.0` was verified directly with restore for the human policy | human policy is active through L0, L1 tool, and embodiment MCP; animal/object selection remains withheld pending a physical selection and release test |
| Optical framing | absolute zoom | L0, L1 tool, embodiment MCP | set/get/restore | active |
| Optical framing | FOV 86, 78, or 65 degrees | L0, L1 tool, embodiment MCP | firmware status readback | active |
| Face imaging | face-priority autofocus and auto-exposure | L0, L1 tool, embodiment MCP | both camera-status bits set and restored | active |
| Lens | auto or absolute manual focus | L0, L1 tool, embodiment MCP | active-device range `0...100` with step `1`; manual `50` set/read/restore test passed and automatic mode was restored | active; automatic focus remains the normal perception state |
| Imaging | auto/manual white balance | L0, L1 tool, embodiment MCP | set/get/restore | active |
| Imaging | AE lock | L0, L1 tool, embodiment MCP | set/get/restore | active |
| Imaging | anti-flicker: off, 50 Hz, 60 Hz, auto | L0, L1 tool, embodiment MCP | set/get/restore | active |
| Imaging | auto or absolute manual exposure | L0, L1 tool, embodiment MCP | active-device shutter-code range `10...42` with step `1`; manual `33` set/read/restore test passed and automatic mode was restored | active; automatic exposure remains the normal perception state |
| Imaging | exposure mode, ISO limits, EV bias, mirror/flip | startup inventory | fully readable: auto exposure, ISO 100–7813, EV 0 over a 0–18 range, mirror/flip 0 | observed; mutable controls remain withheld until a visual task requires them |
| Imaging | brightness, contrast, hue, saturation, sharpness | L0, L1 tool, embodiment MCP | range preflight, transaction readback, failure rollback | active |
| Imaging | WDR | startup inventory | firmware getter; SDK support excludes Tiny 3 Lite | withheld |
| Audio | omni, spatial stereo, conversation front, bidirectional, music | L0, L1 tool, embodiment MCP | set/status/restore on firmware `6.5.10.1` | active |
| Audio | microphone input gain `0...100` | L0, L1 tool, embodiment MCP | direct active-device `40 → 60 → 40` set/readback/restore test passed | active |
| Audio | VQE: none, talk, vlog | none | current state `none` is readable; `talk` setter returned success but the immediate state query failed, then `none` restored | withheld: a success return without durable readback is not a usable SOMA control |
| Audio | rear capture mode | none | setter returned success but camera status remained spatial stereo | withheld on firmware `6.5.10.1` |
| Audio | firmware sound following | L0, L1 tool, embodiment MCP | enable/readback/disable and a bounded L0 lease; firmware contains a multichannel audio/DOA queue and an internal gimbal find-by-DOA path | active configuration; physical sound-turn validation pending |
| Audio | firmware sound-follow distance | none | only `doa_range=1` persisted; values 2 and 3 silently remained 0 | withheld until its physical semantics are established |
| Audio | audio distance field | none | `cameraSetAudioDistanceU` state round-trip verified for values 0, 1, and 2; 3, 4, and 15 silently reported 0 | withheld until the firmware's three distance settings and acoustic effect are established |
| Audio | raw sound bearing | none | firmware does not expose a host-readable direction | calibration required |
| LED | enabled and brightness | L0 indicator session | getter/setter | active |
| LED | firmware status states | none | `sysMgSetIndicatorStateR` / `sysMgClearIndicatorStateR` are documented for a different OBSBOT product family; their asynchronous acknowledgement does not establish Tiny 3 Lite semantics | withheld |
| LED | direct blue social signal | L0 indicator session | Tiny 3's observed RGB request `cmd_set=13`, `cmd_id=456`, payload `0,0,255` renders blue on firmware `6.5.10.1` | active for human presence; eye contact uses a direct-RGB brightness cadence without state-ID requests |
| LED | arbitrary RGB and firmware-native patterns | none | the running firmware contains internal RGB palette and pattern routines, but the public host SDK exposes only status-state selection, enablement, and brightness | withheld: the blue diagnostic does not establish a general RGB command surface |
| Target framing | target view and target zoom presets | none | SDK documentation marks view presets as Air-series specific and offers no getter | withheld |
| System | factory reset, firmware update, sleep, recording | none | destructive or outside embodied interaction | intentionally unavailable |

## Firmware-image boundary

The supplied `6.5.9.1` update image is an OBSBOT PW105/OA_E release bundle,
not an API contract for the running `6.5.10.1` device. Its payload names the
gimbal, camera, Bluetooth, and receiver components and contains internal DOA,
voice-tracking, target-tracking, and RGB-processing symbols. That establishes
that those subsystems exist inside firmware; it does **not** establish a safe
host control or a host-readable sound bearing. SOMA exposes a firmware
subsystem only after the connected camera accepts it and reports its state.

## Evidence rules

SOMA treats physical motion, a stable LED state, sensor readback, or a
restored direct probe as evidence. A successful SDK return code alone is not
enough to promote a control to `active`.

## Compatibility boundary

The device profile is the only layer that maps an abstract L0 command onto an
OBSBOT product. Cognitive layers issue semantic requests through the
embodiment arbiter; they cannot send raw SDK commands or bypass motor
ownership, pose feedback, route planning, limits, or fail-safe release.
