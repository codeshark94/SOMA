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
