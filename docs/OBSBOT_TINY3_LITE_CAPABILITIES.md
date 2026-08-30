# OBSBOT Tiny 3 Lite capability matrix

Validated device: OBSBOT Tiny 3 Lite, firmware `6.5.10.1`, USB `3564:ff04`.

This matrix distinguishes the current open UVC/XU driver from controls that
were previously characterized but have not yet been migrated. An accepted USB
request is not treated as physical validation.

| Domain | Control | SOMA path | Evidence | Status |
| --- | --- | --- | --- | --- |
| Gimbal | measured pose | L0 native bridge | standard UVC pan/tilt absolute readback | active |
| Gimbal | health, limit, warning, and error telemetry | none | no open readback contract has been established | withheld; the bridge does not fabricate healthy telemetry |
| Gimbal | pose and velocity commands | L0 route controller | profile-calibrated actuation plus measured pose change and arrival checks | active |
| Native target tracking | select a human center or face ROI | L0 native bridge | open human-to-portrait transition and selected-target V3 request; installed runtime acquired and followed a live face after transport cutover | active |
| Native target tracking | speed, retention, composition, and gain policy | none | open parameter wire contract is not yet complete | withheld rather than reporting false success |
| Optical framing | absolute zoom | L0, L1 tool, embodiment MCP | standard UVC zoom range query and absolute setter | active setter; current-value readback and transactional restore are not yet exposed |
| Optical framing | FOV 86, 78, or 65 degrees | none | product-specific open control has not been migrated | withheld |
| Face imaging | face-priority autofocus and auto-exposure | none | product-specific open control has not been migrated | withheld |
| Lens | auto or absolute manual focus | none | standard UVC control mapping has not been migrated | withheld |
| Imaging | auto/manual white balance | none | standard UVC control mapping has not been migrated | withheld |
| Imaging | AE lock | none | product-specific open control has not been migrated | withheld |
| Imaging | anti-flicker: off, 50 Hz, 60 Hz, auto | none | standard UVC control mapping has not been migrated | withheld |
| Imaging | auto or absolute manual exposure | none | standard UVC control mapping has not been migrated | withheld |
| Imaging | exposure mode, ISO limits, EV bias, mirror/flip | startup inventory | fully readable: auto exposure, ISO 100–7813, EV 0 over a 0–18 range, mirror/flip 0 | observed; mutable controls remain withheld until a visual task requires them |
| Imaging | brightness, contrast, hue, saturation, sharpness | none | standard UVC control mapping has not been migrated | withheld |
| Imaging | WDR | none | no open control contract has been established | withheld |
| Audio | omni, spatial stereo, conversation front, bidirectional, music | L0, L1 tool, embodiment MCP | product-specific UVC/XU setter on firmware `6.5.10.1` | active setter; state readback is not yet exposed |
| Audio | microphone input gain `0...100` | none | open setter/readback contract is not yet complete | withheld rather than reporting false success |
| Audio | VQE: none, talk, vlog | none | current state `none` is readable; `talk` setter returned success but the immediate state query failed, then `none` restored | withheld: a success return without durable readback is not a usable SOMA control |
| Audio | rear capture mode | none | setter returned success but camera status remained spatial stereo | withheld on firmware `6.5.10.1` |
| Audio | firmware sound following | diagnostic transport only | the enable/disable request is accepted, but repeated bounded trials produced no measured gimbal response | withheld; not advertised to L0, L1, or L2 until physical sound-turn validation succeeds |
| Audio | firmware sound-follow distance | none | only `doa_range=1` persisted; values 2 and 3 silently remained 0 | withheld until its physical semantics are established |
| Audio | audio distance field | none | `cameraSetAudioDistanceU` state round-trip verified for values 0, 1, and 2; 3, 4, and 15 silently reported 0 | withheld until the firmware's three distance settings and acoustic effect are established |
| Audio | raw sound bearing | none | firmware does not expose a host-readable direction | calibration required |
| LED | enabled and brightness | L0 indicator session | open firmware setters used by the device-specific pulse transport | active setters; state readback is not yet exposed |
| LED | semantic exploration, human-presence, contact-ready, and conversation presentations | L0 indicator session | firmware state-machine reconstruction plus physical validation of green, blue, and yellow routes | active |
| LED | direct RGB candidate | none | the private three-byte packet accepted transport but never produced a durable physical presentation | invalid; removed from the adapter contract |
| Target framing | target view and target zoom presets | none | no Tiny 3 Lite open control contract has been established | withheld |
| System | factory reset, firmware update, sleep, recording | none | destructive or outside embodied interaction | intentionally unavailable |

