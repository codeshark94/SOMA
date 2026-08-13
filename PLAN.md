# Subconscious v0 execution plan

## Definition of done

Subconscious v0 is complete when the connected Tiny 2 Lite can continuously
produce timestamped, local events for presence, one attention target, target
loss, voice activity, interaction readiness, and low-cost intent hints. The
result must be observable in a trace, must not depend on L1/L2, and must leave
the camera stationary until a separate actuator stage is explicitly enabled.

An intent hint is a confidence-bearing cue such as `wake_gesture`,
`user_present`, `voice_activity`, or `attention_gained`; it is not a semantic
interpretation of a sentence and cannot trigger speech or an external action.

## Design constraints

- Use the Tiny 2 Lite explicitly as the video and audio source; never change
  the macOS default microphone.
- Keep the real-time path local. It must not wait for an LLM, cloud service,
  batch transcription, disk I/O, or a conversational response.
- Use bounded, latest-value queues between capture, perception, and control.
  Stale frames are discarded rather than allowed to accumulate.
- Record monotonic timestamps at input, inference completion, event emission,
  command send, and actuator acknowledgement. Establish latency SLOs only
  after this baseline exists.
- Do not infer speaker direction from the dual microphones until a calibrated
  experiment establishes that the device exposes stable directional evidence.
- A camera command always has exactly one owner. The valid owners are
  `manual`, `native_ai`, `external`, and `fault`.

## Execution stages

| Stage | Deliverable | Verification / decision gate |
| --- | --- | --- |
| P0 - hardware contract | Read-only probe for the actual UVC camera, OBSBOT microphone, permissions, available video formats, and device identity. | A 60-second capture has continuous monotonic audio/video timestamps, reports source names and failures, and sends no camera command. |
| P1 - event and trace contract | Small versioned event schema plus a bounded local trace writer. | A replay of a fixed short capture preserves event ordering and computes capture-to-event latency; no event needs an LLM response. |
| P2 - perception loop | Latest-frame person/face/hand detection, target selection, temporal tracker, and audio VAD. | A single nearby person stays the active target through ordinary movement; loss is reported rather than silently switching identities. |
| P3 - interaction preparation | State estimator combining target continuity, voice activity, visible gesture, and idle time into readiness and intent-hint events. | The system emits evidence and confidence only; it emits no text, speech, command execution, or ungrounded semantic intent. |
| P4 - native tracking evaluation | Controlled comparison of the Tiny 2 Lite's native human/group/hand tracking modes. | Logs show start, lock/loss, stop, and camera state for each mode. Native tracking remains disabled by default after the test. |
| P5 - actuator state machine | One-owner camera arbiter, manual stop, native-AI control, and optional external pan/tilt/zoom control. | AI and direct control cannot overlap; disconnect, failed acknowledgement, or explicit stop enters `fault` or `manual` and sends zero-speed/stop as applicable. |
| P6 - end-to-end evaluation | Repeatable, consented scenarios and a baseline report. | Compare native and external paths for latency, target retention, overshoot, recovery after loss, and false readiness events. Choose one control owner for the next milestone. |

## P0: first implementation slice

The next coding task is P0 only. It is deliberately read-only.

1. Enumerate camera and audio devices and select the OBSBOT devices by their
   actual host identifiers, not a fragile ordinal index.
2. Open video and 32 kHz stereo audio independently, request a modest initial
   format, and record the negotiated format.
3. Attach a monotonic timestamp at each capture callback; report dropped
   frames, audio gaps, and reconnects.
4. Produce a short JSONL trace containing health events only.
5. Run a 60-second unattended capture, inspect the trace, and stop cleanly.

P0 explicitly excludes object detection, VAD, OSC, SDK camera commands,
recording user media, and changing any system input setting.

## Event contract for P1

Every event is local, append-only, schema-versioned, and includes
`monotonic_ns`, `source`, and `confidence` when applicable.

