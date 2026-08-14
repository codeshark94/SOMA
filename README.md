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

`soma-subconscious` is a local perception slice and is non-actuating by
default. It has three separate paths:

- The video callback advances a persistent predictive belief and replaces the
  pending Vision frame rather than queueing it.
- The Vision worker runs an ANE-preferred COCO person/object model on each
  dequeued latest frame, an ANE-preferred BlazeFace model at up to 30 Hz, and
  macOS objectness saliency at up to 4 Hz. A failure in either supplementary
  detector cannot discard an otherwise completed COCO result.
- A face enclosed by a person box is kept as the single small face target. For
  at most 320 ms between BlazeFace results, the matching person box may supply
  a damped face-position bridge. This is face-only motor evidence because it
  requires the immediately preceding enclosed face+person pair; it expires
  without a fresh face result.
  Default L0 camera motion is face-only: person boxes, objects, and saliency remain scene
  evidence but cannot cause fixation or offscreen re-acquisition. Attention
  weights remain reasoning evidence only; they have no L0 motor authority.
- If one or more people are currently observed, objects and saliency remain in
  the L0 attention posterior, but its human-dominance constraint ensures none
  can outrank a current person or face.
- A local scene field keeps every current candidate as a separate, persistent
  hypothesis. The probabilistic attention selector chooses one candidate (or
  `no target`) for the compact belief, but it never deletes the other scene
  candidates.
- `SubconsciousAttentionController` converts that selected posterior into one
  of five hardware-independent L0 states: `social_fixation`,
  `social_reframing`, `social_retention`, `scene_observation`, or
  `exploration`. A face may expose the optional native human-tracking adapter
  only in `social_fixation`; a credible person body may make a bounded reframe
  to reveal a face; an observed object remains non-actuating.
- The audio callback only downmixes ephemeral PCM and submits it to a bounded
  mailbox. A local Core ML Silero VAD worker consumes 260 ms windows with
  `cpuAndNeuralEngine` requested; it is evidence for readiness, not ASR or
  transcription.
  A calibrated two-channel TDOA estimator can additionally emit local
  left/center/right attention cues; without calibration it emits `unknown`.

It emits local JSONL belief, voice-activity, vision-observation,
`scene.candidate`, metrics, and source-health events. The default trace never
writes raw media or invokes an LLM, network, OSC, or PTZ service. Native
tracking is available only through the explicit consented bridge documented
below.

SOMA requires macOS 13 or later. On Apple Silicon, its bundled person, face,
and VAD models are loaded with `cpuAndNeuralEngine`; GPU is excluded by that
Core ML policy. Person observations are `coreml_ane`; close-range face
observations are `coreml_ane_face`; voice events are `coreml_vad`. The model
source, hash, and hardware-attribution boundary are recorded in
[MODELS.md](MODELS.md).

Run it against explicit OBSBOT IDs:

```sh
swift run soma-subconscious --duration 30 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>' \
  --output artifacts/subconscious/run.jsonl
```

## Optional local L0.5 semantic side loop

`gemma-4-e4b-it-nvfp4` can run directly through `mlx-vlm`, without Ollama, as
an explicitly enabled low-rate semantic side loop. It is not part of the L0
control path and it is not L1: it produces a bounded scene summary, novelty,
social-presence probability, and an advisory attention hint. Those values are
written as scalar `l05.semantic` events only. They never enter target
selection, face lock, camera ownership, or a gimbal command.

The video callback never waits for the model. An event gate admits a changed
or salient keyframe at most once per second and refreshes an unchanged scene
once per five seconds. The bridge has one in-flight request and one replaceable
pending frame, converts the latter to a 512x288 in-memory JPEG on a utility
queue, and sends it to one persistent local Python process. Neither the JPEG
nor model input is written by the L0.5 path. A local model directory is required
so enabling the bridge cannot silently download a model or call a remote API.
The worker also sets an 8 GB MLX evaluation limit and a 256 MB free-cache limit;
an over-limit inference fails in the advisory process instead of consuming
unbounded unified memory.

The installed reference environment is:

```sh
/Library/Frameworks/Python.framework/Versions/3.12/bin/python3 -m venv \
  "$HOME/Library/Application Support/SOMA/venvs/l05"
"$HOME/Library/Application Support/SOMA/venvs/l05/bin/python" -m pip install mlx-vlm
"$HOME/Library/Application Support/SOMA/venvs/l05/bin/hf" download \
  mlx-community/gemma-4-e4b-it-nvfp4 \
  --local-dir "$HOME/Library/Application Support/SOMA/models/gemma-4-e4b-it-nvfp4"
```

Probe it without changing the running camera service:

```sh
"$HOME/Library/Application Support/SOMA/venvs/l05/bin/python" \
  scripts/soma_l05_probe.py \
  --python "$HOME/Library/Application Support/SOMA/venvs/l05/bin/python" \
  --worker "$PWD/scripts/soma_l05_vlm_worker.py" \
  --model "$HOME/Library/Application Support/SOMA/models/gemma-4-e4b-it-nvfp4" \
  --image /absolute/path/to/one-consented-test-frame.jpg
```

After that independent probe passes, opt in on a new `soma-subconscious` run
with all three flags:

```sh
swift run soma-subconscious --duration 30 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>' \
  --output artifacts/subconscious/l05-run.jsonl \
  --l05-vlm-python "$HOME/Library/Application Support/SOMA/venvs/l05/bin/python" \
  --l05-vlm-worker "$PWD/scripts/soma_l05_vlm_worker.py" \
  --l05-vlm-model "$HOME/Library/Application Support/SOMA/models/gemma-4-e4b-it-nvfp4"
```

On the 24 GB Apple Silicon host, the 512x288 benchmark loaded the 4.8 GB
checkpoint in 2.5–3.8 s, took 3.50–4.77 s for a first image and 2.89–4.25 s for
subsequent images, and reported a 5.75 GB MLX peak. This makes E4B suitable only
for an approximately 0.2–0.35 Hz advisory loop. During a concurrent benchmark,
the repaired L0 advanced 1,749 video callbacks, 700 person-model attempts,
1,750 face-model attempts, and 1,750 vision updates during a 70-second window
containing 20 consecutive E4B requests. Skipped frames and cumulative inference
maxima did not increase, the L0 PID survived, and its trace recorded no runtime
error or stall. The worker loaded in 2.79 s and its 20-request run measured a
3.41 s cold inference and 2.79 s warm median. This is a bounded coexistence
stress result, not permission to put semantic output in the motor path.

The earlier roughly five-minute `IOSurface` failure came from running every
Vision request inside one long-lived GCD work item without a per-frame
autorelease boundary. The worker now drains temporary Vision/IOSurface objects
after every processed frame. A same-PID L0-only run then lasted 898.43 seconds,
advanced from 23 to 22,422 video callbacks, recorded zero Vision runtime
error/stall events, and showed no linear RSS growth. The persistent LaunchAgent
still leaves L0.5 disabled until the integrated side-loop configuration itself
receives a longer thermal soak.
The original latency run is recorded in
[l05-e4b-mlx-benchmark-20260815.json](artifacts/subconscious/l05-e4b-mlx-benchmark-20260815.json);
the repaired L0 soak and 20-request coexistence window are recorded in
[l0-lifetime-l05-coexistence-20260815.json](artifacts/subconscious/l0-lifetime-l05-coexistence-20260815.json).
MLX uses the Apple GPU/unified memory for this model; it does not move this VLM
onto the Neural Engine. L0's Core ML person, face, and VAD models retain their
separate ANE-preferred policy.

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

The runtime voice path now uses the bundled 16 kHz Core ML Silero VAD over
260 ms windows, behind a latest-audio mailbox. Its voice events carry only
`coreml_vad`, active state, probability, and RMS level; JSONL never stores PCM.
The 6-second no-speech OBSBOT trace
[p5-neural-vad-live.jsonl](artifacts/subconscious/p5-neural-vad-live.jsonl)
completed 23 VAD inferences (mean 1.56 ms, maximum 2.43 ms; maximum
window-end-to-evidence 3.02 ms) without superseding an audio VAD frame or
writing a voice event. This proves bounded quiet-path operation, not speech
quality or a human-onset latency below the model's 260 ms window.

On the first ignored-local smoke corpus, the legacy RMS evaluator yielded
precision 0.646, recall 0.593, and F1 0.619 on 16 ms blocks. The Core ML
evaluator yielded F1 1.0 on only 43 independent 260 ms windows. Those scores
are different units and this tiny, mismatched corpus does not qualify either
model as a reliable field speech detector; see
[VAD_EVALUATION.md](docs/VAD_EVALUATION.md) for the evaluator and limits.

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