## LED evidence ledger

The Tiny 3 Lite adapter owns the LED mapping. Cognitive code requests a
semantic state only; it must not send raw state IDs or RGB values.

| Semantic presentation | Active device route | Evidence status |
| --- | --- | --- |
| Exploration / no selected target | `SYSTEM_READY(3)` + `NORMAL_WORKMODE(54)` | physically verified steady green; the native indicator session establishes and restores both states |
| Human presence / native tracking | `SYSTEM_READY(3)` + `TRACK_WORKMODE(57)` | physically verified steady blue |
| Contact ready | state `57` with the configured contact cadence | physically verified blue route; cadence is owned by the indicator session |
| Conversation | `AI_TARGET_LOSE(16)` reused as the firmware yellow presentation | physically verified steady yellow; cleared when conversation ends |

Tiny 3 Lite exposes a firmware status machine rather than an arbitrary RGB
surface. The vendor manual and the recovered `6.5.10.1` state machine agree on
the complete native presentation vocabulary:

| Firmware condition | Vendor presentation | Firmware state evidence | SOMA policy |
| --- | --- | --- | --- |
| device initialization | blue cyclic animation | incomplete ready/work-mode state set | observed only |
| no tracking target selected | steady green | `SYSTEM_READY(3)` + `NORMAL_WORKMODE(54)` | exploration baseline |
| gesture or voice feedback | blink the current presentation twice, then restore it | `AI_GESTURE_RECOGNIZING(18)` and `DOA_SPEECH_RECOGNIZED(52)` | reserved for native feedback |
| human tracking active | steady blue | `SYSTEM_READY(3)` + `TRACK_WORKMODE(57)` | human presence |
| tracking target lost | steady yellow | `AI_TARGET_LOSE(16)` | yellow palette route |
| hand tracking active | steady purple | `SYSTEM_READY(3)` + `HANDSTRACK_WORKMODE(59)` | not used by SOMA |
| firmware upgrade | blue/yellow mixed animation | `UPGRADE_UPGRADING(30)` | never issued by SOMA |
| firmware upgrade failure | slowly blinking red | `UPGRADE_ERROR(29)` | never issued by SOMA |
| AI or device malfunction | steady red | `AI_ERROR(15)` and related error states | diagnostic output only |
| privacy mode | off | device privacy state | firmware-owned |

State-changing diagnostics must not clear a state that may already belong to
the firmware baseline. The production bridge therefore keeps state `3`
persistent, changes only the active semantic work state, and restores `3 + 54`
on release or shutdown.

## Firmware-image boundary

An inspected `6.5.9.1` update image is an OBSBOT PW105/OA_E release bundle,
not an API contract for the running `6.5.10.1` device. Its payload names the
gimbal, camera, Bluetooth, and receiver components and contains internal DOA,
voice-tracking, target-tracking, and RGB-processing symbols. That establishes
that those subsystems exist inside firmware; it does **not** establish a safe
host control or a host-readable sound bearing. SOMA exposes a firmware
subsystem only after the connected camera accepts it and SOMA obtains the
capability-specific physical or readback evidence stated above.

## Evidence rules

SOMA treats physical motion, a stable LED state, sensor readback, or a
restored direct probe as evidence. A successful USB return code alone is not
enough to promote a control to `active`.

## Compatibility boundary

The device profile is the only layer that maps an abstract L0 command onto an
OBSBOT product. Cognitive layers issue semantic requests through the
embodiment arbiter; they cannot send raw device packets or bypass motor
ownership, pose feedback, route planning, limits, or fail-safe release.
