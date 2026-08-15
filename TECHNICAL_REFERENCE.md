# SOMA subconscious baseline

`soma-probe` is the first, read-only implementation of SOMA's subconscious
layer. It verifies that the OBSBOT Tiny 2 Lite video and microphone streams can
be captured continuously before perception or camera actuation is introduced.

It does not invoke the supplied OBSBOT SDK or OSC control surface, move the
gimbal, select a tracking mode, record raw audio/video, alter macOS's default
input device, or call an LLM or network service.

## Project architecture

The project-wide cognitive design is tracked in
[COGNITIVE_ARCHITECTURE.md](COGNITIVE_ARCHITECTURE.md). L0 remains the local,
low-latency perception and motor layer. The selected primary L1 path is
`gemma4:31b-cloud`; the direct-MLX E2B worker is only an L1-owned visual helper,
not an independent L0.5 layer or authority. L1 owns active situational
interpretation through a typed short-, medium-, and long-term memory service.
Its deployed first step is a sparse known-person situation cycle: stable,
consented recognition wakes `gemma4:31b-cloud`, whose strict decision may stay
silent, issue a nonverbal invitation, or open one bounded account-backed voice
greeting. L1 retrieves only policy-approved memory summaries, rapport context,
and information motives. Sparse relationship knowledge itself creates an
information motive, but not a canned question: a bounded rolling L1 thought
state weighs curiosity, social availability, interruption cost, rapport, and
current evidence before composing any opening. Transcript consolidation remains
the next runtime step.
L2 is the Codex human-interaction, reasoning, and task layer. Authorized
explicit human contact may open L2 directly from L0 while L1 builds richer
context in parallel, so directed contact does not wait for the 31B stream. The
primary interactive route is Codex app-server's account-authenticated GPT-Live
WebRTC session. L0 supplies the eye-contact-plus-voice opening decision and its
already captured PCM stream; the installed Codex runtime owns Live session,
natural turn taking, spoken output, and ChatGPT-account authentication.
Neither L1 nor L2 drives the camera SDK directly; both use the leased embodiment
MCP contract described in that document.

That MCP is not a weak suggestion channel. L1 and L2 share leased goals
for semantic labels, per-target probabilistic attention priors, target tracking,
orientation, exploration regions and directional distributions, view capture,
and social motion. L0 retains SDK timing, stabilization, watchdogs, joint-limit
handling, and immediate physical vetoes. The versioned request types exist in
`Sources/SOMACore/CognitiveEmbodiment.swift`. A local stdio MCP process now
forwards those requests over a current-user Unix socket to the running L0
process. The L0 executor validates, leases, rejects, preempts, expires, and
traces goals. Physical execution is a separate opt-in
`--allow-embodiment-motor-control` adapter: without that flag the same endpoint
remains shadow-only. The persistent launcher enables it because camera motion
was explicitly authorized for this installation.

The C2 model-independent memory core is present in
`Sources/SOMACore/CognitiveMemory.swift`: typed short-, medium-, and long-term
records use an authenticated encrypted journal, provenance/consent validation,
revision and deletion lifecycles, and a minimal remote-summary projection. It
also has a local-only raw L2 conversation-turn type and archiver: exact finalized
user and assistant transcript text stays encrypted in short-term memory until
L1 links it to derived episode, person, relationship, task, or open-question
records. Live transcript capture and runtime-key provisioning are not yet wired.
The C3 transition core is also present:
it produces a versioned, normalized distribution over `stay_l0`, `wake_l1`,
and `request_human_interaction`, records bounded evidence references and the
policy reason, dispatches explicit contact directly to L2 with parallel L1
context preparation, and prevents non-human events from opening interaction.
`--l2-live-voice` is the primary L2 interaction route. A Core ML VAD onset must
coincide with fresh directed eye contact, except for one response to a greeting
pulse that SOMA initiated. `soma-live-voice` starts the installed Codex
app-server with its realtime feature, creates an ephemeral `realtime_voice`
thread that is not materialized in the Codex desktop task list, and
negotiates V3 audio over WebRTC using the existing ChatGPT account. The OBSBOT
PCM already captured by L0 is scheduled onto the WebRTC input track, so this
path needs neither Accessibility automation nor a second microphone capture.
The scalar L0 trace still contains only bounded launch/active/end and
context-state events. Raw audio is not persisted. Finalized transcript text is
instead destined for the separate encrypted C2 short-term journal, never the
L0 trace.

