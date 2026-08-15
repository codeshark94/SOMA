# Subconscious v0 execution plan

This file tracks the L0 execution history and acceptance gates. The primary
post-L0 cognitive objective, including the 31B L1 model, memory, L2 Codex interaction,
embodiment MCP, LED capability boundary, and panoramic spatial memory,
is tracked in [COGNITIVE_ARCHITECTURE.md](COGNITIVE_ARCHITECTURE.md).

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
| P3.5 - L1 visual auxiliary | A persistent local MLX-VLM helper interprets sparse keyframes for L1 without blocking L0. | One-in-flight/latest-one-pending inference transport; scalar semantic output; no independent layer or SDK authority. |
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

## P3.5 L1 auxiliary semantic interpretation

The E2B MLX-VLM worker is an optional visual helper owned by L1. The primary
31B cloud route decides when its local sketch is useful; E2B is not a separate
cognitive layer. The capture, perception, and actuator loops never wait
for it. A changed or salient scene may submit at most one keyframe per second;
an unchanged scene refreshes at five seconds. One persistent worker accepts one
inference plus one replaceable pending 512x288 in-memory JPEG. Its strict result
contains only a scene summary, novelty, social-presence probability, advisory
attention hint, bounded situation/wake hypotheses, confidence, and timing. A
deterministic gate emits a scalar `l1.auxiliary.wake_proposal` only when the
situation and wake reason agree, wake score is at least 0.65, and confidence is
at least 0.55; identical recommendations are suppressed for five seconds.

E2B cannot by itself select or suppress a target, change a face lock, claim the camera owner,
move the gimbal, speak, identify a person, retrieve memory, or invoke L1. The
shared MCP transport and running L0 arbiter accept the same leased semantic
embodiment goals from L1 and L2—labels, attention priors, tracking, orientation,
exploration, view alignment, and expression. The separately enabled motor
adapter is active in the authorized persistent launcher; E2B is disabled there
by default and is enabled only with `SOMA_ENABLE_L05_VLM=1`. It still cannot claim
that lease or invoke the MCP by itself. The model path
must already exist locally; no network or Ollama fallback is permitted. Direct MLX uses the Apple GPU
and unified memory, while L0 Core ML remains independently ANE-preferred. The
worker has an 8 GB MLX evaluation limit and a 256 MB free-cache limit.

The 2026-08-15 same-image direct-MLX comparison found E2B at 1.47 s cold and
1.39 s warm median, versus E4B at 3.00 s cold and 2.75 s warm median. E2B's
MLX-reported peak was 4.20 GB versus 5.75 GB, and its local checkpoint was
3.3 GiB versus 4.8 GiB. E2B is therefore the preferred explicit helper; E4B remains a
comparison fallback. Process RSS moved in the opposite direction in this short
probe (3.33 GB E2B versus 2.31 GB E4B), so the decision is based on latency,
MLX peak, disk footprint, and the bounded-worker isolation—not a claim that
every memory metric is lower. Both remain semantic observers, not reflex or
tracking components. The L0
Vision worker's missing per-frame autorelease boundary was fixed and a same-PID
898.43-second L0-only run reached 22,422 video callbacks with zero runtime
error/stall events and bounded RSS. A following 20-request E4B stress window
advanced L0 by 1,749 video callbacks with no new skipped frames or cumulative
latency maxima. The persistent LaunchAgent keeps direct MLX opt-in and a first
234.34-second integrated smoke produced 48 semantic events, no interrupt false
positive, and no auxiliary-worker runtime error. A longer thermal qualification remains an
operational follow-up. The E2B/E4B semantic comparison used one person-free
panorama fixture, so broader human and object accuracy evaluation remains open.
Ollama is benchmark-only and never part of this runtime.

The persistent runtime now separates bounded forensic detail from durable
operational history. Full scalar evidence rotates at 128 MiB with eight retained
segments; native actuator evidence rotates at 32 MiB with four retained
segments. A separate important journal retains only source/controller state
changes, target acquire/loss transitions, voice transitions, semantic
interrupts, camera-mode changes, and hourly metrics, also under a segment cap.
Repeated unchanged states are not promoted. Face-lock JPEG diagnostics remain a
manual, session-scoped tool and are not enabled by the persistent launcher.

## P8 gimbal-relative spatial scene field

