# Subconscious v0 execution plan

## Definition of done

Subconscious v0 is complete when the connected Tiny 2 Lite can continuously
produce timestamped, local events for presence, a persistent field of scene
candidates, one selected attention target, target loss, voice activity,
interaction readiness, and low-cost intent hints. The result must be observable
in a trace, must not depend on L1/L2, and must leave the camera stationary until
a separate actuator stage is explicitly enabled.

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
| P2 - perception loop | Latest-frame person/face/hand detection, a persistent scene field, posterior target selection, temporal tracker, and audio VAD. | A credible face holds social attention through a detector gap; an observed non-face candidate remains scene attention without acquiring motor authority; coverage exploration resumes only after confirmed visual absence. |
| P3 - interaction preparation | State estimator combining target continuity, voice activity, visible gesture, and idle time into readiness and intent-hint events. | The system emits evidence and confidence only; it emits no text, speech, command execution, or ungrounded semantic intent. |
| P3.5 - optional L0.5 semantics | A persistent local MLX-VLM side process interprets sparse keyframes without blocking L0. | One-in-flight/latest-one-pending transport; scalar advisory output only; no target-selection, memory, dialogue, or motor authority. |
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

Target selection maintains an uncalibrated normalized posterior over visual
candidates and a `no target` hypothesis. Detector confidence, temporal continuity, a modest
human prior, and a bounded L1-provided attention prior contribute evidence; no
fixed score ordering is treated as a decision. A posterior-based commitment
retains a credible target to avoid flicker. At L0, a supported object remains
available for scene evidence and later L1 reasoning but cannot become an L0
physical gimbal target. When a human is present, objects and saliency stay in
the L0 posterior but a human-dominance constraint prevents them from outranking
a person or face.

## P7 L0 scene field and action gate

The low-latency path now keeps a `SceneField` separate from the compact
one-target belief. Every detector, face, or system-objectness candidate receives
a persistent `scene_id`; attention selects one posterior hypothesis but does
not remove the rest. System objectness is explicitly nonsemantic `unknown`
evidence. It can corroborate an object label but cannot name, identify, or act
on its own.

`SubconsciousAttentionController` is the L0 control layer between the posterior
and any actuator. It chooses `social_fixation`, `social_retention`,
`social_reframing`, `social_retention`, `scene_observation`, or `exploration`;
a face may expose a native social-tracking adapter, and a credible current person
box may make a bounded reframe to reveal facial evidence. An unlabelled `unknown`
or labelled object remains a scene hypothesis without camera-fixation authority.
A future L1 needs a separate actuator policy rather than reusing this L0 path.
The existing eight-second
no-motion trace `artifacts/subconscious/p7-scene-field-current-20260814.jsonl`
has three scene IDs, 62 candidate records, zero eligible candidates, and zero
camera events.

This is strictly L0 work. It does not add L1 dialogue, language inference,
memory, identity, rapport, or semantic reasoning.

## Optional P3.5 L0.5 semantic interpretation

The E4B MLX-VLM experiment is an optional side loop between reflexive L0 and a
future deliberative L1. The capture, perception, and actuator loops never wait
for it. A changed or salient scene may submit at most one keyframe per second;
an unchanged scene refreshes at five seconds. One persistent worker accepts one
inference plus one replaceable pending 512x288 in-memory JPEG. Its strict result
contains only a scene summary, novelty, social-presence probability, advisory
attention hint, confidence, and timing.

The result is trace evidence, not authority. It cannot select or suppress a
target, change a face lock, claim the camera owner, move the gimbal, speak,
identify a person, retrieve memory, or invoke L1. The model path must already
exist locally; no network fallback is permitted. Direct MLX uses the Apple GPU
and unified memory, while L0 Core ML remains independently ANE-preferred. The
worker has an 8 GB MLX evaluation limit and a 256 MB free-cache limit.

