#!/usr/bin/env python3
"""Benchmark the persistent SOMA L1 visual helper without touching the live service."""

from __future__ import annotations

import argparse
import base64
import io
import json
import statistics
import subprocess
import time

from PIL import Image


def read_envelope(process: subprocess.Popen[str]) -> dict:
    assert process.stdout is not None
    line = process.stdout.readline()
    if not line:
        assert process.stderr is not None
        diagnostic = process.stderr.read()[-1_000:]
        raise RuntimeError(f"worker exited with {process.poll()}: {diagnostic}")
    return json.loads(line)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", required=True)
    parser.add_argument("--worker", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--requests", type=int, default=3)
    parser.add_argument("--resize-width", type=int, default=512)
    parser.add_argument("--no-target", action="store_true")
    args = parser.parse_args()
    if args.requests < 1:
        parser.error("--requests must be positive")

    with Image.open(args.image) as source_image:
        source_size = source_image.size
        scale = min(1, args.resize_width / source_image.width)
        resized_size = (round(source_image.width * scale), round(source_image.height * scale))
        resized_image = source_image.convert("RGB").resize(resized_size, Image.Resampling.LANCZOS)
        image_buffer = io.BytesIO()
        resized_image.save(image_buffer, format="JPEG", quality=85)
    image_payload = base64.b64encode(image_buffer.getvalue()).decode("ascii")
    started = time.perf_counter()
    process = subprocess.Popen(
        [args.python, args.worker, "--model", args.model],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None
    ready = read_envelope(process)
    if ready.get("type") != "health" or ready.get("state") != "ready":
        raise RuntimeError(f"worker did not become ready: {ready}")
    ready_wall_ms = (time.perf_counter() - started) * 1_000

    results = []
    for request_id in range(1, args.requests + 1):
        capture_ns = time.monotonic_ns()
        request = {
            "type": "infer",
            "requestID": request_id,
            "context": {
                "captureNS": capture_ns,
                "trigger": "benchmark",
                "surprise": 0.7 if request_id == 1 else 0.1,
                "informationGain": 0.4,
                "presenceProbability": 0 if args.no_target else 0.8,
                "voiceProbability": 0,
                "targetKind": None if args.no_target else "human",
                "targetLabel": None if args.no_target else "face",
                "targetProbability": 0 if args.no_target else 0.8,
                "targetStatus": "none" if args.no_target else "tracked",
            },
            "imageJPEGBase64": image_payload,
        }
        request_started = time.perf_counter()
        process.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        process.stdin.flush()
        envelope = read_envelope(process)
        wall_ms = (time.perf_counter() - request_started) * 1_000
        if envelope.get("type") != "result":
            raise RuntimeError(f"inference failed: {envelope}")
        try:
            rss_kilobytes = int(subprocess.check_output(
                ["ps", "-o", "rss=", "-p", str(process.pid)],
                text=True,
            ).strip())
        except (OSError, subprocess.SubprocessError, ValueError):
            rss_kilobytes = 0
        results.append({
            **envelope,
            "wallMS": wall_ms,
            "workerRSSMB": rss_kilobytes / 1024,
        })

    process.stdin.write('{"type":"shutdown"}\n')
    process.stdin.flush()
    process.wait(timeout=10)
    inference_times = [float(result["inferenceMS"]) for result in results]
    wall_times = [float(result["wallMS"]) for result in results]
    print(json.dumps({
        "model": args.model,
        "image": args.image,
        "source_image_size": source_size,
        "transport_image_size": resized_size,
        "requests": args.requests,
        "process_ready_wall_ms": ready_wall_ms,
        "worker_load_ms": ready.get("loadMS"),
        "cold_inference_ms": inference_times[0],
        "warm_inference_ms": inference_times[1:],
        "warm_inference_median_ms": statistics.median(inference_times[1:]) if len(inference_times) > 1 else None,
        "maximum_worker_rss_mb": max(float(result["workerRSSMB"]) for result in results),
        "maximum_reported_peak_memory_gb": max(float(result.get("peakMemoryGB", 0)) for result in results),
        "wall_ms": wall_times,
        "results": results,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