Recognizing a stable local person—either an enrolled profile or a recurring
pseudonymous person—does not automatically speak. It creates a bounded
L1 social-deliberation opportunity whose valid outcomes are silence,
nonverbal invitation, or a spoken opening. A spoken opening is permitted only
when L1 binds one natural question to one current information motive and gives
the L2 session that motive's completion condition; a generic greeting or
service prompt cannot open a session. The motive remains private: L2 opens with
one conversational beat, then guides the exchange one turn at a time and stops
pursuing the motive after an answer or graceful decline. L2 may mark explicit user facts and
corrections as memory proposals; L1 remains the default curator and the deterministic memory
validator owns the final commit. The deployed `gemma4:31b-cloud` stream performs
event-driven situational inference with policy-filtered memory retrieval.
Transcript ingestion and consolidation are still pending. There is no second L1
model, shadow route, or fallback cognition path.

Face identity now has a real local inference boundary rather than treating a
detector box as a person record. System Vision eye/nose landmarks align each
independently verified face, and an external ArcFace R50 Core ML model produces
a normalized 512-dimensional embedding on a latest-one worker capped at 5 Hz.
The worker requests CPU plus Neural Engine and never blocks L0 tracking. Known
profiles require explicit enrollment and are stored encrypted. The identity
store uses a local owner-only installation secret so the persistent L0 process
never blocks on Keychain UI. An unenrolled face may acquire a stable local
`anon_*` pseudonym only after repeated open-set matches; this is an
installation-keyed HMAC of a random cluster ID, not a brittle hash of
floating-point face values. That pseudonym deterministically maps to a local
medium-term person entity, so L1 can form continuity, rapport, and information
motives without a name. Enrollment is a separate, explicit transition that
adds an encrypted recognition profile to the same entity; it does not create a
second person or reset their memory. Pixels, embeddings, and the opaque handle
never enter Gemma context. Labelled same-person/different-person threshold
calibration remains required before a human can be named.

Recognition references are multi-view sets, not one privileged portrait. A
local selector rejects near-duplicate frames, retains observations that improve
the minimum embedding-space separation of the set, and replaces a redundant
view only when a new view improves coverage or is materially clearer. An
anonymous cluster retains at most eight distinct local references; an explicitly
enrolled persistent profile may retain up to twenty-four. New distinct views of
a confirmed profile are stored asynchronously after recognition, so the
identity worker never delays L0 tracking. `--face-identity-status` reports only
the per-profile and per-cluster reference counts—never a handle, embedding,
pixel, or name—so angle coverage can be checked locally.

`maple` configures the realtime speaking voice, not the language model. The
current Live start request sends no model override, so the installed Codex
app-server chooses the realtime model. Separate temporary Codex threads do
support an explicit model and reasoning-effort override.

`soma-codex-bridge`, `--local-speech-recognition`, and local
`AVSpeechSynthesizer` remain an explicit diagnostic/fallback transport. They are
not the persistent launcher's default and must not be described as GPT-Live.
That fallback requires the installed Codex CLI to report `Logged in using
ChatGPT`; no API key is stored by SOMA.

Live text context is push-capable: V3 `initialItems` supplies the opening L0/L1
context and `thread/realtime/appendText` supplies later bounded updates. Images
have a different boundary because the current realtime append contract has no
image item. `capture_view` returns a settled frame as an MCP `image` content
block and short-lived resource link to a Codex tool turn; that turn can inspect
the frame and append a grounded text result to Live. SOMA does not claim that a
JPEG was injected directly into the realtime model when only the MCP/Codex
handoff saw it.

Verify the account and start the JSONL bridge with:

```sh
codex login status
swift run soma-codex-bridge
```

The process first emits `bridge.ready`. It accepts version-1
`CodexAccountTurnRequest` values on standard input and emits `turn.completed`
with the assistant text, Codex thread ID, monotonic latency, and token counts.
Requests use `CodexInteractionContext`, which bounds situation, identity,
rapport, task, memory, embodiment, and privacy projections. A caller can supply
the returned thread ID after a bridge restart; while the process stays alive it
automatically resumes the thread for the same interaction ID.

