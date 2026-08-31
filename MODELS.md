# Bundled models

## CPU spatial place signature

SOMA derives a normalized 12×8 RGB spatial signature from stable, human-free
panorama frames. The signature is a local CPU feature, not a learned identity
model: it supports fixed-base spherical place familiarity and change evidence,
not face identity, object identity, dialogue, or direct motor authority.

Its encoder name, revision, and element count are stored with every bounded
Float32 embedding. A signature from a different encoder or revision is rejected
rather than compared. Optional cross-session storage contains only these
embeddings and scalar spherical-cell statistics in an owner-only local file;
no camera pixels or scene entities are included.

## Ultralytics YOLO11n

- Package: `Sources/SOMASubconscious/Resources/YOLO11n.mlpackage`
- Core ML model SHA-256: `4922e5fd9c9511e8e042fb93435d250665a2b837f36cf7847594f3dfaa527843`
- Weight SHA-256: `d291ffef8e23d2d944ef6c17470d83b157f5d3300fad742a1a27af1bad7adc4f`
- Model: Ultralytics YOLO11n, COCO object detection with built-in NMS; SOMA
  accepts only the `person` label as L0 attention evidence.
- License: AGPL-3.0, as embedded in the package metadata and documented by
  [Ultralytics](https://docs.ultralytics.com/license/). An Enterprise license
  is the alternative offered by Ultralytics for use outside the AGPL route.

The package is a bundled third-party model asset. SOMA's source is also
distributed under AGPL-3.0; anyone redistributing or deploying the bundled
YOLO11n package must determine and satisfy the applicable Ultralytics terms.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

SOMA requires macOS 13 or later and loads this model with
`MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`. This excludes GPU
execution and permits Core ML to use the Neural Engine with CPU fallback only
for unsupported operations. Core ML does not expose a public per-operation
attestation that every operation ran on the Neural Engine; trace evidence proves
the requested configuration and completed Core ML inference, while Instruments
profiling is needed for hardware-level attribution.

## BlazeFaceShortRange

- Package: `Sources/SOMASubconscious/Resources/BlazeFaceShortRange.mlpackage`
- Core ML model SHA-256: `4dbdfafae0109d18b80c4ea44f9c944b8f2a3437ae9f888d35dba2386d76ffbd`
- Weight SHA-256: `a853df2cdca76830189cac29dc2d82a368ce6d4e8b5b38312a39a730ffd96dcd`
- Source weights and architecture:
  [hollance/BlazeFace-PyTorch](https://github.com/hollance/BlazeFace-PyTorch)
  at `852bfd8e3d44ed6775761105bdcead4ef389a538`.
- License: Apache-2.0, as declared by that project's
  [LICENSE](https://github.com/hollance/BlazeFace-PyTorch/blob/master/LICENSE).
- Model: short-range MediaPipe BlazeFace; 128x128 RGB input, raw
  `896x16` box regressions and `896x1` scores. SOMA decodes and overlap-suppresses
  boxes locally, accepts scores of at least 0.75, and emits only bounding-box
  attention evidence.

The package was converted from the pinned PyTorch checkpoint with
`coremltools` for macOS 13+, using `MLModelConfiguration.computeUnits =
.cpuAndNeuralEngine` at runtime. Core ML may fall back to CPU for unsupported
operations and has no public per-operation placement attestation. The trace
therefore records requested compute policy and completed inference, not a claim
that every operation ran on the Neural Engine. The exact conversion recipe is
[`tools/convert_blazeface.py`](tools/convert_blazeface.py).

## SileroVAD256ms

- Package: `Sources/SOMAVADModel/Resources/SileroVAD256ms.mlmodelc`
- Source package: [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml)
  at `b419383c55c110e2c9271fa6ee0ea83d03c70d96`.
- Upstream model: [snakers4/silero-vad](https://github.com/snakers4/silero-vad),
  unified v6.2.1 VAD. The source package and upstream project declare MIT.
- The bundled attribution and MIT notice are retained in
  [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
- Weight SHA-256: `53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063`.
- Model SHA-256: `c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270`
  (`model.mil`); metadata SHA-256:
  `2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6`.
- Model: 16 kHz mono, recurrent 4,160-sample (260 ms) windows; scalar speech
  probability plus 128-value hidden and cell states. SOMA uses a fixed 0.50
  activation threshold and a 520 ms inactive hangover.

SOMA loads this pre-converted Core ML package with
`MLModelConfiguration.computeUnits = .cpuAndNeuralEngine`; no audio leaves the
process and no model is downloaded at runtime. That setting excludes GPU and
allows CPU fallback for unsupported operations. It is a requested execution
policy—not proof that every layer, especially the recurrent layers, ran on the
Neural Engine. The live trace separately records Core ML inference duration and
window-end-to-evidence duration; a speech onset necessarily also waits for up
to one 260 ms input window.

## ArcFace R50 local face identity

- Runtime asset: `~/Library/Application Support/SOMA/models/arcface-r50-v1/ArcFaceR50.mlmodelc`
  (installed locally, not committed to Git).
- Source: InsightFace `buffalo_l` model package, recognition network
  `w600k_r50.onnx`; 112x112 RGB input and a 512-dimensional ArcFace output.
- Source archive SHA-256:
  `80ffe37d8a5940d59a7384c201a2a38d4741f2f3c51eef46ebb28218a7b0ca2f`.
- Installed Core ML SHA-256: `model.mil`
  `91c6ae2e6d8f8c4206ba78fb47fc8b3451bc55477b32a84d94d85a9bde47774c`,
  `weights/weight.bin`
  `144520cc668d73cda37fdece90776ad3c7fb57a9c39449dc546c8054723aa70a`.
- Reproduction: `scripts/install-soma-face-identity-model.zsh` verifies the
  archive, locks Python 3.12, the complete conversion environment, and Xcode
  build 17F113, converts it with `scripts/convert_arcface_coreml.py`, verifies
  the deterministic model and weights plus the stable metadata schema, then
  loads the compiled package with Core ML before installing it with owner-only
  permissions. The compiler-generated `metadata.json` conversion date and
  `coremldata.bin` containers vary between equivalent compilations, so those
  artifacts are checked semantically and by successful loading rather than by
  byte identity.

The runtime aligns independently verified eye and nose landmarks to ArcFace's
canonical template, then requests `.cpuAndNeuralEngine`. A deterministic probe
against the converted PyTorch graph measured cosine similarity `0.99842`; a
30-run warm probe measured median `1.95 ms`, p95 `2.10 ms`, and max `2.85 ms`
on this machine. These numbers cover the embedding model, not face detection,
landmark verification, or end-to-end identity latency. The compute setting is
a requested Core ML policy and does not prove per-operation ANE placement.

InsightFace code is MIT, but its pretrained recognition weights and training
data are restricted to non-commercial research unless separately licensed.
SOMA therefore treats this checkpoint as a local research asset rather than a
redistributable product dependency.

Known-person references require explicit enrollment and are encrypted locally.
The identity store uses an owner-only local installation secret rather than a
Keychain query on the persistent L0 startup path, so it cannot trigger or wait
on a Keychain authorization dialog. Unenrolled people are compared by cosine
similarity into bounded anonymous clusters; the exported `anon_*` handle is an
installation-keyed HMAC of a random cluster ID, never a direct hash of the face
vector. A cluster becomes durable only after repeated evidence, expires under
the retention policy, can be forgotten, and never exports pixels or embeddings
to Gemma, traces, or remote services.

## Active local Gemma 4 E2B MLX-VLM helper

- Local directory: `~/Library/Application Support/SOMA/models/gemma-4-e2b-it-4bit`
  (downloaded runtime asset; not bundled in the Swift package or Git repository).
- Repository: [mlx-community/gemma-4-e2b-it-4bit](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit)
  at revision `238767527555cb75a05732a84dff5d6ba0dd6809`.
- Variant: 4-bit; `model.safetensors` size 3,550,670,554 bytes and SHA-256
  `038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e`.
- License: Gemma terms, as declared by the conversion model card. The operator
  is responsible for accepting and complying with those terms for the local
  downloaded checkpoint.

`scripts/install-soma-l05-model.zsh` downloads only that immutable revision,
verifies every runtime file against `config/l05-model.sha256`, and atomically
activates the checkpoint. The repository does not redistribute the model.

This is L1's optional local semantic helper. A same-image three-request
probe measured 1.47 s cold and 1.39 s warm-median inference with a 4.20 GB
MLX-reported peak. It remains asynchronous visual advisory cognition and is never part
of the L0 tracking, motor, or conversation-tool loop. Live Voice tool selection
uses the primary `gemma4:31b-cloud` route through Ollama native `tools` and
`message.tool_calls`; L2 validates the advice and retains execution authority.
E2B cannot select or execute tools or speak. MLX uses the Apple GPU and unified
memory, not the Neural Engine. The persistent launcher leaves it off by default because
it adds multi-gigabyte unified-memory pressure without contributing to L0
fixation or social decisions. Set `SOMA_ENABLE_L05_VLM=1` only for an explicit
visual audit. The worker requires the existing local path and has no Ollama or
network fallback.

The local semantic worker accepts only this pinned E2B checkpoint. There is no
alternate local-model fallback and no Ollama route for L0.5 perception.