Every calibration run writes a scalar-only `audio_tdoa=calibration_summary`
health event for left, center, and right: VAD-active attempts, accepted and
threshold-eligible measurements, integer and fractional median lag, zero-lag
absolute correlation magnitude, and ambiguous/low-energy/invalid rejections.
Fractional lag is a local parabolic interpolation around one unambiguous
correlation peak; it is not a direction result by itself. If calibration
fails, use that summary to correct placement or speech coverage; do not relax
the gates simply to produce a direction.

The 2026-08-13 fractional OBSBOT check recorded 58/56/29 eligible speech
measurements for left/center/right, respectively. All three phases had an
integer median lag of 0, fractional median lag of 0.000 samples, and zero-lag
absolute correlation magnitude rounded to 1.000. For this macOS capture path and placement, the
two delivered channels contain no usable TDOA direction evidence. This does
not make a general claim about every OBSBOT hardware/firmware mode, but it
blocks audio-driven camera reaction in this configuration.

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

This L0 path is language-neutral. Future language identification, multilingual
ASR, consented identity/session resolution, rapport, and scoped individual
memory belong to L1. They may change response style or handoff priority, but
cannot change L0 sensor permissions or authorize camera motion.

The [p4-attention-field-idle.jsonl](artifacts/subconscious/p4-attention-field-idle.jsonl)
four-second OBSBOT smoke run records 379 monotonic scalar events with belief
schema version 2 and only `idle`/`visual` routes. Its health trace explicitly
says `audio_tdoa=calibration_required`; it has zero `audio.direction` and zero
camera-command events. It verifies the safe uncalibrated boundary, not sound
localization or reaction quality.

## Camera-control boundary

The separate `Sources/SOMANativeTracking/soma-native-track` helper is the only
SDK control path. It accepts movement only with `--allow-camera-motion`, an
explicit `--duration`, and an `--output` trace path. `--duration 0` keeps the
reactive session running until explicitly stopped; positive durations remain
available for bounded trials. Its local pipe
can request either Tiny 2 Lite native human tracking or direct low-speed gimbal
control, but never concurrently. Once the device control endpoint has been
discovered, it always requests `AiWorkModeNone` plus
`aiSetGimbalStop()` on normal exit, interruption, a rejected start, or an
unconfirmed start. A local cleanup guard also attempts that stop path during an
unexpected post-discovery exception. An interruption before discovery records
`discovery_interrupted`; it has no device endpoint to stop. Its JSONL contains
only command and acknowledgement owner/state, result codes, bounded diagnostic
messages, monotonic timestamps, and a `command_id` pairing a command with its
acknowledgement—never raw media.

Build it against a supplied macOS arm64 vendor SDK, then confirm discovery
without moving the camera:

```sh
cmake -S Sources/SOMANativeTracking -B /tmp/soma-native-track \
  -DOBSBOT_SDK_ROOT=/absolute/path/to/libdev_v2.1.0_8
cmake --build /tmp/soma-native-track
/tmp/soma-native-track/soma-native-track --list
```

Only an explicitly consented trial may add `--allow-camera-motion --duration
10 --output /path/to/trace.jsonl`.

The accompanying `EmbodiedAttentionPolicy` is a pure local policy: it turns a
tracked target into `orient`, `hold`, or `soften` route recommendations using a
dead-zone and confidence/uncertainty checks. It cannot issue a command. The pure
`CameraOwnerArbiter` models only `manual -> native_ai` or
`manual -> external`; a failed acknowledgement becomes `fault` and can return
only through a confirmed manual stop.

### Probabilistic, object-capable attention

L0 does not rank a fixed list of “scores.” For every video update it maintains an
uncalibrated normalized posterior over the current visual candidates and a `no target`
hypothesis. The evidence is detector confidence, a deliberately small human
class prior, spatial/semantic continuity with the last target, and an optional
bounded `attention_weight` supplied later by L1. The emitted observation carries
its posterior probability and the distribution entropy. A person is therefore a
high-value class, not the only kind of thing SOMA can notice: COCO object labels
remain first-class targets for an L1 thought, question, or memory lookup.