The diagnostic local transport can check that an on-device language model is
supported and installed. SOMA does not download an asset or fall back to server
recognition:

```sh
/Users/seungyeop/Library/Application\ Support/SOMA/Applications/SOMA\ Subconscious.app/Contents/MacOS/soma-subconscious \
  --speech-recognition-status ko-KR
```

Exercise the same PCM conversion and on-device recognizer used by the live
transport against an explicit local audio file:

```sh
/Users/seungyeop/Library/Application\ Support/SOMA/Applications/SOMA\ Subconscious.app/Contents/MacOS/soma-subconscious \
  --speech-recognition-file ko-KR /absolute/input.aiff
```

Exercise the local spoken-output path without opening the camera or L2:

```sh
/Users/seungyeop/Library/Application\ Support/SOMA/Applications/SOMA\ Subconscious.app/Contents/MacOS/soma-subconscious \
  --speech-synthesis-test ko-KR '연결 완료.'
```

The fallback locale is an explicit transport setting rather than a Korean-only cognitive
assumption; L1 memory may later select it per interaction. This host currently
has Korean, English, Simplified and Traditional Chinese, Japanese, German,
French, and Spanish SpeechTranscriber assets installed. SOMA refuses an
unsupported or uninstalled locale. A 2026-08-15 synthetic transport smoke
transcribed a Korean sentence exactly in 277 ms and returned a Chinese
transcript in 247 ms, with an error on the SOMA proper name; this proves the
local path, not conversational or field-speech accuracy. `SpeechAnalyzer`
itself does not require the legacy server-recognition permission flow.

Tiny 2 Lite LED support uses its predefined RGB palette/pattern engine with four
brightness levels, not arbitrary RGB. The native bridge accepts allowlisted
set/clear/brightness/enabled commands, restores global settings it changed, and
clears every SOMA-owned state on shutdown. The persistent L0 maps exploration,
human detection, contact readiness, listening, cognitive work, and speaking to
firmware states. SOMA composes those colours as interaction affordances for a
person: a slow exploration beacon means it is not yet engaged, steady presence
means it noticed someone, a double flash invites eye contact and speech, a calm
long-on pulse means it is hearing the user, a slow heartbeat asks the user to
wait while it prepares a reply, and steady light accompanies its response.
Exact hue remains firmware-defined. Its contract and evidence are recorded in
the architecture document.

Run the C3 bootstrap contract evaluator with:

```sh
swift run soma-event-eval
```

Its 32 labelled rows are deliberately split into calibration and evaluation
partitions and cover ambient activity, uncertain sampling, persistent novelty,
direct contact, accepted memory curiosity, cooldown, and local safety. They are
an executable routing contract, not captured deployment data or an accuracy
claim. Live, time-aligned camera/audio labels are required before this router
can govern real L0-to-L1 or L0-to-L2 interaction transitions.

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
  `cpuAndNeuralEngine` requested. By default it is evidence only. When the
  explicit local-speech option is enabled, a separate worker consumes a
  bounded in-memory turn after an authorized C3 wake; it never blocks the
  callback or persists audio/transcript text in the L0 trace.
  A first turn additionally requires a current System Vision landmark estimate
  with bilateral pupils, frontal head pose, and social-fovea alignment. This is
  an ephemeral directed-contact estimate, not identity or a biometric record.
  A SOMA-initiated greeting expression grants one eight-second response window.
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

Continuous operation uses two scalar journals. The detailed journal retains
full belief, vision, scene, control-intent, and metrics evidence only within a
bounded rotating window. The important journal keeps source/controller state
changes, target acquire/loss transitions, voice onset/offset, L1 auxiliary wake proposals,
camera mode changes, and an hourly metrics checkpoint; repeated unchanged
states are suppressed. Rotation is configured explicitly rather than inferred
from filenames:

```sh
--output runtime/detail/subconscious.jsonl \
--trace-max-megabytes 128 --trace-retained-files 8 \
--important-output runtime/important/subconscious-important.jsonl \
--important-max-megabytes 16 --important-retained-files 8
```