| Event | Minimum payload |
| --- | --- |
| `source.health` | source identifier, negotiated format, connected/disconnected, error code |
| `video.frame` | capture timestamp, sequence number, dimensions, dropped-frame count |
| `audio.block` | capture timestamp, sequence number, sample rate, channels, gap count |
| `attention.target` | stable target id, bounding box, confidence, target state |
| `presence` | present/absent/unknown and confidence |
| `voice.activity` | active/inactive, confidence, onset/offset timestamp |
| `interaction.readiness` | idle/observing/ready/engaged and supporting cue ids |
| `intent.hint` | cue name, confidence, supporting event ids |
| `camera.command` / `camera.ack` | owner, command id, requested state, acknowledgement or error |

Raw audio and video are not part of the default trace. P6 may use short,
consented recordings only when they are needed to reproduce a defect or score
a fixed scenario.

## Attention and readiness policy

P2 and P3 use an explicit state estimator rather than a black-box dialogue
model:

| State | Entry evidence | Exit evidence |
| --- | --- | --- |
| `idle` | no reliable person or interaction cue | reliable person appears |
| `observing` | a stable person target | loss timeout, or readiness evidence |
| `ready` | stable target plus voice activity, wake gesture, or direct-engagement cue | cue expires, target loss, or L1 accepts the handoff |
| `engaged` | L1 explicitly claims the interaction | L1 release or loss timeout |

Target selection is deterministic: retain the current target while it remains
credible; choose a new target only after a loss timeout or an explicit
priority cue. This avoids attention flicker when several people enter view.

## Camera-control decision tree

1. P0-P3: camera owner is `manual`; no commands are emitted.
2. P4: the operator explicitly enters `native_ai`; test one native tracking
   mode at a time and return to `manual` when the test ends.
3. P5: `external` can be entered only after native AI is disabled and camera
   state confirms it. The controller respects the documented pan/tilt bounds,
   uses hysteresis and a command rate limit, and sends stop on target loss.
4. Any device disconnect, acknowledgement timeout, unexpected owner, or
   manual stop enters `fault`/`manual`; external movement is disabled until a
   new explicit enable.

## Measures collected from the first trace

- Video frame interval, jitter, and drops.
- Audio block interval, gaps, and drift relative to video timestamps.
- Capture-to-event latency by event type.
- Target retention, identity switches, and loss-recovery time.
- Readiness precision/recall over labelled test moments.
- For P4-P6 only: command-to-acknowledgement latency, tracking error,
  overshoot, and stop latency.

No latency number is promised before P0 supplies the host-and-device baseline.

## Decisions deferred intentionally

- Implementation language and inference runtime: choose after P0 identifies
  the capture path and P1 measures its overhead. The supplied C++ SDK remains
  available for direct control; OSC is an alternative integration boundary.
- Wake word, ASR, speaker identification, and semantic intent: L1 work, not
  a prerequisite for subconscious v0.
- Speaker direction from the dual microphone array: require a controlled
  calibration before use.
- Persistent memory, personality, dialogue, and outbound actions: L1/L2 work.

## P0 baseline captured

P0 completed on 2026-08-13 with the connected OBSBOT Tiny 2 Lite. The
read-only 60-second trace contains 1,817 video callbacks over 60.54 seconds
and 3,791 audio callbacks over 60.54 seconds. The trace reported no callback
drops or host-callback gaps, a 0.16 ms capture-start skew, and no camera
events or raw audio/video payload. The video PTS stream had one initial
timebase reset but no non-monotonic PTS; this is recorded separately from host
callback continuity. AVFoundation delivered 1920x1080 video at approximately
30.02 Hz despite the probe's initial 1280x720/30 request; the actual negotiated
format is recorded in the trace and is now a P1/P2 input. The probe now records
runtime error/interruption and device disconnect/reconnect events, although none
occurred during this baseline run.

## P1/P2 implementation baseline