### L0 scene field and action-evidence gate

`scene.candidate` is the L0 view of the current scene. It preserves a stable
`scene_id`, rectangle, detector source, optional classifier label, observation
count, stability, corroborating-source count, and `action_eligible` flag for
every active candidate. With the direct gimbal bridge it also projects each
candidate into gimbal-relative `azimuth_degrees` and `elevation_degrees` from
the SDK-reported attitude and current 86°/78°/65° FOV mode. An offscreen
candidate remains in the spatial field for the running session with decaying
`spatial_confidence`; a later compatible observation near that bearing refreshes
the existing scene rather than creating a duplicate. It stores scalar metadata
only: no frame, crop, JPEG, or PCM is added to the trace. During an explicitly
requested face-lock diagnosis, `--face-lock-diagnostics <new-directory>` keeps
at most 60 JPEGs outside the trace: it samples raw face-candidate frames at up to
10 Hz and face-absent frames at 500 ms. This bounded one-in-flight writer cannot
accumulate camera buffers or starve live vision. Filenames carry the matching monotonic timestamp and `face_absent`,
`face_unverified`, `face_rejected`, or `face_verified` state. Each bridge stop
also appends a scalar `gimbal-stop-reports.jsonl` record
in that directory with the stop reason, latest face/target state, gimbal attitude,
and the newest retained diagnostic-frame filename; it never duplicates raw pixels.

An empty completed detector result is a real visual miss: it advances retained
tracks into their offscreen-decay state, and the trace reports that spatial
state at most 4 times per second. A bearing is projected only when a native
attitude sample received over the local scalar pipe is no more than 50 ms old;
the helper reports at 20 ms intervals. A stale or unavailable pose leaves the
bearing unset rather than placing an object in the wrong place.

Offscreen candidates are normally session-map evidence only. The sole L0 motor
exception is the remembered bearing of the currently verified face lock: after
a confirmed loss, it receives one bounded local re-acquisition attempt before
broad coverage begins. This keeps the social reference without freezing the
last gimbal pose. Predictions, audio, periodic belief snapshots, objects, and
unverified faces cannot use this path.

When no retained scene hypothesis wins, L0 falls back to a coarse gimbal-relative
coverage field rather than a fixed left/right scan. Every fresh-pose video frame
marks the current 86°/78°/65° FOV on a spherical azimuth/elevation grid as
observed; directions that have not recently been covered receive the larger
exploration posterior and guide both pan and pitch of the next waypoint. The
grid uses five comfort-bounded elevation layers from -30° through +30°, keeps
visited regions suppressed for 90 seconds, and supplies successive waypoints to
one continuous exploration trajectory. The spatial target remains unchanged;
the motor planner intersects every camera pose that can see it with the safe
pan/pitch joint envelope, then chooses the nearest reachable pose. A target
with no such intersection is rejected before motion and another posterior
sample is drawn, while an opposite-side target is routed through the finite
joint interior instead of wrapping across the ±180° seam.
Pan and pitch velocities are updated at
50 ms control intervals with 60°/s pan and 30°/s pitch caps, 120/80°/s²
acceleration limits, and stopping-distance braking;
a new waypoint is selected inside a 10° look-ahead radius and blends into the
current velocity instead of hitting the exact centre and inserting a stop/rest
pulse. Waypoint timeout scales with angular travel instead of cutting
a distant route at a fixed duration. The helper discards superseded direct-motion commands while an
SDK call is in flight, so delayed commands cannot accumulate behind perception.
An unexpected attitude outside the planned envelope receives an inward velocity
curve; the SDK's absolute centre operation is reserved for a measured
two-direction stall. This is scalar spatial recency only,
not image storage or L1 memory.

A non-human `scene_observation` can delay the start of a new blind search while
its posterior-weighted dwell is active, but it cannot interrupt a coverage
trajectory already in motion. A provisional `social_retention` observation is
also non-motor: it remains in the belief without interrupting an active
trajectory. Only a verified face fixation or an actionable person reframe may
preempt that motion.