Those stable basenames create numbered segments and prune older segments both
when a process starts and whenever a segment fills. The native actuator journal
uses the same contract through `--gimbal-trace-max-megabytes` and
`--gimbal-trace-retained-files`. The installed persistent launcher retains up to
1 GiB of detailed evidence, 128 MiB of important history, 128 MiB of actuator
evidence, and four 1 MiB launcher logs. Raw face JPEG diagnostics are not enabled
by the persistent launcher.

## L1 local visual helper

`gemma-4-e2b-it-4bit` runs directly through `mlx-vlm`, without Ollama, as an
optional low-rate helper inside L1. The fast cloud 31B route remains the primary
situational stream; L1 may use E2B for a local image sketch or a remote-data
restriction. E2B produces a bounded scene summary, novelty, social-presence
probability, attention hint, situation hypothesis, and wake proposal. Results
are scalar `l1.auxiliary.semantic` and `l1.auxiliary.wake_proposal` events. The
helper has no separate memory, dialogue, target-selection, camera-ownership, or
motor authority.

It is disabled in the persistent launcher by default: E2B is useful for an
explicit visual audit, but its 1.4-second class inference and multi-gigabyte
unified-memory footprint do not improve L0 fixation or the deployed social
situation cycle. To enable it temporarily, launch with `SOMA_ENABLE_L05_VLM=1`.

The shared embodiment transport is live independently of that automatic
adapter. An MCP client launches:

```sh
.build/soma-live/arm64-apple-macosx/debug/soma-embodiment \
  --socket "$PWD/artifacts/subconscious/runtime/ipc/embodiment-shadow.sock"
```

It implements MCP `initialize`, `ping`, `tools/list`, and `tools/call` over
stdio. The current twenty tools cover state, scene-entity and spherical-map inspection,
semantic target registration/removal, probabilistic attention policy, target tracking,
orientation, exploration policy, view requests, social gimbal expression, lease
release, and person-context inspection/management. The LaunchAgent creates the Unix socket as mode `0600` inside a
mode `0700` directory. Every accepted or rejected mutation is recorded as a
scalar `embodiment.decision` event. `mode=active` and
`physical_actuation_enabled=true` mean the optional L0 adapter is connected;
default command-line runs remain `mode=shadow` and non-actuating.

The running L0 now also projects its persistent `SceneField` and shared
spherical coverage atlas into the MCP state as scalar scene entities and map
cells, and resolves registered semantic targets against them on
a bounded latest-value worker. An explicit `scene_id` remains the same binding
when that entity goes offscreen. Descriptor-only targets use a normalized
association posterior and return `ambiguous` instead of inventing an identity
when several entities fit. Binding transitions are recorded as
`semantic.binding`; pixels, embeddings, facial landmarks, and biometric
templates are never added to this channel.

The same `soma-embodiment` MCP endpoint exposes `get_person_context`,
`set_preferred_language`, `clear_preferred_language`,
`set_contact_preference`, `set_person_rapport`, `set_person_fact`, and
`remove_person_fact`. These tools operate on the L0-owned encrypted memory
journal through the owner-only socket rather than opening a second writer. All
mutations require `confirmed_by_user=true`; they retain explicit-user
provenance, are revisioned, and are eligible for the policy-filtered L1/L2
context projection. They never return or write a face embedding, pixel, raw
transcript, local-only identity record, or a name inferred from a face. L1-proactive
Live context receives an opaque person-context reference solely for these tools.
When a recognized participant has an explicitly stated preferred language, the
L1 creates a compact native-language Live-session instruction from the BCP-47
tag. That instruction is passed both as Live startup policy and scoped session
context, and governs every spoken token unless the person clearly switches
language or asks otherwise; L0 does not maintain a hard-coded translation table.

Accepted motor goals now pass through one semantic intent coordinator and the
existing L0 gimbal owner queue. `orient_to` and `capture_view` align a reachable
gimbal-home-relative bearing; `track_target` moves only after its registered
reference has one non-ambiguous SceneField binding with a spatial bearing;
`set_exploration_policy` reshapes the existing spherical information-gain
distribution; and `express_gimbal` expands a semantic expression into a bounded
smooth route. An unresolved target suspends motion while preserving the lease,
so a later binding can resume without inventing an identity. Preemption,
owner-scoped release, target removal, expiry, process shutdown, stale pose,
joint reachability, and the native helper watchdog all converge on the same L0
stop path.

