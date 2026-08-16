<p align="center">
  <img src="assets/branding/soma-mark.png" width="248" alt="SOMA character mark">
</p>

<h1 align="center">SOMA</h1>

<p align="center"><strong>An embodied local intelligence with a non-negotiable physical boundary.</strong></p>

<p align="center">
  <img alt="macOS 13 or later" src="https://img.shields.io/badge/platform-macOS%2013%2B-111827?style=flat-square&amp;logo=apple&amp;logoColor=white">
  <img alt="Local-first" src="https://img.shields.io/badge/runtime-local--first-0f766e?style=flat-square">
  <img alt="Safety-gated" src="https://img.shields.io/badge/actuation-safety--gated-7c2d12?style=flat-square">
</p>

<p align="center">
  <a href="COGNITIVE_ARCHITECTURE.md">Architecture</a> ·
  <a href="TECHNICAL_REFERENCE.md">Technical reference</a> ·
  <a href="PLAN.md">Roadmap</a> ·
  <a href="MODELS.md">Models</a>
</p>

SOMA is a macOS system for an OBSBOT Tiny 2 Lite that combines local
perception, bounded live conversation, and deliberate physical presence. It
can notice, understand, and respond—but a language model never acquires a
direct path to camera control.

## Presence, without surrendering control

> [!IMPORTANT]
> **L0 observes and moves. L1 interprets. L2 converses.** Every physical action
> still passes back through L0’s local safety, stabilization, watchdog, and
> joint-limit checks.

**L0 · Subconscious** keeps the camera, microphone, VAD, target continuity,
spatial coverage, and final motor veto close to the device.

**L1 · Situation stream** turns bounded evidence and permitted memory into
context, curiosity, and goal-level attention—never SDK velocity.

L1 is time-aware: a public-world brief may be collected through an ephemeral
Codex App Server session **once per local calendar day**, then kept as encrypted
daily memory. It never receives person identity, camera media, or conversation
content during that collection; relevance to a person is judged locally from
their permitted memory and interests.

**L2 · Interaction** owns account-backed live conversation and user-requested
work, while using the same leased embodiment boundary as L1.

While Live Voice is active, L0 keeps only one recent downscaled camera JPEG in
memory. A frame no older than two seconds is injected into the L2 turn when the
person begins speaking, so a request to look at the current view has fresh
sensor evidence rather than a textual scene guess. The frame is never written
to a trace, report, person memory, or disk. `capture_view` remains the separate
MCP path for a deliberate reframe or target-specific view.

Read the complete authority model in
[COGNITIVE_ARCHITECTURE.md](COGNITIVE_ARCHITECTURE.md).

## The control surface

Launch the native status-menu application during development:

```sh
swift run soma-menu-bar
```

The menu bar is the local interface between a person and the running device.

**Voice** — enable account-backed realtime conversation and select a voice,
including `Maple`.

**Indicator** — choose an Expressive, Contextual, Quiet, or Off response;
adjust brightness from 0–3; then assign a verified colour and supported
behaviour to each meaningful interaction state. The Tiny 2 Lite exposes yellow,
blue, and green. Continuous blinking is a verified blue firmware capability,
not a simulated RGB effect.

**Attention** — restrict verified-human tracking or no-target exploration that
the active service has already been authorized to perform. These controls never
create a new physical permission.

**Administrator identity** — explicitly enroll the face currently in view, set
a display name or preferred address, inspect local verification, or delete the
enrollment. Facial templates remain encrypted on this Mac and never enter the
activity trace or L2 context. An administrator L2 session can compare the
current non-biometric presence roster with registered identities and update
their explicit language, rapport, and factual context. An unregistered speaker
can still use interaction-scoped embodiment tools, but cannot create a
persistent person record until explicit enrollment.

**Runtime** — see the current Vision, Voice, Identity, Embodiment, and
indicator state without exposing raw camera or microphone media.

## Start safely

Build and run the test suite:

```sh
swift build
swift test
```

Inspect connected capture devices without moving the camera:

```sh
swift run soma-probe --list-formats
```

Then run a bounded, read-only health probe with the reported IDs:

```sh
swift run soma-probe --duration 60 \
  --video-id '<OBSBOT video unique ID>' \
  --audio-id '<OBSBOT microphone unique ID>'
```

The probe writes scalar JSONL health telemetry only. It neither records media
nor moves the camera.

<details>
<summary><strong>Local companion installation</strong></summary>

<br>

The launcher packages configured helpers, code-signs the app, and registers the
current user’s menu-bar LaunchAgent:

```sh
swift build --build-path .build/soma-live
scripts/install-soma-subconscious-app.zsh
```

Review the script and explicit motion flags before enabling a camera-control
path.
</details>

<details>
<summary><strong>Requirements</strong></summary>

<br>

- macOS 13 or later and a Swift 6 toolchain
- OBSBOT Tiny 2 Lite for camera and indicator features
- The vendor SDK only for explicitly enabled native camera control
- A signed-in local Codex installation only for account-backed live voice
</details>

## Inside the project

**Core contracts**
[`Sources/SOMACore`](Sources/SOMACore) holds cognition, memory, identity,
settings, and embodiment leases.

**Device runtime**
[`Sources/SOMASubconscious`](Sources/SOMASubconscious) hosts L0 perception and
the local safety boundary; [`Sources/SOMANativeTracking`](Sources/SOMANativeTracking)
is the explicitly gated OBSBOT SDK bridge.

**Human-facing applications**
[`Sources/SOMAMenuBar`](Sources/SOMAMenuBar) provides the native control
surface, and [`Sources/SOMALiveVoice`](Sources/SOMALiveVoice) provides the
account-backed live-voice helper.

**Verification**
[`Tests/SOMACoreTests`](Tests/SOMACoreTests) contains core contract and
regression coverage.

## The technical record

- [Technical reference](TECHNICAL_REFERENCE.md) — runtime behaviour, command
  boundaries, hardware observations, traces, and calibration evidence.
- [Cognitive architecture](COGNITIVE_ARCHITECTURE.md) — layer contracts,
  authority boundaries, and privacy model.
- [Roadmap](PLAN.md) — execution sequence and open work.
- [Model registry](MODELS.md) — model roles and deployment boundaries.
- [VAD evaluation](docs/VAD_EVALUATION.md) — evaluation protocol and corpus
  constraints.

## Source artwork

[`assets/branding/soma-original.png`](assets/branding/soma-original.png) is the
unaltered source illustration. The compact
[`soma-mark.png`](assets/branding/soma-mark.png) is a display-only crop for the
README and application derivatives.