When the direct gimbal bridge is present, the native helper reports the Tiny 2
Lite's current pitch/pan attitude and generic 86/78/65 FOV mode label over the
local scalar pipe. A specification-derived optical profile remains the fallback.
The provisional 86-mode calibration instead shares normalized intrinsics and one
camera-to-gimbal rotation across `SceneField`, coverage, and panorama projection
before every observed rectangle is projected to a gimbal-relative
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

The native helper disables auto zoom, commands 1×, and requires its readback
before exposing motion. Calibration capture uses absolute 21-waypoint motion
and accepts only frames at no more than 0.75°/s. The deployed 28-frame schema-1
model fits intrinsics, Brown radial distortion, and camera-to-gimbal rotation;
five held-out pairs/369 matches improve from 41.325 px RMSE to 6.098 px with
8.204 px p90. Rotation-centre parallax remains open calibration work.

When no retained scene wins that posterior, the shared spherical scene atlas
marks every fresh-pose FOV as seen and chooses an unobserved azimuth/elevation
direction across the complete edge-visible field for the next exploration
waypoint, driving both pan and pitch. The same bounded scalar atlas is readable
through `get_spatial_map` and retains scene bearings for L1. Waypoints feed a continuous 50 ms control
trajectory capped at 30°/s pan and 18°/s pitch for exploration, with 120/80°/s² acceleration
limits and stopping-distance braking. For each spatial cell, the planner
intersects its FOV-valid camera poses with one shared `GimbalKinematicEnvelope`
and chooses the nearest reachable guide; unreachable cells are rejected before motion and
opposite-side routes stay inside finite joint space instead of crossing the
angular seam. A 10° look-ahead transition changes direction before the exact
guide centre, so normal routes neither plan a joint boundary nor insert a hard
stop/rest. The waypoint deadline scales with angular travel. The native helper
coalesces superseded direct-motion commands while the synchronous SDK call is
in flight. Normal exploration continues from the current world-relative pose;
re-centering is reserved for measured external displacement or a
two-direction pan stall. This replaces a fixed scan order with scalar spatial
recency. An optional separate panorama worker writes one rolling 1024×256 JPEG
plus metadata at most once per second and resets that session artifact at
startup. It uses a 4 Hz one-slot input, waits up
to 125 ms for the post-exposure attitude packet, interpolates only measured
samples within a 120/200 ms distance/bracket bound, and
drops unaligned frames without delaying L0. Stable frames up to 2°/s may use
the full image; continuous motion from 2°/s through 40°/s contributes a central
vertical strip sized from the actual interval since the previous projection.
The compositor evaluates only the perspective frame's candidate spherical
window so the one-slot worker can keep pace with a sweep. The explicit
`--panorama-strip-scan` traverses four overlapping alternating elevation strips.
An AE/AWB-on physical circuit projected 643 frames, rejected zero for quality,
accepted 605/622 Vision translation refinements, and covered 96.9% of reachable
pixels with 73.6% high-quality coverage. OpenCV channel exposure compensation
and feather seam weights averaged 5.28 ms on the independent utility queue;
OpenCV pyramidal LK was measured and rejected because both acceptance and
latency were worse. People are kept out of the background composite; non-human
detections remain scene content. A currently detected person is masked
while the remaining background may contribute; an unmasked detector gap is
rejected for 750 ms. Per-pixel quality selection replaces the former
accumulating average: frames below the stable projection threshold are rejected,
and an existing pixel changes only for a materially better observation. Its
standard world equirectangular raster converts the OBSBOT SDK attitude once
into canonical visual axes, and source rays use a coupled 3D yaw/pitch basis
rather than separable planar offsets. Consecutive overlapping background views
receive a utility-queue translational registration pass only after the motion
gate; its residual correction is confidence-gated, robustly weighted, bounded,
and re-anchored to measured attitude on every pair.
Stable human-free views run a versioned Apple Vision Feature Print at most once
per second on the utility queue and contribute its normalized learned embedding
to a fixed spherical cell. A compatible revisit updates that cell and records
familiarity or appearance conflict rather than creating another location;
encoder/revision mismatch cannot merge. An explicit place-memory path persists
only embeddings and bounded scalar cell state in one atomic 4 MiB/256-cell,
owner-only file, while the rolling image and dynamic entities remain
session-scoped. The exploration
posterior combines scalar recency, spherical image-quality deficit, and place
uncertainty as expected information gain, then centres a reachable deficient
tile in the FOV. MCP exposes coverage/quality, registration and embedding
timing, restored/revisit/conflict, encoder revision, and information-gain state;
cloud transfer is not automatic.
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