`capture_view` is a one-shot active-sensing operation rather than an alias for
orientation. L0 uses the native stabilized absolute-position path, refreshes it
within the helper watchdog interval, enters a 2-degree alignment window, leaves
only beyond 4.5 degrees, and requires 180 ms of settled pose before accepting
the next exposure-aligned frame. The frame is centre-cropped to the requested
field of view, encoded as a 640x360 JPEG, and returned as both MCP image content
and a resource link.
`get_view_capture` recovers a timed-out caller by request ID. Resources live in
an owner-only directory, files are mode `0600`, at most 16 handles exist, and a
60-second timer deletes the pixels even if no later query arrives. Only scalar
capture state and geometry enter JSONL traces. Completing capture releases the
one-shot motor goal without deleting the owner's semantic targets or policy.

The physical smoke run `physical-orient-smoke-2` used a 1.2 s L1 lease. The
native trace recorded the first direct command through `manual_active` in
1.274 s, then the existing L0 exploration resumed 0.509 s later. A later
`capture_view` request at azimuth/elevation 0/0 degrees and 65-degree field of
view returned a visually checked, sharp frame in 1.6 s at measured pose
-0.35/-0.05 degrees. A registered `bicycle` bound to `scene-10` became grounded
in 108 ms, was freshly re-observed in 187 ms, drove the physical helper to a
holding stop in 3.83 s, and released on its 20 s lease deadline. These are
deployment checks for active sensing, semantic binding, physical reacquisition,
deadline release, and ownership return—not recognition-accuracy or L1 cognition
claims.

The video callback never waits for the model. An event gate admits a changed
or salient keyframe at most once per second and refreshes an unchanged scene
once per five seconds. The bridge has one in-flight request and one replaceable
pending frame, converts the latter to a 512x288 in-memory JPEG on a utility
queue, and sends it to one persistent local Python process. Neither the JPEG
nor model input is written by the L1 auxiliary path. A local model directory is required
so enabling the bridge cannot silently download a model or call a remote API.
The worker also sets an 8 GB MLX evaluation limit and a 256 MB free-cache limit;
an over-limit inference fails in the advisory process instead of consuming
unbounded unified memory.

The live implementation invokes `mlx-vlm` directly. It does not use Ollama and
has no Ollama fallback. `scripts/soma_l1_auxiliary_ollama_probe.py` is a benchmark-only
tool for an explicitly named comparison model; it is not imported or launched
by `soma-subconscious`.

The installed reference environment is:

```sh
/Library/Frameworks/Python.framework/Versions/3.12/bin/python3 -m venv \
  "$HOME/Library/Application Support/SOMA/venvs/l05"
"$HOME/Library/Application Support/SOMA/venvs/l05/bin/python" -m pip install mlx-vlm
"$HOME/Library/Application Support/SOMA/venvs/l05/bin/hf" download \
  mlx-community/gemma-4-e2b-it-4bit \
  --local-dir "$HOME/Library/Application Support/SOMA/models/gemma-4-e2b-it-4bit"
```

Probe it without changing the running camera service:

```sh
"$HOME/Library/Application Support/SOMA/venvs/l05/bin/python" \
  scripts/soma_l1_auxiliary_probe.py \
  --python "$HOME/Library/Application Support/SOMA/venvs/l05/bin/python" \
  --worker "$PWD/scripts/soma_l1_auxiliary_vlm_worker.py" \
  --model "$HOME/Library/Application Support/SOMA/models/gemma-4-e2b-it-4bit" \
  --image /absolute/path/to/one-consented-test-frame.jpg
```

After that independent probe passes, opt in on a new `soma-subconscious` run
with all three flags:

```sh
swift run soma-subconscious --duration 30 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>' \
  --output artifacts/subconscious/l1-auxiliary-run.jsonl \
  --l1-auxiliary-vlm-python "$HOME/Library/Application Support/SOMA/venvs/l05/bin/python" \
  --l1-auxiliary-vlm-worker "$PWD/scripts/soma_l1_auxiliary_vlm_worker.py" \
  --l1-auxiliary-vlm-model "$HOME/Library/Application Support/SOMA/models/gemma-4-e2b-it-4bit"
```

