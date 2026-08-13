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
- Do not emit a speaker-direction cue from the dual microphones until a
  three-position TDOA calibration establishes stable directional evidence.
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
- Speaker direction from the dual microphone array: runtime code may emit only
  calibrated, high-correlation left/center/right attention cues. It remains
  separate from speaker identity and camera actuation.
- Persistent memory, personality, dialogue, and outbound actions: L1/L2 work.

## Language, identity, and memory boundary

The subconscious is language-neutral: it may emit local evidence that a voice
is active or comes from a calibrated direction, but it does not infer language,
transcribe speech, identify a speaker, or retrieve a person record. VAD and
TDOA evaluation must cover the deployment's expected languages and acoustic
conditions; no Korean-only corpus may become the implicit production contract.

L1 may later combine language evidence, a consented account/session identity
candidate, and scoped memory retrieval. Identity remains `unknown` until an
explicitly authorized signal establishes it; face or voice resemblance is not
enough. Rapport and individual information may tune response timing and style,
but cannot widen memory access, lower consent requirements, or authorize a
camera/action command. The L0 attention field receives only bounded,
non-semantic handoff evidence from that layer.

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
  dequeued latest frame; its full-body miss triggers an up-to-6Hz ANE-preferred
  BlazeFace inference. A pending face inference is not incorrectly treated as
  target-loss evidence.
- The audio callback downmixes only ephemeral PCM and feeds a bounded
  latest-audio worker. The worker runs local Core ML Silero VAD over 260 ms
  windows with `cpuAndNeuralEngine` requested; it does not perform ASR or
  speaker ID. After a three-position calibration it can emit left/center/right
  TDOA attention cues only.
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

The person-detector path is Apple Core ML YOLOv3Tiny FP16, bundled with the
executable and configured on required macOS 13+ as `.cpuAndNeuralEngine` (GPU
excluded). The close-range path is now a separate bundled Core ML BlazeFace
model configured with the same policy; it replaces the generic Vision face
detector and runs at up to 6 Hz after a person miss.

On the Apple M5 host, `artifacts/subconscious/p3-ane-final.jsonl` recorded
`neural_engine/configured` with `compute_units=cpu_and_neural_engine`, a 33.30
ms prewarm, 244 completed Core ML inferences over 11.1 seconds (about 22.0/s),
and 45 `coreml_ane` observations. Mean inference time was 30.68 ms; the 415.67
ms maximum and 420.12 ms maximum capture-to-belief time rule out any claim of a
hard real-time end-to-end SLO. Core ML's public API records the compute-unit
policy but does not attest the hardware chosen for every individual operation.
Use Instruments to obtain that hardware-level attribution.

## P3 sensory-fusion baseline

`artifacts/subconscious/p3-fusion-continuity-final.jsonl` is a historical
30.66-second no-person capture-session run before the face-model replacement.
It records 832 Core ML inferences (27.1/s), 158 face fallback inferences (5.2/s), and
`late_events_dropped=0`. Core ML averaged 17.05 ms and the maximum
capture-to-belief latency was 390.98 ms. No person or face was visible, so it
does not establish target retention, target loss, or speech detection quality.
The former 96 ms RMS gate remains only as an evaluator baseline. Runtime voice
evidence comes from local Core ML Silero VAD, which resets recurrent state on a
packet discontinuity, evaluates 260 ms windows at a fixed 0.50 threshold, and
uses a 520 ms inactive hangover. The model's source/hash and Core ML placement
boundary are recorded in `MODELS.md`; requested compute units are not
per-operation Neural Engine attestation.

## P3 guided lifecycle evidence

`artifacts/subconscious/p3-guided-scenario-protocol-final.jsonl` provides a
phase-marked 50.04-second capture acceptance interval. The five-second move-out
period and two seconds before the entry marker are transition buffers. The
scored quiet window (5–13 s) contains zero visual observations and zero VAD
transitions. An ANE person observation arrived 40 ms after `enter_and_move`.

In `speak_to_camera`, VAD opened at +2.085 s and +4.663 s while the visual target
was tracked; the first onset produced `handoff_candidate` (presence 0.74,
voice 0.80, readiness 0.61). After the final visual observation, target loss
occurred at 1.52 seconds, consistent with the configured 1.5-second boundary;
the settle window had zero visual observations and zero tracked beliefs. The
acceptance cutoff records 1,042 Core ML attempts, 113 `coreml_ane` and 78
`vision_face` observations, monotonic event timestamps, and
`late_events_dropped=0`. One local VAD onset occurred 1.76 seconds before the
speak marker; the markers describe the protocol, not verified human action.
The final shutdown metric includes one in-flight Core ML inference (1,043 total)
but no post-cutoff visual or voice event.

This accepts the phase-bounded lifecycle behavior, not speaker identity,
speech precision/recall, exact physical compliance with phase markers, or
per-operation ANE attribution. Its 566.36 ms maximum capture-to-belief latency
also rules out any hard real-time end-to-end claim.

## Immediate next action

Collect a consented, deployment-matched multilingual VAD corpus with labelled
speech, music, media playback, room noise, overlap, and distance conditions.
Use held-out clips to set or reject the 0.50 threshold before relying on voice
activity as a handoff cue. In parallel, run a speaker-present face scenario and
measure face-model p50/p95; audio-driven camera reaction remains blocked by the
failed OBSBOT TDOA calibration.

## P4 audiovisual attention field

The predictive model now records a version-2 `attention_cue` containing a
route (`idle`, `visual`, `auditory`, or `audiovisual`), a left/center/right
direction, and confidence. Visual target confidence and calibrated audio
direction decay independently. Agreement fuses evidence; weak disagreement
retains the visual target; only a substantially stronger audio cue emits the
non-actuating `reacquire` policy. Audio alone never creates a visual identity.

This is a hand-tuned continuous evidence field, not an LLM decision, random
behavior, speaker identification, or a camera command. The next physical gate
is still the three-position calibration plus a consented, deployment-matched
VAD corpus. Only after those results are reviewed can a separate camera-owner
state machine consider converting `reacquire` into motion.

The calibration trace now records a scalar `calibration_summary` for each
left/center/right phase: VAD-active analysis attempts, accepted measurements,
those meeting the correlation threshold, integer and fractional median lag,
zero-lag absolute correlation magnitude, and ambiguous/low-energy/invalid
rejections. A failed run is a diagnostic signal; do not lower the ambiguity or
correlation gates merely to force a direction result.

On 2026-08-13 the current OBSBOT macOS capture path produced zero fractional
lag and a 1.000 rounded zero-lag absolute correlation magnitude at all three
calibrated positions. This rules out this TDOA implementation as a source-direction input for the
present configuration. Keep audio as non-directional `sound_present` evidence
until a distinct microphone path is evaluated; do not convert it to a camera
motion request.