The 2026-08-15 24 GB host benchmark found 3.50–4.77 s first-image latency,
2.89–4.25 s warm latency, and a 5.75 GB MLX-reported peak. E4B is therefore a
roughly 0.2–0.35 Hz semantic observer, not a reflex or tracking component. It
remains opt-in and is not added to the persistent launch configuration. The L0
Vision worker's missing per-frame autorelease boundary was fixed and a same-PID
898.43-second L0-only run reached 22,422 video callbacks with zero runtime
error/stall events and bounded RSS. A following 20-request E4B stress window
advanced L0 by 1,749 video callbacks with no new skipped frames or cumulative
latency maxima, but a longer integrated thermal soak is still required before
enabling the side loop in the LaunchAgent.

## P8 gimbal-relative spatial scene field

When the direct gimbal bridge is present, the native helper reports the Tiny 2
Lite's current pitch/pan attitude and 86°/78°/65° FOV mode over the local scalar
pipe. `SceneField` projects every observed rectangle to a gimbal-relative
azimuth/elevation bearing, retains an offscreen candidate for the running
session with decaying spatial confidence, and refreshes a compatible labelled candidate
near that bearing after the camera moves. Offscreen bearings are normally map
evidence only. The retained bearing of the currently verified face lock gets
one bounded local re-acquisition attempt after confirmed loss; coverage chooses
the next direction only if that fails. The latched face preempts either search
stage immediately when it returns. Weak edge detections stay perceptual evidence
but do not become motor targets.
This is a local spatial index for L0 exploration, not a claim of object identity
or a new L1 memory system.

When no retained scene wins that posterior, a coarse spherical coverage field
marks every fresh-pose FOV as seen and chooses an unobserved azimuth/elevation
direction from five -30°...+30° elevation layers for the next exploration
waypoint, driving both pan and pitch. Waypoints feed a continuous 50 ms control
trajectory capped at 60°/s pan and 30°/s pitch, with 120/80°/s² acceleration
limits and stopping-distance braking. For each spatial cell, the planner
intersects its FOV-valid camera poses with the safe joint envelope and chooses
the nearest reachable guide; unreachable cells are rejected before motion and
opposite-side routes stay inside finite joint space instead of crossing the
angular seam. A 10° look-ahead transition changes direction before the exact
guide centre, so normal routes neither plan a joint boundary nor insert a hard
stop/rest. The waypoint deadline scales with angular travel. The native helper
coalesces superseded direct-motion commands while the synchronous SDK call is
in flight. Normal exploration continues from the current world-relative pose;
re-centering is reserved for an extreme physical attitude or measured
two-direction pan stall. This replaces a fixed scan order with scalar spatial
recency; it does not store frames or introduce L1 memory.
Non-human scene observation may delay a new search but cannot terminate an
already active coverage trajectory; social evidence retains preemption.

A completed empty detector result advances this field into its offscreen state;
the scalar trace snapshots retained candidates at most 4 Hz. Projection uses a
native attitude sample received on the local scalar pipe no older than 50 ms at
the video capture timestamp; the helper emits it every 20 ms. Otherwise it
records no bearing for that observation.

## Camera-control decision tree

1. P0-P3: camera owner is `manual`; no commands are emitted.
2. P4: the operator explicitly enters `native_ai`; test one native tracking
   mode at a time and return to `manual` when the test ends.
3. P5: the attention controller chooses a hardware-independent state before an
   owner is considered. `native_ai` is an optional low-level adapter for
   `social_fixation`; `external` requires both a measured axis mapping and a
   capture-to-attitude time-alignment evaluation before it may be selected for
   fixation or exploration. A selected object stays scene attention rather than
   becoming an implicit camera target.
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
  dequeued latest frame; its full-body miss triggers an up-to-12Hz ANE-preferred
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
detector and runs independently at up to 30 Hz.

The L0 motor boundary is face-only by default. Person/object/saliency output
continues to update the local scene field, but an object cannot fixate. No
offscreen scene record may direct the gimbal in this L0 implementation.
When a BlazeFace rectangle is enclosed by a concurrent person rectangle, the
face remains the motor geometry and the person detector can bridge it for at
most 320 ms with a damped translation. This is face-only motor evidence because
it requires the immediately preceding enclosed face+person pair; the bridge
expires without fresh face evidence.

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

Stay within L0. Collect a labelled, no-motion scene sequence containing real
people, ordinary objects, empty wall, reflections, and occlusion. Score scene
retention, false-label rate, source agreement, eligibility false positives, and
capture-to-belief latency before enabling another physical gimbal trial. Do not
start L1 dialogue, memory, identity, or language work until explicitly asked.

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