On the 24 GB Apple Silicon host, a three-request same-image direct-MLX
comparison measured E2B at 1.47 s cold and 1.39 s warm median, versus E4B at
3.00 s cold and 2.75 s warm median. The E2B checkpoint occupies 3.3 GiB instead
of 4.8 GiB and reported a 4.20 GB MLX peak instead of 5.75 GB. E2B is therefore
the preferred explicit helper and E4B remains a comparison fallback. Short-probe
process RSS moved in the opposite direction—3.33 GB for E2B versus 2.31 GB for
E4B—so this is not a claim that every memory metric improved. The person-free
fixture stayed `ambient / none` under E2B, while E4B proposed
`object_presentation / presented_object`; broader labelled human and object
evaluation remains open. During an earlier concurrent E4B benchmark,
the repaired L0 advanced 1,749 video callbacks, 700 person-model attempts,
1,750 face-model attempts, and 1,750 vision updates during a 70-second window
containing 20 consecutive E4B requests. Skipped frames and cumulative inference
maxima did not increase, the L0 PID survived, and its trace recorded no runtime
error or stall. That worker loaded in 2.79 s and its 20-request run measured a
3.41 s cold inference and 2.79 s warm median. This is a bounded coexistence
stress result, not permission to put semantic output in the motor path.

With the semantic-interrupt schema, an earlier E4B direct-MLX run loaded
in 2.22 s, took 3.27 s cold and 2.65 s warm median, and consistently classified
the person-free fixture as `ambient / none / 0.1`. The benchmark-only
`gemma4:31b-cloud` comparison took 0.79 s cold and 0.89 s warm median on the
same fixture. It was faster and has now been selected as the primary L1
situational model. Its active situation-stream adapter still requires the
memory, privacy projection, event
router, and authority boundaries in [COGNITIVE_ARCHITECTURE.md](COGNITIVE_ARCHITECTURE.md).
The Ollama `gemma4:e4b-mlx` and `gemma4:12b-mlx` packages both returned HTTP 400
for image input; loading them for that capability check also increased L0's
cumulative Vision maximum, so both were unloaded and excluded.

The earlier roughly five-minute `IOSurface` failure came from running every
Vision request inside one long-lived GCD work item without a per-frame
autorelease boundary. The worker now drains temporary Vision/IOSurface objects
after every processed frame. A same-PID L0-only run then lasted 898.43 seconds,
advanced from 23 to 22,422 video callbacks, recorded zero Vision runtime
error/stall events, and showed no linear RSS growth. The persistent LaunchAgent
keeps the direct-MLX side loop opt-in. Its first 234.34-second integrated smoke
produced 48 semantic events, zero interrupt false positives, and zero auxiliary-worker
runtime errors; semantic inference ranged from 2.70 to 3.25 seconds. This is
enough for continuous development use, but it is not a multi-hour thermal
qualification.
The original E4B latency run is recorded in
[l05-e4b-mlx-benchmark-20260815.json](artifacts/subconscious/l05-e4b-mlx-benchmark-20260815.json);
the current E2B/E4B same-image decision is recorded in
[l1-auxiliary-e2b-vs-e4b-20260815.json](artifacts/subconscious/l1-auxiliary-e2b-vs-e4b-20260815.json);
the repaired L0 soak and 20-request coexistence window are recorded in
[l0-lifetime-l05-coexistence-20260815.json](artifacts/subconscious/l0-lifetime-l05-coexistence-20260815.json).
The interrupt feature, Ollama comparison, and integrated smoke are recorded in
[l05-semantic-interrupt-benchmark-20260815.json](artifacts/subconscious/l05-semantic-interrupt-benchmark-20260815.json).
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
the SDK-reported attitude and current 86/78/65 FOV mode label. These generic
libdev labels are not treated as Tiny 2 Lite physical angles. The specification
profile is only the fallback; the persistent runtime loads the current
provisional normalized pinhole and camera-to-gimbal rotation from
[`camera-geometry-tiny2lite-20260815.json`](artifacts/subconscious/camera-geometry-tiny2lite-20260815.json).
SceneField, spherical coverage, and panorama projection therefore share the
same focal lengths, principal point, axis signs, and rigid extrinsic. An offscreen
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
The 60-image ring bounds one requested diagnostic session; the caller owns that
directory's lifetime. It is therefore unsuitable as an always-on runtime flag.

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

