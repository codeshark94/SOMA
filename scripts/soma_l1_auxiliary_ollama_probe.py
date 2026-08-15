#!/usr/bin/env python3
"""Compare Ollama vision models for SOMA L1 without changing the live service."""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import statistics
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from PIL import Image


SITUATIONS = ["social_bid", "object_presentation", "scene_transition", "ambient", "uncertain"]
WAKE_REASONS = ["direct_social_bid", "presented_object", "unexpected_change", "ambiguity", "none"]


def post_json(endpoint: str, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        diagnostic = error.read().decode("utf-8", errors="replace")[-1_000:]
        raise RuntimeError(f"HTTP {error.code}: {diagnostic}") from error


def parse_content(response: dict[str, Any]) -> dict[str, Any]:
    message = response.get("message", {})
    content = message.get("content", "") or message.get("thinking", "")
    if not content:
        raise ValueError(
            f"empty model message; keys={sorted(message)}; done_reason={response.get('done_reason')}"
        )
    decoder = json.JSONDecoder()
    parsed = None
    for index, character in enumerate(content):
        if character != "{":
            continue
        try:
            candidate, _ = decoder.raw_decode(content[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict):
            parsed = candidate
            break
    if parsed is None:
        raise ValueError(f"non-JSON model message: {content[:500]!r}")
    if not isinstance(parsed, dict):
        raise ValueError("model response was not a JSON object")
    return parsed


def duration_ms(response: dict[str, Any], key: str) -> float:
    return float(response.get(key, 0)) / 1_000_000


def validate_result(result: dict[str, Any]) -> None:
    required = {"summary", "situation", "wake_reason", "wake_score", "confidence"}
    missing = sorted(required - result.keys())
    if missing:
        raise ValueError(f"model result missing keys: {missing}")
    if result["situation"] not in SITUATIONS:
        raise ValueError(f"invalid situation: {result['situation']!r}")
    if result["wake_reason"] not in WAKE_REASONS:
        raise ValueError(f"invalid wake_reason: {result['wake_reason']!r}")
    for key in ("wake_score", "confidence"):
        value = float(result[key])
        if not 0 <= value <= 1:
            raise ValueError(f"{key} outside 0..1: {value}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", action="append", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--requests", type=int, default=3)
    parser.add_argument("--resize-width", type=int, default=512)
    parser.add_argument("--endpoint", default="http://127.0.0.1:11434/api/chat")
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args()
    if args.requests < 1:
        parser.error("--requests must be positive")

    image_path = Path(args.image)
    image_digest = hashlib.sha256(image_path.read_bytes()).hexdigest()
    with Image.open(image_path) as source:
        source_size = source.size
        scale = min(1, args.resize_width / source.width)
        transport_size = (round(source.width * scale), round(source.height * scale))
        image = source.convert("RGB").resize(transport_size, Image.Resampling.LANCZOS)
        buffer = io.BytesIO()
        image.save(buffer, format="JPEG", quality=85)
    encoded_image = base64.b64encode(buffer.getvalue()).decode("ascii")

    prompt = (
        "You are SOMA L1's bounded local visual helper evaluator. "
        "Describe only visible evidence. Do not identify people or infer private traits. "
        "Return only one JSON object with exactly these keys: summary, situation, wake_reason, "
        "wake_score, confidence. Do not use markdown. summary is at most 120 characters. "
        "Return the requested JSON. situation must be one of " + "|".join(SITUATIONS) + ". "
        "wake_reason must be one of " + "|".join(WAKE_REASONS) + ". "
        "A quiet static background is ambient with wake_reason none and low wake_score."
    )
    schema = {
        "type": "object",
        "properties": {
            "summary": {"type": "string"},
            "situation": {"type": "string", "enum": SITUATIONS},
            "wake_reason": {"type": "string", "enum": WAKE_REASONS},
            "wake_score": {"type": "number", "minimum": 0, "maximum": 1},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        },
        "required": ["summary", "situation", "wake_reason", "wake_score", "confidence"],
    }

    comparisons: list[dict[str, Any]] = []
    for model in args.model:
        runs: list[dict[str, Any]] = []
        model_error: str | None = None
        for request_index in range(args.requests):
            payload = {
                "model": model,
                "messages": [{"role": "user", "content": prompt, "images": [encoded_image]}],
                "stream": False,
                "think": False,
                "format": schema,
                "keep_alive": "5m",
                "options": {"temperature": 0, "num_predict": 128},
            }
            started = time.perf_counter()
            try:
                response = post_json(args.endpoint, payload, args.timeout)
                wall_ms = (time.perf_counter() - started) * 1_000
                result = parse_content(response)
                validate_result(result)
                runs.append({
                    "request": request_index + 1,
                    "wall_ms": wall_ms,
                    "total_ms": duration_ms(response, "total_duration"),
                    "load_ms": duration_ms(response, "load_duration"),
                    "prompt_eval_ms": duration_ms(response, "prompt_eval_duration"),
                    "generation_ms": duration_ms(response, "eval_duration"),
                    "prompt_tokens": response.get("prompt_eval_count", 0),
                    "generation_tokens": response.get("eval_count", 0),
                    "result": result,
                })
            except Exception as error:  # preserve capability failures in the comparison
                model_error = f"{type(error).__name__}: {error}"
                break
        warm = [float(run["wall_ms"]) for run in runs[1:]]
        comparisons.append({
            "model": model,
            "status": "passed" if len(runs) == args.requests else "failed",
            "error": model_error,
            "requests_completed": len(runs),
            "cold_wall_ms": runs[0]["wall_ms"] if runs else None,
            "warm_wall_ms": warm,
            "warm_wall_median_ms": statistics.median(warm) if warm else None,
            "runs": runs,
        })

    print(json.dumps({
        "schema_version": 1,
        "endpoint": args.endpoint,
        "image_sha256": image_digest,
        "source_image_size": source_size,
        "transport_image_size": transport_size,
        "image_contains_person": False,
        "requests_per_model": args.requests,
        "comparisons": comparisons,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
