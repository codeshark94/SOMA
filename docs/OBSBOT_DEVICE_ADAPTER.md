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

## Control-plane recovery

Video and audio capture do not share the vendor control endpoint. A healthy
media stream therefore does not imply that gimbal, tracking, audio-mode, or
indicator writes are available. `OpenOBSBOTUVCTransport` maintains an explicit
control-plane state independent of capture health.

The first failed UVC/XU transfer closes and releases the stale IOKit device
interface. Further writes are held by a circuit breaker rather than retried
against that handle. Reconnection uses the original product profile and USB
serial identity; devices without a serial are constrained to their macOS USB
`locationID` instead. That fallback binds recovery to the same USB topology,
not to a cryptographically unique device, because the hardware exposes no
serial. The rebound endpoint must pass both an attitude read and a
zero-velocity vendor write before entering provisional restoration. It becomes
healthy only after the safe stop and current state have also been restored.
Failed attempts retain their failure streak and use bounded backoff from 100 ms
to 5 seconds.

After a verified reconnect, the bridge first disables native tracking and
commands zero velocity. It then restores only a current native-tracking lease,
a still-live external motion intent, or a non-expired absolute position. The
most recent semantic indicator presentation, brightness, and enabled state are
reapplied once. Expired motion and recenter requests are not replayed. Recovery
transitions include the raw macOS `IOReturn`, retry count, endpoint generation,
and next-attempt delay in the actuator trace.

Velocity direction changes are segmented at the device boundary. An axis that
reaches neutral or requests the opposite sign first holds a zero-velocity
segment until consecutive measured attitudes show that the physical gimbal has
settled; only then can the next segment reach firmware. This invariant is
applied to L0 exploration and to direct L1, L2, and MCP velocity requests. The
bridge records `external_direction_neutralized` when it has to enforce the
boundary itself.

Accepted control transfers without measured attitude change are treated as a
functional motor stall, not immediately as proof of a dead device. The bridge
expires every motor intent and performs a bounded measured-motion probe. It
resumes only after observed motion, requests endpoint recovery if the probe
cannot run, and enters the physical-reconnect state only when the probe is
accepted but produces no motion.

Lifecycle transitions are also physical, not acknowledgement-driven. Every
recenter path first submits zero velocity and waits for consecutive stable
attitude samples. Recenter succeeds only after the centered pose is both
reached and stable. Shutdown then issues sleep only after that proof and
completes only after consecutive rest-pose samples. A failed tracking stop,
motion stop, pose read, center, or rest verification holds the transition; it
never advances to the next motor state.

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