System objectness (`system_saliency`) has no semantic label and remains
`unknown`; it is evidence that a visually distinct region exists, not evidence
that the region is a person, bottle, or any named item. It is scene evidence
only at L0: neither an ordinary `unknown` candidate nor a labelled object can
command fixation. Offscreen object records never command re-acquisition, even with a
future top-down weight in this L0 implementation. Posterior probability chooses
the compact belief but does not bypass this motor boundary. Repeated unchanged object evidence habituates in
the belief while no-person periods proceed to coverage exploration; current
human evidence does not habituate at L0.

The controller is not a face tracker. It owns the transition from a
probabilistic scene posterior to `social_fixation`, `social_reframing`,
`social_retention`, `scene_observation`, or `exploration`; each state then asks
a separate actuator adapter for work, if any. A credible face is high-value
social evidence and may request native human tracking. A credible current person
body may make only a bounded `social_reframing` correction to bring a face into
view; it is not a face substitute or an identity claim. An object or saliency
candidate remains selected scene evidence without implicit fixation authority.

`social_retention` preserves a credible social context through a detector gap
without treating that gap as a new motor measurement. When it has no fixation
or reframe authority, it does not insert a stop between exploration waypoints.
Once native tracking is
confirmed active, app-detector misses and one-frame confidence dips do not tear
down the device's own live tracking loop; the bridge supplies an independent
200 ms ownership heartbeat through a short gap. After 1.2 seconds of continuous
social visual loss it releases native ownership, searches the remembered face
bearing, and then resumes probabilistic spherical coverage. A reacquired face
immediately preempts exploration and starts tracking again. `scene_observation` keeps
the current object/region in the local attention field without pretending that
the L0 motor knows how to fixate it. Its dwell is posterior-weighted (0.25–0.70
seconds); a static non-human region then yields to `exploration` while remaining
in the scene map. Broad exploration uses the spherical coverage field. The only
saved-candidate motion is the bounded remembered-bearing recovery for the active
verified face lock; predictions, audio cues, and periodic belief snapshots never
become physical evidence.

The persistent live service currently uses native human tracking as the
`social_fixation` adapter (`--allow-native-human-tracking`). Direct external
control handles bounded person-body reframing, one remembered-bearing face
recovery after loss, and spherical no-target exploration. While coverage is
physically moving, two consecutive high-confidence detections of the same face
track may stop that motion and make a bounded provisional re-centering
correction. With the native adapter enabled, that provisional lease may start
only a bounded external correction; only independent verification may start
native tracking and promote the face to the persistent lock.
Each native acquisition selects the Tiny-series `AiVTrackMotion` tracking mode;
the helper records both the SDK setter result and the mode read back from
`AiStatus` in the `human_normal_active` acknowledgement.
Native tracking is stopped before an external recovery path starts, so the two
servos never race.
Direct external fixation remains a separately opt-in calibration experiment: an
axis sign measurement alone does not establish capture-to-attitude time
alignment, so it is not the controller's default route. The helper independently
enforces its stop/watchdog contract for any explicitly enabled experiment.

To enable calibrated external fixation, all consent flags and an empirical
screen-to-gimbal calibration are required:

```sh
swift run soma-subconscious --duration 5 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>' \
  --output artifacts/subconscious/bridge.jsonl \
  --allow-camera-motion \
  --native-gimbal-helper /absolute/path/to/soma-native-track \
  --gimbal-output artifacts/subconscious/bridge-actuator.jsonl \
  --allow-external-gimbal-control \
  --external-gimbal-calibration /absolute/path/to/calibration.json
```

The calibration JSON is schema 1 and contains measured `panSign`, `pitchSign`
(`-1` or `1`) plus configured `maximumPanDegreesPerSecond` (0–180) and
`maximumPitchDegreesPerSecond` (0–90), the documented direct-speed ranges of the
Tiny 2 Lite SDK. The signs come from small observed pulses; they are not guessed
from the SDK. Create it with any stable visual candidate in frame:

```sh
swift run soma-subconscious --duration 12 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>' \
  --output artifacts/subconscious/calibration.jsonl \
  --allow-camera-motion \
  --native-gimbal-helper /absolute/path/to/soma-native-track \
  --gimbal-output artifacts/subconscious/calibration-actuator.jsonl \
  --calibrate-external-gimbal artifacts/subconscious/external-gimbal-calibration.json
```

