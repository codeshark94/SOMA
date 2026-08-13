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
  frame.
  On a full-body miss, it obtains a low-rate close-range face observation;
  intermediate misses are absence of new evidence, not a target-loss claim.
- The audio callback uses a 96ms-confirmed local RMS/VAD gate only. It is
  evidence for readiness, not a learned speech classifier, transcription, or
  speaker direction.

It emits local JSONL belief, voice-activity, vision-observation, metrics, and
source-health events. It never writes raw media, invokes an LLM/network,
enables native tracking, or sends PTZ/OSC/SDK commands.

SOMA requires macOS 13 or later. On Apple Silicon, person detection is a bundled
Core ML YOLOv3Tiny FP16 model loaded with `cpuAndNeuralEngine`; GPU is excluded
for that Core ML model.
The model evaluates the latest available video frames and accepts only the
`person` class. When that full-body detector has no candidate, a throttled
up-to-6Hz System Vision face fallback supports close-up conversation distance;
it does not replace the ANE primary path. The model source, hash, and hardware
attribution boundary are recorded in [MODELS.md](MODELS.md).

Run it against explicit OBSBOT IDs:

```sh
swift run soma-subconscious --duration 30 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>' \
  --output artifacts/subconscious/run.jsonl
```

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

The current [p3-fusion-continuity-final.jsonl](artifacts/subconscious/p3-fusion-continuity-final.jsonl)
is a 30.66-second capture-session OBSBOT run with no visible face or full body.
It records 832 Core ML inferences (27.1/s), 158 throttled face-fallback
inferences (5.2/s), and no raw media or late trace events. The Core ML model
remained configured as `cpu_and_neural_engine`; its mean inference time was
17.05 ms. The worst capture-to-belief measurement was 390.98 ms, so this is a
bounded latest-frame throughput result, not a hard end-to-end latency claim.

The local VAD accumulates continuous PCM duration above threshold and opens only
after 96ms; a packet timestamp discontinuity resets the accumulation. It emitted
no activity onset in this trace. That is not a speech-quality result: a
controlled person-present, ordinary-motion, leave-frame, and speak/silence
scenario remains required before P2/P3 acceptance is claimed.
