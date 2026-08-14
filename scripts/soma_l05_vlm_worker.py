#!/usr/bin/env python3
"""Persistent local-only Gemma 4 MLX-VLM JSONL worker for SOMA L0.5."""

from __future__ import annotations

import argparse
import base64
import contextlib
import io
import json
import os
import sys
import time
from typing import Any


def emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def bounded_probability(value: Any) -> float:
    try:
        return min(1.0, max(0.0, float(value)))
    except (TypeError, ValueError):
        return 0.0


def parse_object(text: str) -> dict[str, Any]:
    decoder = json.JSONDecoder()
    for index, character in enumerate(text):
        if character != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise ValueError("model output did not contain a JSON object")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()

    try:
        with contextlib.redirect_stdout(sys.stderr):
            import mlx.core as mx
            from PIL import Image
            from mlx_vlm import generate, load
            from mlx_vlm.prompt_utils import apply_chat_template

            mx.set_memory_limit(8 * 1024 * 1024 * 1024)
            mx.set_cache_limit(256 * 1024 * 1024)
            load_started = time.perf_counter()
            model, processor = load(args.model)
            load_ms = (time.perf_counter() - load_started) * 1_000
    except Exception as error:  # startup must fail closed and explain why
        emit({"type": "error", "message": f"startup: {type(error).__name__}: {error}"[:500]})
        return 2

    emit({
        "type": "health",
        "state": "ready",
        "model": args.model,
        "loadMS": load_ms,
        "pid": os.getpid(),
        "memory_limit_bytes": 8 * 1024 * 1024 * 1024,
        "cache_limit_bytes": 256 * 1024 * 1024,
    })

    for line in sys.stdin:
        try:
            request = json.loads(line)
            if request.get("type") == "shutdown":
                return 0
            if request.get("type") != "infer":
                raise ValueError("unsupported request type")
            request_id = int(request["requestID"])
            context = request["context"]
            capture_ns = int(context["captureNS"])
            image_bytes = base64.b64decode(request["imageJPEGBase64"], validate=True)
            image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
            context_text = json.dumps(context, ensure_ascii=False, separators=(",", ":"))
            instruction = (
                "You are SOMA's low-rate preconscious visual interpretation layer. "
                "Describe only currently visible evidence. Do not identify a person, infer private traits, "
                "or issue motor commands. Return exactly one JSON object with keys: "
                "summary (max 120 characters), novelty (0..1), social_presence (0..1), "
                "attention_hint (person|object|sound_source|explore|none), "
                "situation (social_bid|object_presentation|scene_transition|ambient|uncertain), "
                "wake_reason (direct_social_bid|presented_object|unexpected_change|ambiguity|none), "
                "wake_score (0..1), confidence (0..1). "
                "Use attention_hint=person whenever any human, face, or body is visible; use object only "
                "when no human is visible. social_presence is the probability that a human is visible. "
                "A quiet static background is ambient with wake_reason=none and low wake_score. "
                "A social bid requires visible evidence that a person is addressing the camera; merely "
                "being visible is not enough. Do not use markdown. "
                f"Fast sensor context: {context_text}"
            )
            prompt = apply_chat_template(
                processor,
                model.config,
                instruction,
                num_images=1,
                chat_template_kwargs={"enable_thinking": False},
            )
            started = time.perf_counter()
            with contextlib.redirect_stdout(sys.stderr):
                generated = generate(
                    model=model,
                    processor=processor,
                    prompt=prompt,
                    image=[image],
                    max_tokens=128,
                    temperature=0.0,
                    enable_thinking=False,
                    verbose=False,
                )
            inference_ms = (time.perf_counter() - started) * 1_000
            text = getattr(generated, "text", generated)
            parsed = parse_object(str(text))
            hint = str(parsed.get("attention_hint", "none"))
            if hint not in {"person", "object", "sound_source", "explore", "none"}:
                hint = "none"
            situation = str(parsed.get("situation", "uncertain"))
            if situation not in {"social_bid", "object_presentation", "scene_transition", "ambient", "uncertain"}:
                situation = "uncertain"
            wake_reason = str(parsed.get("wake_reason", "none"))
            if wake_reason not in {"direct_social_bid", "presented_object", "unexpected_change", "ambiguity", "none"}:
                wake_reason = "none"
            emit({
                "type": "result",
                "requestID": request_id,
                "captureNS": capture_ns,
                "source": "gemma4_e4b_mlx_vlm",
                "summary": str(parsed.get("summary", ""))[:160],
                "novelty": bounded_probability(parsed.get("novelty")),
                "socialPresence": bounded_probability(parsed.get("social_presence")),
                "attentionHint": hint,
                "situation": situation,
                "wakeReason": wake_reason,
                "wakeScore": bounded_probability(parsed.get("wake_score")),
                "confidence": bounded_probability(parsed.get("confidence")),
                "inferenceMS": inference_ms,
                "promptTokens": getattr(generated, "prompt_tokens", 0),
                "generationTokens": getattr(generated, "generation_tokens", 0),
                "promptTPS": getattr(generated, "prompt_tps", 0),
                "generationTPS": getattr(generated, "generation_tps", 0),
                "peakMemoryGB": getattr(generated, "peak_memory", 0),
            })
        except Exception as error:
            emit({
                "type": "error",
                "message": f"{type(error).__name__}: {error}"[:500],
            })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