That protocol admits each pulse and settling measurement only after a completed
visual observation (never a prediction, audio cue, or periodic snapshot). It
sends one +pan (18°/s) and one +pitch (25°/s) pulse for 180 ms, stops after each,
waits 400 ms for the same target, and writes nothing if either image displacement
is under 0.015 normalized image units. A failed calibration releases all external
motion rather than falling back to exploratory control. A motion-enabled non-native session tracks
visual targets but does not search on its own. Add `--allow-autonomous-scan` to explicitly
authorize calibrated local visual search. Omitting the motion flags leaves every
direct speed at zero. Add
`--allow-native-human-tracking` only when deliberately comparing or using the
vendor's human-tracking fallback.

The bridge sends only target kind, label, posterior, and local command IDs over
a process-local scalar pipe; the return channel accepts only the helper-ready
acknowledgement. Neither channel carries frames, pixels, or audio. The five-second
[p5-stderr-ready-idle-20260813.jsonl](artifacts/subconscious/p5-stderr-ready-idle-20260813.jsonl)
run saw only the object label `zebra` after the helper was ready. It issued no
native-tracking request, and its
[actuator trace](artifacts/subconscious/p5-stderr-ready-idle-actuator-20260813.jsonl)
contains only the final `manual_active` acknowledgement. The later
[p6-native-opt-in-idle-20260813.jsonl](artifacts/subconscious/p6-native-opt-in-idle-20260813.jsonl)
run confirms the same safe no-motion branch after native tracking was changed to
explicit opt-in. The external velocity parser also rejected an out-of-range
request outside the documented ±90°/s pitch and ±180°/s pan ranges before device
control.
The current eight-second, no-motion OBSBOT trace
[p7-scene-field-current-20260814.jsonl](artifacts/subconscious/p7-scene-field-current-20260814.jsonl)
contains 208 scalar records, three scene IDs across the run (up to two at one
time), 62 scene-candidate records, zero action-eligible candidates, and zero
camera events. It ran 201
YOLO Core ML inferences (mean 8.47 ms, maximum 11.91 ms); its maximum
capture-to-belief time was 45.29 ms. This demonstrates candidate retention in a
historical no-motion run, not semantic recognition accuracy.

The subsequent 15-second
[p7-reactive-fast-20260814.jsonl](artifacts/subconscious/p7-reactive-fast-20260814.jsonl)
physical run emitted 55 completed-observation fixation requests. Its paired
[actuator trace](artifacts/subconscious/p7-reactive-fast-actuator-20260814.jsonl)
records 55 successful `external_active` SDK acknowledgements, with observed command
components reaching 44.4°/s pan and 31.5°/s pitch. This proves device acceptance
of the reactive commands; it is not a labelled accuracy or comfort evaluation.

The current 12-second
[calibration no-target trace](artifacts/subconscious/p6-external-calibration-no-target-20260814.jsonl)
contained zero vision observations, no external velocity intent, no calibration
file, and a final manual acknowledgement. These are safety/path checks, not yet
a measured fixation or scan evaluation. The posterior is normalized but not
calibrated to a field-measured probability until it is evaluated on labelled
sequences.

The first arm64 SDK trial is
[p4-native-human-20260813.jsonl](artifacts/subconscious/p4-native-human-20260813.jsonl).
It entered `fault/device_unavailable` before the helper sent a tracking command.
This proves only that this helper did not command movement; it does not prove
the physical camera state, native tracking, or the cause of discovery failure.

After OBSBOT Center was closed, the follow-up
[p4-native-human-active-20260813.jsonl](artifacts/subconscious/p4-native-human-active-20260813.jsonl)
successfully discovered the Tiny 2 Lite, entered `human_normal_active` (AI mode
2) 3.06 ms after the command was sent, then returned to `manual_active`
(AI mode 0) 245.91 ms after the stop command. The active interval measured
10.07 s because the stop loop polls at 100 ms. All five scalar trace events
have result code 0 and monotonic timestamps. This verifies the explicit
native-human-tracking handshake and stop acknowledgement on this host; it does
not yet measure visual lock, retention, overshoot, or the quality of nonverbal
motion.

The follow-up three-second
[p4-native-human-correlated-20260813.jsonl](artifacts/subconscious/p4-native-human-correlated-20260813.jsonl)
verifies the trace contract: `native-human-1` pairs native-tracking send and
acknowledgement, while `manual-stop-1` pairs AI-off/gimbal-stop send and manual
acknowledgement. All five events have result code 0.
