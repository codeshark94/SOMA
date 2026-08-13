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
- The Vision worker re-detects at a low rate when no target exists, then uses a
  fast tracker between periodic detector refreshes.
- The audio callback computes local RMS/VAD only. It is evidence for readiness,
  not transcription or speaker direction.

It emits local JSONL belief, voice-activity, vision-observation, metrics, and
source-health events. It never writes raw media, invokes an LLM/network,
enables native tracking, or sends PTZ/OSC/SDK commands.

SOMA requires macOS 13 or later. On Apple Silicon, person detection is a bundled
Core ML YOLOv3Tiny FP16 model loaded with `cpuAndNeuralEngine`; GPU is excluded.
The model evaluates the latest available video frames and accepts only the
`person` class. System Vision tracking is retained only as a compatibility
fallback if the Core ML model cannot load. The model source, hash, and hardware
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
