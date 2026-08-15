# Bundled models

## Apple Vision Feature Print

SOMA uses the system `VNGenerateImageFeaturePrintRequest` only on stable,
human-free panorama frames, at most once per second on the utility compositor
queue. The encoder revision and element count are stored with every normalized
Float32 scene embedding; a mismatch is rejected rather than compared. The
embedding supports fixed-base spherical place familiarity and change evidence,
not face identity, object identity, dialogue, or direct motor authority.

This model is supplied by macOS rather than bundled in the repository. Apple
does not expose a per-request Neural Engine placement guarantee for this Vision
operation, so SOMA records its revision, attempts, failures, and latency without
claiming ANE execution. Optional cross-session storage contains only bounded
embeddings and scalar spherical-cell statistics in an owner-only local file;
no camera pixels or scene entities are included.

## YOLOv3TinyFP16

- File: `Sources/SOMASubconscious/Resources/YOLOv3TinyFP16.mlmodel`
- SHA-256: `73406178d0f5793d0d5d1e38274acd146a744c2245c9b63a11998a5015925dda`
- Source: [Apple Core ML model gallery](https://developer.apple.com/machine-learning/models/)
- Model: YOLOv3 Tiny, FP16, COCO object detection; SOMA accepts only the
  `person` label as attention evidence.
- License: MIT, as stated on the [Apple model card](https://huggingface.co/apple/coreml-YOLOv3).

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

This is L1's active optional local visual helper. A same-image three-request
probe measured 1.47 s cold and 1.39 s warm-median inference with a 4.20 GB
MLX-reported peak. It remains asynchronous advisory cognition and is never part
of the L0 tracking or motor loop. MLX uses the Apple GPU and unified memory,
not the Neural Engine. The persistent worker requires the existing local path
and has no Ollama or network fallback.

## Evaluated local Gemma 4 E4B MLX-VLM fallback

- Local directory: `~/Library/Application Support/SOMA/models/gemma-4-e4b-it-nvfp4`
  (downloaded runtime asset; not bundled in the Swift package or Git repository).
- Repository: [mlx-community/gemma-4-e4b-it-nvfp4](https://huggingface.co/mlx-community/gemma-4-e4b-it-nvfp4)
  at revision `769ca8889f89f8ec8c1ca59bf427332895eb1cb2`.
- Upstream: `google/gemma-4-E4B-it` source revision
  `fee6332c1abaafb77f6f9624236c63aa2f1d0187`, according to the conversion card.
- Variant: NVFP4; `model.safetensors` size 5,146,755,012 bytes and SHA-256
  `42361d0a7d1af5c9cf6f42c2a46be0f39fa4e060cedf0dfc43b0b4d97e413c9e`.
- License: Gemma terms, as declared by the conversion model card. The operator
  is responsible for accepting and complying with those terms for the local
  downloaded checkpoint.

E4B remains an evaluated comparison fallback, not the persistent default. MLX
runs it on the Apple GPU and unified memory, not the Neural Engine. The
real-time L0 path never waits for it, and its scalar advisory output has no
target-selection or actuator authority. The command line requires an existing
local directory; there is no runtime network fallback. The worker calls
`mlx-vlm` directly and never routes the local checkpoint through Ollama.