## P4/P5 actuator control status

The SDK control boundary is implemented separately from `soma-subconscious`.
`soma-native-track` requires an explicit motion flag, duration, and output
trace path. Its local bridge records command/acknowledgement events with a
correlation `command_id` and serializes native AI and direct external control.
The pure `CameraOwnerArbiter` prevents native AI and external control from
overlapping when an actuator integrates it with acknowledgements; failure
remains `fault` until a confirmed manual stop.

The first arm64 trial produced
`artifacts/subconscious/p4-native-human-20260813.jsonl`. It failed device
discovery before a tracking command. The trace does not identify the cause, so
it did not establish native tracking.

With OBSBOT Center closed, the follow-up
`artifacts/subconscious/p4-native-human-active-20260813.jsonl` completed the
native human-tracking handshake: `human_normal_active` (mode 2) appeared 3.06
ms after the command was sent, and `manual_active` (mode 0) appeared
245.91 ms after the stop command. The active interval measured 10.07 s because
the stop loop polls at 100 ms. All five trace events have result code 0 and
monotonic timestamps. This clears the basic P4 control handshake gate. It does
not yet establish visual lock/loss behavior, control latency beyond SDK
acknowledgement, target retention, or natural nonverbal movement quality.

`artifacts/subconscious/p4-native-human-correlated-20260813.jsonl` repeats a
three-second trial with the final trace contract. Its `native-human-1` and
`manual-stop-1` command IDs each pair a command with its acknowledgement; all
five result codes are 0.

The integrated bridge now makes native AI explicit opt-in through
`--allow-native-human-tracking`; without it, the helper receives no native
start even if a human is visible. A calibrated external owner, enabled only by
`--allow-external-gimbal-control --external-gimbal-calibration`, defaults to
eligible face fixation with completed-observation renewals only. Predictions, audio,
and periodic snapshots never renew an actuator lease. The responsive controller
uses up to the documented SDK limits of 180°/s pan and 90°/s pitch, has a 350 ms
bridge hard-stop and a 700 ms helper watchdog; a vision miss forces an external
servo stop, while acknowledged native tracking is kept alive independently of
app-detector cadence through short gaps. Continuous social loss for 1.2 seconds
releases native ownership and re-arms probabilistic spatial exploration; a new
verified face preempts that exploration and reacquires tracking. A
motion-enabled non-native session searches 450 ms after visual absence with a
continuous acceleration-limited trajectory at up to 60°/s pan and 30°/s pitch,
resampling the spherical posterior as each waypoint is reached or times out
until vision returns. The helper reads physical pitch/pan attitude but does not infer
an axis sign and overwrite the requested direction. Coverage exploration compares
attitude across each waypoint and reverses its next pan request if pan did not move,
rather than mistaking command acceptance for movement. The
source and helper serialize owner handoff: external yields manual before native
start, and native yields manual before external speed.

`artifacts/subconscious/p6-native-opt-in-idle-20260813.jsonl` verifies the new
default with a ready bridge and zero native/external intents; its actuator trace
contains only final manual acknowledgement. The external command parser rejects
requests outside the documented ±90°/s pitch and ±180°/s pan ranges. The current
`p6-external-calibration-no-target-20260814` pair saw zero visual
observations and thus emitted no calibration pulse or external velocity before
manual shutdown. Measured screen-to-gimbal axis signs, target-retention error,
overshoot, and scan comfort still require a controlled physical evaluation
before external motion is enabled with a real calibration file. The later
`p7-reactive-fast-20260814` run supplied hardware evidence: 55 visual fixation
requests and 55 accepted external SDK commands, reaching 44.4°/s pan and 31.5°/s
pitch. `--calibrate-external-gimbal` is the controlled physical protocol: it needs
a stable visual target and sends only one +pan 18°/s and one +pitch 25°/s / 180 ms
pulse, each admitted only by a completed visual observation and followed by a
timer-driven stop and 400 ms settling. Predictions, audio, and periodic state
snapshots cannot start or advance calibration. It writes no calibration when
the observed image displacement is under 0.015 normalized units. A failed calibration
releases all external motion rather than falling back to exploration.
