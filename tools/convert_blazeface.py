#!/usr/bin/env python3
"""Convert the pinned BlazeFace PyTorch checkpoint into SOMA's Core ML package.

Run with coremltools and torch installed, against the checked-out source at
commit 852bfd8e3d44ed6775761105bdcead4ef389a538:

  python tools/convert_blazeface.py /path/to/BlazeFace-PyTorch \
    Sources/SOMASubconscious/Resources/BlazeFaceShortRange.mlpackage
"""

import sys
from pathlib import Path

import coremltools as ct
import torch
import torch.nn as nn
import torch.nn.functional as F


class FaceRaw(nn.Module):
    """Fixed-batch raw BlazeFace head; decoding remains in the Swift runtime."""

    def __init__(self, detector):
        super().__init__()
        self.detector = detector

    def forward(self, image):
        image = F.pad(image, (1, 2, 1, 2), "constant", 0)
        features8 = self.detector.backbone1(image)
        features16 = self.detector.backbone2(features8)
        scores8 = self.detector.classifier_8(features8).permute(0, 2, 3, 1).reshape(1, 512, 1)
        scores16 = self.detector.classifier_16(features16).permute(0, 2, 3, 1).reshape(1, 384, 1)
        boxes8 = self.detector.regressor_8(features8).permute(0, 2, 3, 1).reshape(1, 512, 16)
        boxes16 = self.detector.regressor_16(features16).permute(0, 2, 3, 1).reshape(1, 384, 16)
        return torch.cat((boxes8, boxes16), dim=1), torch.cat((scores8, scores16), dim=1)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: convert_blazeface.py <BlazeFace-PyTorch checkout> <output.mlpackage>")
    source = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    sys.path.insert(0, str(source))
    from blazeface import BlazeFace

    detector = BlazeFace()
    detector.load_weights(source / "blazeface.pth")
    example = torch.zeros(1, 3, 128, 128)
    traced = torch.jit.trace(FaceRaw(detector).eval(), example, strict=False)
    model = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="image",
            shape=example.shape,
            color_layout=ct.colorlayout.RGB,
            scale=1 / 127.5,
            bias=[-1.0, -1.0, -1.0],
        )],
        outputs=[ct.TensorType(name="raw_boxes"), ct.TensorType(name="raw_scores")],
        minimum_deployment_target=ct.target.macOS13,
        convert_to="mlprogram",
    )
    model.author = "SOMA conversion from MediaPipe BlazeFace weights"
    model.license = "Apache License 2.0"
    model.short_description = "BlazeFace short-range face detector raw boxes and scores"
    model.user_defined_metadata["soma.source_commit"] = "852bfd8e3d44ed6775761105bdcead4ef389a538"
    model.user_defined_metadata["soma.input"] = "128x128 RGB scaled to [-1,1]"
    model.save(str(output))


if __name__ == "__main__":
    main()
