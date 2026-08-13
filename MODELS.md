# Bundled models

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
