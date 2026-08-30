# OBSBOT open-device contract

SOMA separates perception and cognition from product-specific physical
control. The native helper uses macOS IOKit to issue UVC camera-terminal and
extension-unit requests directly; no OBSBOT SDK or redistributed vendor binary
is required.

`soma-obsbot-probe` and `soma-native-track` emit the same versioned
`SOMA_OBSBOT_CAPABILITY` line. The launcher passes that exact line to the
runtime as `SOMA_OBSBOT_CAPABILITY_CONTRACT`; it does not infer hardware from a
camera display name.

The boundary has one direction:

1. L0, L1, L2, settings, and MCP issue semantic requests.
2. `OBSBOTDeviceContract` advertises only capabilities of the detected USB
   product.
3. `OpenOBSBOTProtocol` owns product identity, opcodes, receivers, payload
   widths, and axis encoding; native protocol tests prevent cross-profile
   packet leakage.
4. `OpenOBSBOTUVCTransport` submits those typed requests through the product's
   validated UVC/XU controls.
5. `soma-native-track` serializes ownership, applies watchdog stops, reconciles
   temporary indicator state, and reports outcomes.

No cognitive or UI layer owns product IDs, transport opcodes, LED state IDs,
or packet layouts.

## Supported products

| Product | USB identity | Native control dependency |
| --- | --- | --- |
| Tiny 2 Lite | `3564:fef9` | macOS IOKit UVC/XU |
| Tiny 3 Lite | `3564:ff04` | macOS IOKit UVC/XU |
| unknown | unmatched | perception and conversation only |

The probe opens the matching USB control endpoint before advertising a
contract. Zero devices fails closed. More than one supported device also fails
closed until explicit USB-path binding is implemented, preventing commands
from being sent to an arbitrary camera.

## Authority levels

| Contract state | Enabled behaviour |
| --- | --- |
| no valid contract | perception and conversation only |
| valid contract without matching calibration | device observation and supported LED/audio controls; no autonomous direct gimbal movement |
| valid contract with matching calibration | L0 tracking, exploration, and higher-layer motion leases within profile limits |

The motion gate checks both `native_bridge` and a calibration whose
`deviceIdentifier` matches the detected profile. A product name alone never
grants gimbal authority.

## Profile differences

| Capability | Tiny 2 Lite | Tiny 3 Lite |
| --- | --- | --- |
| native human tracking | selector-6 human mode | human-to-portrait transition plus selected human ROI |
| direct velocity | float V3 command | centidegree-per-second V3 command |
| recenter | measured-pose closed loop | firmware recenter command with measured settle verification |
| indicator | states `54`, `57`, `16`; brightness-dimmed pulse | persistent state `3` plus states `54`, `57`, `16`; enable-toggled pulse |
| audio modes | not exposed | omni, stereo, front, bidirectional, music |
| firmware sound following | unavailable | experimental transport only; not advertised to production cognition |

Direct arbitrary RGB is not part of either contract. Cognitive code requests a
semantic presentation; only the native profile maps it to a firmware state.

## Adding a product

1. Add the exact VID/PID and typed packet codec in `OpenOBSBOTProtocol`, plus a
   profile contract in `OpenOBSBOTContract`.
2. Implement product-specific commands behind the existing semantic methods.
3. Add protocol regression cases and run CTest before any physical request.
4. Run `soma-obsbot-probe --contract` and `--read-attitude` without motion.
5. Create matching gimbal and camera-geometry calibrations.
6. Validate indicator, native tracking acquisition/release, stop, pose,
   bounded velocity, recenter, and sleep on the physical device.

An accepted USB write is transport evidence, not physical acceptance. A new
profile remains incomplete until its visible movement and indicator behaviour
are observed on hardware.