When no retained scene hypothesis wins, L0 falls back to a shared spherical
scene atlas rather than a fixed left/right scan. Every fresh-pose video frame
marks the actual FOV on a seven-layer azimuth/elevation map spanning every
direction visible from a valid autonomous camera centre. The atlas retains
coverage counts, recency, unproductive visits, panorama quality, compact
place familiarity/conflict, expected information gain, and remembered entity bearings;
`get_spatial_map` exposes the same bounded scalar state to L1. Directions not
well resolved receive the larger exploration posterior, while repeated
unproductive visits are penalized and then recover gradually rather than
becoming permanently forbidden.

`GimbalKinematicEnvelope` is the single source of truth shared by frame-edge
eligibility, atlas construction, autonomous route planning, and offscreen face
re-acquisition. The planner first finds the nearest reachable camera centre
whose usable FOV contains the requested world bearing. It therefore observes
an edge-visible target without centring the joint on that target, rejects an
unreachable direction before motion, and routes an opposite-side target through
the finite joint interior instead of wrapping across the ±180° seam. Normal
routes never ask the later boundary-recovery state to repair a bad waypoint;
that state is reserved for measured external displacement or stale legacy
controller state.
Pan and pitch velocities are updated at
50 ms control intervals with 30°/s pan and 18°/s pitch exploration caps, 120/80°/s²
acceleration limits, and stopping-distance braking;
a new waypoint is selected inside a 10° look-ahead radius and blends into the
current velocity instead of hitting the exact centre and inserting a stop/rest
pulse. Waypoint timeout scales with angular travel instead of cutting
a distant route at a fixed duration. The helper discards superseded direct-motion commands while an
SDK call is in flight, so delayed commands cannot accumulate behind perception.
An unexpected attitude outside the planned envelope receives an inward velocity
curve; the SDK's absolute centre operation is reserved for a measured
two-direction stall. The JSONL trace remains scalar. When `--panorama-output`
is supplied, a separate utility-priority compositor also maintains exactly one
rolling 1024×256 JPEG and one metadata JSON; it does not append raw frames.
Each process publishes an empty session map before admitting frames, so a
human-occluded startup cannot expose the previous process's panorama as current.
The equirectangular raster has a fixed world convention—azimuth increases from
left to right and elevation from bottom to top. The OBSBOT SDK attitude is
converted once into canonical visual yaw/elevation before projection; its
image-axis signs are not applied again to individual source rays. Source
sampling uses a coupled 3D yaw/pitch camera basis rather than two independent
planar offsets, so elevated diagonal views remain on the same sphere.

The panorama path admits at most 4 frames/s into a one-slot mailbox and may wait
125 ms for the attitude sample after exposure. It interpolates only between
measured packets no farther than 120 ms from exposure and with a bracket no
wider than 200 ms; unbracketed or wider poses are dropped rather than projected
from stale pre-motion state. These bounds cover the SDK's observed native-AI
sampling gaps without permitting extrapolation. The real-time face detector
and motor controller keep their strict timestamps and never wait for this
branch. People are masked from the background composite; non-human detections
remain ordinary scene content rather than opening holes in the panorama. A
frame with a current person rectangle may contribute only its
unmasked background; after that rectangle disappears, the entire frame is
rejected for 750 ms across short detector gaps. Feature Print requires an
empty dynamic mask.
The compositor does not average repeated pixels. It scores each observation
from the bracketed gimbal angular velocity and view-centre geometry. At up to
2°/s it may use the full frame; from 2°/s through 40°/s it uses only a central
vertical strip whose width covers the elapsed interval since the last projected
frame. Faster frames are rejected. The raster worker evaluates only the
spherical window that the current perspective frame can see, preventing its
mailbox from falling behind a continuous sweep. The camera model and pose basis
are validated and prepared once per frame rather than rebuilt per output pixel.
It otherwise replaces an empty
pixel or a prior pixel only when quality improves by a fixed hysteresis margin.
The higher-quality observation owns the overlap interior while a bounded
OpenCV feather weight softens only its seam; repeated views are not globally
averaged into a progressively blurred image. On the same utility queue, Vision
translation registration compares consecutive overlapping background views
that already pass the motion gate and refines only the residual between their
image motion and measured gimbal motion. The correction requires both request
confidence and robust residual weight, is bounded to 4% of each FOV, and is
rejected when the motion exceeds the local translation model; every pair is
re-anchored to measured attitude, so errors do not accumulate as visual
odometry. At most once per second, a human-free stable view also runs Apple's
Vision Feature Print model and contributes its normalized learned embedding to
the nearest fixed spherical cell. Returning to that bearing with the same
encoder, revision, and element count updates the same cell and records
familiarity or conflict instead of creating another location. An incompatible
model revision starts new evidence and is never treated as a revisit. These
embeddings are scene appearance cues, are not used as biometric or object
identity, and remain sensitive local derived data.

