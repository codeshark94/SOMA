#!/usr/bin/env python3
"""Convert InsightFace w600k_r50.onnx into SOMA's 112x112 Core ML embedder."""

from __future__ import annotations

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import torch
from onnx2torch import convert


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.output.suffix != ".mlpackage":
        raise SystemExit("--output must end in .mlpackage")

    torch.manual_seed(0)
    source = onnx.load(str(args.input))
    onnx.checker.check_model(source)
    model = convert(source).eval()
    example = torch.zeros((1, 3, 112, 112), dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(model, example, strict=False)
        traced = torch.jit.freeze(traced.eval())

    converted = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="face",
                shape=example.shape,
                color_layout=ct.colorlayout.RGB,
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
            )
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    )
    converted.author = "SOMA local conversion of InsightFace w600k_r50.onnx"
    converted.short_description = "512D ArcFace embedding for aligned 112x112 RGB faces"
    converted.version = "1"
    converted.save(str(args.output))


if __name__ == "__main__":
    main()