L1 may combine language evidence, a consented account/session identity
candidate, and scoped memory retrieval. Face resemblance can recover an
encrypted local anonymous pseudonym, but it does not establish a name,
relationship, or consent state. Those remain `unknown` until an explicitly
authorized enrollment. Rapport and individual information may tune response timing and style,
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

The direct interaction transport now has an end-to-end synthetic validation:
the installed helper accepted OBSBOT-format PCM, produced an input transcript,
created a response turn, and played a detected remote audio track. The deployed
default is the app-server's `maple` voice. Physical field validation with a
human still has to measure microphone, echo, and barge-in behaviour. Build C4
without coupling its latency to this route. L0 now permits the first spoken turn
only when fresh directed
eye-contact evidence and voice coincide, except for one response after a
SOMA-initiated greeting pulse. A successful L2 handoff opens a bounded follow-up
conversation lease. The authorized C3 wake becomes a bounded
utterance and consumes one second of memory-only PCM pre-roll. The primary path
starts an account-authenticated Codex app-server V3 WebRTC session, supplies the
opening context through `initialItems`, batches PCM into a continuous Web Audio
worklet, and admits changed ephemeral E2B camera summaries through `appendText`.
The local CLI/Apple-ASR/AVSpeechSynthesizer bridge remains a
diagnostic fallback only. A labelled directed/non-directed speech set must
still measure false wakes, missed wakes, speech-start-to-transcript latency,
multilingual accuracy, account-to-audio latency, echo, and barge-in without
weakening the eye-contact opening gate or immediate L0 acknowledgement.
Meanwhile the primary 31B situational stream consumes a bounded
`SituationFrame`, C2 memory projection, and C6 embodiment MCP and prepares the
richer interaction context in parallel. It requests transient views only for
visual disambiguation, proposes rather than directly commits memory, and uses a
leased embodiment action rather than SDK access. Extend the labelled L0 corpus
with directed and non-directed speech, gaze/contact bids, people, ordinary
objects, empty wall, reflections, and occlusion so false interaction wakes and
missed contacts remain measurable.

The C2 core is now implemented as a typed, encrypted local journal with
provenance, consent, tier retention, promotion, correction, deletion, and
remote-summary projection boundaries. It now includes exact local-only L2
conversation turns, ordered pending/consolidated state, and links to the typed
memories derived by L1. The L1 read path now provisions an owner-only local key
and retrieves only policy-approved summaries, rapport context, and information
motives, which it may naturalize into a context-appropriate opening. Live
transcript ingestion and consolidation remain runtime work. The default curator is L1; L2 may explicitly flag direct
user facts, corrections, and memory requests, but cannot bypass validation.
The same `gemma4:31b-cloud` L1 stream is the intended consolidation route; no
second L1 model or shadow route participates in memory decisions. The C3 core
now supplies a versioned probabilistic router,
direct L2 interaction dispatch, parallel L1 context preparation, interaction
authorization and local-safety policy masks, deterministic replay sampling,
temperature calibration, and false-wake/missed-wake metrics. Its 32-row
bootstrap corpus is only an executable contract. The next C3 gate is a
time-aligned, labelled deployment corpus from real camera, audio, memory, and
task events, followed by out-of-sample calibration and a shadow-mode latency
test before the router can schedule L1 or open L2 interaction.

The leased physical embodiment gate is complete. SceneField projection and
semantic binding feed a separately enabled L0 motor adapter: explicit scene
references preserve object permanence offscreen, descriptor matches expose a
normalized association posterior, and ambiguous or unavailable bindings
suspend rather than move. Accepted `orient`, grounded `track`, policy-shaped
`explore`, active view capture, and bounded social expressions share the existing
gimbal owner queue. Higher-priority leases preempt, owner release and target
removal invalidate, expiry is independently scheduled, and every exit returns
through the native stop/watchdog path. `capture_view` now settles against pose
feedback, captures the next exposure-aligned frame, returns a bounded 60-second
MCP image resource, and releases only its one-shot motor goal. Live checks
returned a sharp 640x360 frame in 1.6 s at -0.35/-0.05 degrees for a 0/0-degree
request. A registered `bicycle` bound to `scene-10`, reacquired fresh visual
evidence, physically tracked to hold, and released at the 20-second deadline.
The next implementation gate is C4: ingest Live transcript turns and consolidate
them through the primary 31B stream, using C6 tools for active observation
rather than adding another actuator path.

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
continuous acceleration-limited trajectory at up to 30°/s pan and 18°/s pitch,
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