The current `soma-subconscious` executable provides a concrete first slice of
P1-P3 while leaving the camera owner as `manual`:

- `PredictiveWorldModel` holds one attention target, velocity, uncertainty,
  surprise, voice evidence, interaction probabilities, and a non-actuating
  active-sensing policy.
- The video path updates the predictive state immediately and feeds a bounded
  latest-frame mailbox. The ANE-preferred person detector runs on every
  dequeued latest frame; its full-body miss triggers an up-to-6Hz close-range
  face fallback. A pending
  fallback is not incorrectly treated as target-loss evidence.
- The audio path uses a 96ms-confirmed local RMS/VAD gate only. It does not
  perform learned speech classification, ASR, speaker ID, or direction estimation.
- JSONL contains no raw audio/video. Source-health reports format-configuration
  fallback, runtime interruption/error, disconnect/reconnect, and clean stop.

The 2026-08-13 10-second baseline is
`artifacts/subconscious/p1-latency-final.jsonl`: 293 video and 626 audio
callbacks; mean hot-path processing time 0.37 ms and 1.35 ms respectively;
204 Vision frames intentionally skipped while untracked, and 20 superseded
frames discarded rather than queued. The device refused active 1280x720@60
configuration, so AVFoundation delivered approximately 30 fps; the trace says
`configuration_fallback` rather than claiming the requested setting applied.
No person was visible in this run, so 69 detector attempts correctly reported
no target. A 897 ms slow Vision inference was isolated from the callback path;
this validates nonblocking absence handling, not an end-to-end latency SLO or
target retention.

## P3 Neural Engine perception baseline

The main person-detector path is now Apple Core ML YOLOv3Tiny FP16, bundled with
the executable and configured on required macOS 13+ as `.cpuAndNeuralEngine`
(GPU excluded). It evaluates the latest available frame rather than waiting
behind a backlog. When it has no person candidate, a throttled up-to-6Hz generic
Vision face detector supports close-up conversation distance while the
ANE path remains the primary detector.

On the Apple M5 host, `artifacts/subconscious/p3-ane-final.jsonl` recorded
`neural_engine/configured` with `compute_units=cpu_and_neural_engine`, a 33.30
ms prewarm, 244 completed Core ML inferences over 11.1 seconds (about 22.0/s),
and 45 `coreml_ane` observations. Mean inference time was 30.68 ms; the 415.67
ms maximum and 420.12 ms maximum capture-to-belief time rule out any claim of a
hard real-time end-to-end SLO. Core ML's public API records the compute-unit
policy but does not attest the hardware chosen for every individual operation.
Use Instruments to obtain that hardware-level attribution.

## P3 sensory-fusion baseline

`artifacts/subconscious/p3-fusion-continuity-final.jsonl` is a 30.66-second
no-person capture-session run of the current fusion code. It records 832 Core
ML inferences (27.1/s), 158 face fallback inferences (5.2/s), and
`late_events_dropped=0`. Core ML averaged 17.05 ms and the maximum
capture-to-belief latency was 390.98 ms. No person or face was visible, so it
does not establish target retention, target loss, or speech detection quality.
The VAD gate accumulates continuous PCM duration, resets on a packet timestamp
discontinuity, opens after 96ms above threshold, and is deliberately non-learned
until a separately evaluated on-device speech model replaces it.

## Immediate next action

Run a consented person-present / ordinary-motion / target-loss / speak-silence
scenario with phase markers and a visible operator. Verify ANE-person to
close-range-face continuity, retained target ID, loss after the configured
timeout, and VAD precision/recall. Only after that should P2/P3 be marked
complete. Replace the variable-latency System Vision face fallback with a
licensed Core ML face detector configured for `cpuAndNeuralEngine`, then measure
its model-specific latency. Separately, determine why macOS refuses the active
720p60 format; do not infer dual-microphone direction until a controlled TDOA
calibration establishes stable left/right evidence.