`--panorama-place-memory /absolute/place-memory.json` persists only those
versioned embeddings, bearings, familiarity/conflict, and observation counts.
It requires `--panorama-output`, overwrites one bounded schema-1 file atomically,
caps it at 4 MiB/256 cells, and applies `0600` file plus `0700` directory
permissions. Pixel data, labels, people, scene entities, and monotonic runtime
state are absent. Startup validates the encoder/revision and rejects an
incompatible or malformed file instead of silently merging it. The rolling
JPEG still starts empty each process; only compatible place evidence is
restored across sessions.
`get_spatial_map` reports the
local image path, revision, raw and quality coverage, mean observation quality,
pose misses, low-quality frame rejection, quality-protected pixels,
masked-pixel count, alignment timing and
acceptance, Feature Print timing/failures, place revisit statistics, restored
place count, and active encoder revision.

### Tiny 2 Lite camera geometry calibration

The native helper disables auto zoom, commands 1×, and requires a successful
zoom readback before it exposes the motor bridge. An explicit calibration
session then follows 21 overlapping absolute pan/pitch waypoints and records
only frames measured at no more than 0.75°/s. The fitter uses pose-separated
SIFT pairs with MAGSAC and a disjoint validation split to estimate normalized
intrinsics plus one camera-to-gimbal rotation.

The deployed schema-1 model comes from a fresh fixed-zoom 1× capture with 28
settled frames. It fits normalized intrinsics, Brown radial distortion, and the
camera-to-gimbal rotation from 12 training pairs/813 matches, then validates on
five disjoint pairs/369 matches. Held-out reprojection improves from 41.325 px
RMSE to 6.098 px, with 8.204 px p90. Rotation-centre parallax remains visible
for nearby desk objects because a single rotational camera model cannot remove
translation caused by the offset lens centre. Raw calibration JPEGs stay
temporary and are not enabled by the persistent launcher.

`--panorama-strip-scan` is an explicit diagnostic route, not the normal social
controller. With panorama output and autonomous external control enabled, it
runs a continuous boustrophedon sweep over four overlapping elevations while
the ordinary runtime still lets human tracking preempt normal exploration.
The compositor uses Vision translation for pose residuals, then OpenCV channel
exposure compensation and feather seam weights on the spherical observation.
An AE/AWB-on physical circuit projected 643 frames with no low-quality
rejection, accepted 605/622 registration attempts, and covered 96.9% of the
physically reachable raster; 73.6% reached the high-quality threshold. Mean
registration and stitch stages were 6.68 ms and 5.28 ms on the separate utility
queue. An OpenCV pyramidal-LK comparison accepted only 152/548 pairs at 9.37 ms
mean, so it is not the deployed registration path. Automatic exposure and white
balance remain enabled: measured channel compensation averaged about 1%, while
locking the camera would reduce its ability to expose differently lit
directions. The Tiny 2 Lite SDK exposes manual white-balance and exposure
controls; a future comparison must save and restore the prior values as one
explicit scan session rather than changing persistent camera state.

No-target exploration consumes the same spherical quality state. Its sampling
posterior uses expected information gain: 20% scalar recency novelty, 45%
panorama-quality deficit, and 35% unresolved or conflicting place evidence,
while retaining route distance, failure, elevation, and joint-boundary terms.
A high-information tile is brought as near the image centre as the gimbal
envelope permits; a familiar clear tile blends earlier into the next route so
normal exploration remains continuous. Fresh human
tracking still preempts this path; panorama pixels never constitute person or
object motor evidence. Nothing uploads the panorama to a cloud model
automatically.

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
