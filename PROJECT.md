# SOMA

## Project objective

Build an embodied, intelligently responsive assistant around the connected
OBSBOT Tiny 2 Lite. The system has three cognitive layers distinguished by
response time and responsibility:

| Layer | Responsibility |
| --- | --- |
| Subconscious | Always-on, low-latency perception and reflexive attention control. |
| Conscious L1 | Short-horizon dialogue and deliberate interaction decisions. |
| Conscious L2 | Long-horizon reasoning, reflection, planning, and memory. |

The first milestone is the **subconscious** layer. It must keep the assistant
oriented to the relevant person or hand, recognize that interaction may be
starting, and emit compact evidence for L1 before conversational reasoning is
needed.

## Subconscious v0 scope

### Inputs

- Timestamped UVC video frames from the Tiny 2 Lite.
- Timestamped audio blocks from the Tiny 2 Lite microphone.
- Camera state: pan, tilt, zoom, tracking mode, target-lock state, and device
  availability.

### Outputs

- A single active attention target, its confidence, screen-space position, and
  track-loss state.
- One camera-control request at a time: built-in tracking mode or external
  pan/tilt/zoom control.
- Interaction-readiness events such as voice activity, likely address to the
  assistant, user present/absent, and attention gained/lost.
- Low-cost intent hints for L1. These are evidence, not dialogue decisions.

### Hard boundaries

- The real-time loop must not wait for an LLM, cloud call, transcription, or
  L1/L2 response.
- OBSBOT built-in AI tracking and external gimbal control are mutually
  exclusive camera-control states. Firmware tracking owns the gimbal while
  enabled; external control must first disable it.
- The subconscious layer may prepare an interaction but cannot speak, send a
  message, or execute a user request. Those actions belong to L1 or L2.
- Every perception and actuator event carries a monotonic timestamp so actual
  capture-to-command and capture-to-event latency can be measured before an
  SLO is fixed.

## Hardware facts established from device references

- Target device: OBSBOT Tiny 2 Lite, an AI-powered USB PTZ webcam with a
  two-axis brushless gimbal and dual microphones.
- Mechanical bounds: pan +/-140 degrees; tilt +30/-70 degrees.
- Video/optics: 4K UVC video, auto/manual focus, and 1x-4x digital zoom.
- Native attention primitives: single-human, group, upper-body, close-up, and
  hand tracking. Tiny 2 Lite supports normal, upper-body, close-up, and group
  modes through its OSC definition.
- The connected macOS host detects `OBSBOT Tiny 2 Lite Microphone` as a USB,
  two-channel, 32 kHz input. It is not currently the default system input.

## Control surface

- The open macOS bridge identifies Tiny 2 Lite by USB `3564:fef9` and exposes
  measured pose, AI mode selection, absolute zoom, sleep/wake, and direct
  gimbal velocity through validated UVC/XU requests.
- The supplied OSC definition exposes device selection, wake/sleep, gimbal
  stop/directional/absolute control, zoom, AI lock, AI mode, tracking-mode,
  and tracking-status queries. OSC is a useful integration boundary after the
  baseline loop works.
- Device attitude readback is an observability channel, not the source of
  visual target coordinates. Video perception remains the source of truth for
  an external control loop.

## First implementation decision

Start with a read-only perception-and-event pipeline, then add camera
actuation behind an explicit state machine:

1. Capture and timestamp video/audio while logging device availability.
2. Produce presence, voice-activity, and attention-target events without
   moving the camera.
3. Validate the native human/group/hand-tracking control path.
4. Add external visual tracking only after selecting one control owner and
   measuring the end-to-end latency and stability of each path.

This order keeps the initial reflex layer observable and safe while preserving
the option to choose the better tracking controller from evidence.

## References reviewed

- `Reference/OBSBOTTiny2LiteUserManual_ENv1.1.pdf`
- `Reference/OBSBOT_Tiny 3 Lite 사용설명서_KR_v1.0.pdf`
- `Sources/SOMANativeTracking/OpenOBSBOTUVCTransport.cpp`
- `Sources/SOMANativeTracking/OpenOBSBOTContract.hpp`
- `Reference/OSC/obsbot_center_osc_definition20250314.xlsx`
- `Reference/OSC/OBSBOT Webcam Sample-TCP.tosc`
- `Reference/OSC/OBSBOT Webcam Sample-UDP.tosc`
