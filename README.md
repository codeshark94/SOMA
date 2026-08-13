# SOMA subconscious baseline

`soma-probe` is the first, read-only implementation of SOMA's subconscious
layer. It verifies that the OBSBOT Tiny 2 Lite video and microphone streams can
be captured continuously before perception or camera actuation is introduced.

It does not invoke the supplied OBSBOT SDK or OSC control surface, move the
gimbal, select a tracking mode, record raw audio/video, alter macOS's default
input device, or call an LLM or network service.

## Run

List the host-recognized devices and their available video formats, then copy
the OBSBOT unique IDs:

```sh
swift run soma-probe --list-formats
```

Run the 60-second read-only probe with those exact IDs:

```sh
swift run soma-probe --duration 60 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>'
```

The output is JSONL `source.health` events only. Each event has a monotonic
timestamp, selected device identity, capture state, and cumulative callback,
drop, gap, timestamp-reset, and negotiated-format statistics. The trace does
not include frame pixels or microphone samples.

## Captured baseline

The connected Tiny 2 Lite completed the first 60-second probe on 2026-08-13.

| Stream | Observed format | Capture evidence |
| --- | --- | --- |
| Video | 1920x1080 | 1,817 callbacks over 60.54 s; 0 dropped callbacks; 0 host-callback gaps |
| Audio | 32 kHz, 2 channels | 3,791 callbacks over 60.54 s; 0 host-callback gaps |

The probe requested 1280x720 at 30 fps, but AVFoundation negotiated a
1920x1080 callback format at approximately 30.07 Hz. This is recorded as a
hardware baseline, not silently treated as the requested format. The next
perception stage will choose its processing resolution independently and must
preserve the latest-frame, bounded-queue rule in [PLAN.md](PLAN.md).

The trace had no PTS reversals. It did report one initial video PTS timebase
reset, which is retained as telemetry and does not hide host callback gaps.
Runtime interruption/error and device disconnect/reconnect notifications are
also written as `source.health` events if they occur.

The exact trace is [p0-60s-validated.jsonl](artifacts/probes/p0-60s-validated.jsonl).

## Predictive subconscious loop

`soma-subconscious` is the first non-actuating perception slice. It has three
separate paths:

- The video callback advances a persistent predictive belief and replaces the
  pending Vision frame rather than queueing it.
- The Vision worker runs the ANE-preferred person model on each dequeued latest
  frame. On a full-body miss it runs a separate ANE-preferred BlazeFace model
  at up to 6 Hz; intermediate misses are absence of new evidence, not a
  target-loss claim.
- The audio callback uses a 96ms-confirmed local RMS/VAD gate only. It is
  evidence for readiness, not a learned speech classifier or transcription.
  A calibrated two-channel TDOA estimator can additionally emit local
  left/center/right attention cues; without calibration it emits `unknown`.

It emits local JSONL belief, voice-activity, vision-observation, metrics, and
source-health events. It never writes raw media, invokes an LLM/network,
enables native tracking, or sends PTZ/OSC/SDK commands.

SOMA requires macOS 13 or later. On Apple Silicon, its bundled person and face
models are both loaded with `cpuAndNeuralEngine`; GPU is excluded by that Core
ML policy. Person observations are `coreml_ane`; close-range face observations
are `coreml_ane_face`. The model source, hash, and hardware-attribution boundary
are recorded in [MODELS.md](MODELS.md).

Run it against explicit OBSBOT IDs:

```sh
swift run soma-subconscious --duration 30 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>' \
  --output artifacts/subconscious/run.jsonl
```

For an explicitly consented 50-second attention/VAD check, add
`--guided-scenario`. The trace writes scheduled `scenario.phase` markers for
five seconds to move out of frame, then quiet/out-of-frame, enter-and-move,
speak-to-camera, exit-and-silence, and settle. That historical trace predates
the Core ML face replacement, so its face observations are labeled
`vision_face`. Markers record the protocol, not proof that an operator followed
it.

## P3 guided lifecycle evidence

The [p3-guided-scenario-protocol-final.jsonl](artifacts/subconscious/p3-guided-scenario-protocol-final.jsonl)
run records a 50.04-second capture acceptance interval, bounded by the
`scenario.completed` event; later shutdown telemetry is not scored. Its first
five seconds are an unscored move-out period and the final two seconds before
entry are a transition buffer. In the scored 5–13 second quiet window there
were zero visual observations and zero VAD transitions. The first ANE person
observation followed the `enter_and_move` marker by 40 ms.

During `speak_to_camera`, two local VAD onsets arrived 2.085 s and 4.663 s after
the marker while a visual target was tracked; the first produced
`handoff_candidate` with presence 0.74, voice 0.80, and readiness 0.61. The
last visual observation preceded the `exit_and_silence` marker by 1.21 seconds;
the predicted target became `none` 1.52 seconds after that last observation,
matching the configured loss boundary. The final five-second settle window had
zero visual observations and zero tracked beliefs.

One local VAD onset also occurred 1.76 seconds before `speak_to_camera`; phase
markers are scheduled protocol markers, not verified operator actions. At the
acceptance cutoff the trace recorded 1,042 Core ML attempts. The final shutdown
metric reports 1,043 because one in-flight Core ML inference completed during
shutdown; it produced no post-cutoff visual or voice event.

This is evidence that the local state machine responds coherently to the
time-bounded protocol. It does not prove speaker identity, speech
precision/recall, physical exit at the exact marker, or per-operation Neural
Engine placement. The acceptance interval recorded 1,042 Core ML attempts
(20.8/s), 191 visual observations (113 `coreml_ane`, 78 `vision_face`), and no
raw media or late trace events; its maximum capture-to-belief latency was
566.36 ms, so it is not an end-to-end real-time SLO.

