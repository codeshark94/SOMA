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