The latest 10-second trace is
[p1-latency-final.jsonl](artifacts/subconscious/p1-latency-final.jsonl).
Its callback averages were 0.37 ms (video) and 1.35 ms (audio). The connected
camera refused an active 720p60 configuration, so the run transparently records
`configuration_fallback` and observed roughly 30 fps rather than pretending
that 60 fps was achieved. A Vision inference reached 897 ms, but it was
decoupled behind the latest-frame mailbox; this run therefore demonstrates
bounded fast-path work, not an end-to-end latency SLO. The scene had no detected
person, so target-retention quality still requires a controlled person-present/
loss test.

## Neural Engine baseline

On the Apple M5 host, [p3-ane-final.jsonl](artifacts/subconscious/p3-ane-final.jsonl)
records the Core ML model as `compute_units=cpu_and_neural_engine`, with a
33.30 ms prewarm. Across 11.1 seconds, the latest-frame path completed 244 Core
ML inferences (about 22.0/s), emitted 45 `coreml_ane` observations, and averaged
30.68 ms per Core ML inference. The maximum was 415.67 ms, so this is evidence
of ANE-preferred execution and bounded frame replacement, not a guaranteed
per-frame or end-to-end latency SLO.

## P3 sensory-fusion baseline

The historical [p3-fusion-continuity-final.jsonl](artifacts/subconscious/p3-fusion-continuity-final.jsonl)
is a 30.66-second capture-session OBSBOT run with no visible face or full body.
It records 832 Core ML inferences (27.1/s), 158 throttled face-fallback
inferences (5.2/s), and no raw media or late trace events. The Core ML model
remained configured as `cpu_and_neural_engine`; its mean inference time was
17.05 ms. The worst capture-to-belief measurement was 390.98 ms, so this is a
bounded latest-frame throughput result, not a hard end-to-end latency claim.

The local VAD accumulates continuous PCM duration above threshold and opens only
after 96ms; a packet timestamp discontinuity resets the accumulation. The
separate guided lifecycle trace above exercises the person-present, movement,
speak, loss, and settle state transitions. It remains an activity gate, not a
speech-quality classifier.

## P4 ANE face, VAD, and direction baseline

The 3.15-second [p4-ane-face-final-verified.jsonl](artifacts/subconscious/p4-ane-face-final-verified.jsonl)
run on the connected OBSBOT configured both Core ML models with
`cpu_and_neural_engine`: person prewarm 4.62 ms and BlazeFace prewarm 0.83 ms.
It completed 91 person inferences and 16 face inferences; that scene contained
no face observation. The pinned model's square reference face decodes to two
candidates (top confidence 0.9998) in an offline, non-persisted check. The
runtime has no `VNDetectFaceRectanglesRequest` path. This confirms loading,
requested compute policy, and trace semantics—not a per-operation ANE
attestation or face-detection accuracy benchmark.

`soma-vad-eval` evaluates the exact local gate from a manifest of labelled WAV
clips. The first ignored-local smoke corpus (four spoken-digit clips and two
non-speech environmental clips) yielded block precision 0.646, recall 0.593,
and F1 0.619. This small, mismatched corpus intentionally fails to qualify the
gate as a reliable speech detector; see [VAD_EVALUATION.md](docs/VAD_EVALUATION.md)
for the evaluator and its limits.

For sound-origin attention only, collect a three-position calibration while
speaking naturally at left, center, and right of the camera:

```sh
swift run soma-subconscious --duration 45 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>' \
  --tdoa-calibrate artifacts/subconscious/tdoa-calibration.json \
  --output artifacts/subconscious/tdoa-calibration-trace.jsonl
```

Then supply the scalar-only calibration file with `--tdoa-calibration`. The
runtime emits `audio.direction` only for high-correlation, unambiguous,
VAD-active audio; it writes no raw samples and still sends no pan/tilt command.
This cue is for a future attention/actuator owner to consume, not speaker
identity or exact angle.

## Audiovisual attention field

Belief schema version 2 adds an `attention_cue` with a route, direction, and
confidence. It is a continuous, local evidence field rather than a random
reaction or an LLM decision:

- A credible visual target creates a decaying `visual` cue from its horizontal
  screen position.
- A calibrated, VAD-active TDOA estimate creates a decaying `auditory` cue.
- Matching directions fuse into `audiovisual`, increasing confidence without
  inventing a speaker identity.
- Weak conflicting sound preserves the credible visual target. Only sound that
  exceeds that target's confidence by 0.18 becomes an `auditory` `reacquire`
  candidate; it never changes visual identity or moves the camera.
- Auditory evidence fades with a 650 ms time constant and becomes `idle` below
  0.08, so a single sound cannot hold attention indefinitely.

The route is trace-only. Actual source-direction behavior remains blocked on
the physical three-position TDOA calibration and a deployment-matched VAD
evaluation; the current small VAD smoke corpus is not sufficient to authorize
camera movement.

The [p4-attention-field-idle.jsonl](artifacts/subconscious/p4-attention-field-idle.jsonl)
four-second OBSBOT smoke run records 379 monotonic scalar events with belief
schema version 2 and only `idle`/`visual` routes. Its health trace explicitly
says `audio_tdoa=calibration_required`; it has zero `audio.direction` and zero
camera-command events. It verifies the safe uncalibrated boundary, not sound
localization or reaction quality.
