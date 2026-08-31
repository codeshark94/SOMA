#!/usr/bin/env python3
"""Persistent local-only Gemma 4 MLX-VLM JSONL helper for SOMA L1."""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
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


def verify_pinned_checkpoint(model_path: str) -> None:
    model_root = Path(model_path).resolve(strict=True)
    manifest_path = Path(__file__).resolve().parent.parent / "config" / "l05-model.sha256"
    if model_root.name != "gemma-4-e2b-it-4bit" or not manifest_path.is_file():
        raise ValueError("only the pinned E2B checkpoint is supported")
    entries = []
    for line in manifest_path.read_text(encoding="utf-8").splitlines():
        digest, relative_path = line.split(maxsplit=1)
        relative_path = relative_path.strip()
        candidate = (model_root / relative_path).resolve(strict=True)
        if model_root not in candidate.parents or not candidate.is_file():
            raise ValueError("invalid E2B checkpoint manifest path")
        entries.append((digest.lower(), candidate))
    if not entries:
        raise ValueError("empty E2B checkpoint manifest")
    for expected_digest, candidate in entries:
        actual = hashlib.sha256()
        with candidate.open("rb") as handle:
            for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
                actual.update(chunk)
        if actual.hexdigest() != expected_digest:
            raise ValueError(f"E2B checkpoint hash mismatch: {candidate.name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    model_slug = os.path.basename(os.path.normpath(args.model)).lower()
    if model_slug != "gemma-4-e2b-it-4bit":
        emit({"type": "error", "message": "startup: only the pinned E2B checkpoint is supported"})
        return 64
    try:
        verify_pinned_checkpoint(args.model)
    except (OSError, ValueError) as error:
        emit({"type": "error", "message": f"startup: {error}"[:500]})
        return 64
    source_name = "gemma4_e2b_mlx_vlm"

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
            request_type = request.get("type")
            if request_type == "shutdown":
                return 0
            if request_type != "infer":
                raise ValueError("unsupported request type")
            request_id = int(request["requestID"])
            context = request["context"]
            capture_ns = int(context["captureNS"])
            image_bytes = base64.b64decode(request["imageJPEGBase64"], validate=True)
            image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
            context_text = json.dumps(context, ensure_ascii=False, separators=(",", ":"))
            instruction = (
                "You are SOMA L1's bounded local visual interpretation helper. "
                "Describe only currently visible evidence. Do not identify a person, infer private traits, "
                "or issue motor commands. Return exactly one JSON object with keys: "
                "summary (max 120 characters), novelty (0..1), social_presence (0..1), "
                "attention_hint (person|object|sound_source|explore|none), "
                "situation (social_bid|object_presentation|scene_transition|ambient|uncertain), "
                "wake_reason (direct_social_bid|presented_object|unexpected_change|ambiguity|none), "
                "wake_score (0..1), confidence (0..1), "
                "eye_contact (0..1), engagement (0..1), "
                "body_language (open|closed|turned_away|leaning_in|none), "
                "gesture (waving|pointing|nodding|none), "
                "approach (approaching|stationary|leaving|none), "
                "reaction (engage|orient|observe|none), "
                "conversation_value (0..1), object_label (a short noun naming the most prominent "
                "object, or empty string if there is no notable object). "
                "Every textual value, including every enum value, must be enclosed in JSON double quotes. "
                "Fast sensor context is an unverified prior, not visual evidence; it can incorrectly say "
                "that a face or person is present, so never repeat it unless the image itself supports it. "
                "Use attention_hint=person whenever any human, face, or body is visible; use object only "
                "when no human is visible. social_presence is the probability that a human is visible. "
                "A figurine, doll, mannequin, statue, toy, poster, painting, photograph, reflection, "
                "screen image, video, or human-shaped artwork is not a human. Treat an uncertain "
                "human-like static representation as non-person rather than person. "
                "A quiet static background is ambient with wake_reason=none and low wake_score. "
                "A social bid requires visible evidence that a person is addressing the camera; merely "
                "being visible is not enough. "
                "object_presentation is a social event, not a synonym for seeing an object. Use it only "
                "when a visible person is deliberately holding, moving, or pointing a specific object "
                "toward the camera for SOMA to inspect; then use wake_reason=presented_object, "
                "reaction=engage, and provide object_label. A person merely looking at, carrying, or "
                "using a phone, laptop, book, tool, or other object is person_using_object context and "
                "must not be classified as object_presentation. A static object with no person is "
                "ambient or scene_transition and must not use wake_reason=presented_object. "
                "conversation_value rates how much this visible object or scene would fuel a conversation "
                "about the person's hobbies, tastes, or interests. Score high (>=0.7) for distinctive, "
                "discussable objects like collectibles, figurines, toys, model kits, gadgets, cameras, "
                "books, art, decorations, sports gear, or anything with a story to tell. Score low (<0.3) "
                "for bland everyday background like plain walls, floors, generic office supplies, or "
                "unremarkable furniture. Set object_label to a short noun for the most prominent object "
                "(e.g. figurine, bicycle, guitar, camera, book) or empty when there is no notable object. "
                "When a human is visible, also judge: eye_contact is the probability the person is looking "
                "at the camera; engagement is how available/attentive they are (low if busy, on a phone, "
                "or turned away); body_language describes their posture; gesture is any clear hand/head "
                "gesture (waving, pointing, nodding) else none; approach is whether they are moving toward "
                "or away from the camera. reaction is the proportional response SOMA should take: "
                "engage when a person is socially addressing the camera (waving, approaching, eye contact, "
                "a social bid); orient when a non-person object or scene change deserves attention; "
                "observe for a mild ambient change; none for a quiet static scene. "
                "When no human is visible, set eye_contact=0, engagement=0, body_language=none, "
                "gesture=none, approach=none. Do not use markdown. "
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
                    max_tokens=192,
                    temperature=0.0,
                    enable_thinking=False,
                    verbose=False,
                )
            inference_ms = (time.perf_counter() - started) * 1_000
            text = getattr(generated, "text", generated)
            try:
                parsed = parse_object(str(text))
            except ValueError as error:
                emit({
                    "type": "error",
                    "message": str(error),
                    "modelOutput": str(text)[:500],
                    "inferenceMS": inference_ms,
                })
                continue
            hint = str(parsed.get("attention_hint", "none"))
            if hint not in {"person", "object", "sound_source", "explore", "none"}:
                hint = "none"
            situation = str(parsed.get("situation", "uncertain"))
            if situation not in {"social_bid", "object_presentation", "scene_transition", "ambient", "uncertain"}:
                situation = "uncertain"
            wake_reason = str(parsed.get("wake_reason", "none"))
            if wake_reason not in {"direct_social_bid", "presented_object", "unexpected_change", "ambiguity", "none"}:
                wake_reason = "none"
            body_language = str(parsed.get("body_language", "none"))
            if body_language not in {"open", "closed", "turned_away", "leaning_in", "none"}:
                body_language = "none"
            gesture = str(parsed.get("gesture", "none"))
            if gesture not in {"waving", "pointing", "nodding", "none"}:
                gesture = "none"
            approach = str(parsed.get("approach", "none"))
            if approach not in {"approaching", "stationary", "leaving", "none"}:
                approach = "none"
            reaction = str(parsed.get("reaction", "none"))
            if reaction not in {"engage", "orient", "observe", "none"}:
                reaction = "none"
            emit({
                "type": "result",
                "requestID": request_id,
                "captureNS": capture_ns,
                "source": source_name,
                "model": model_slug,
                "summary": str(parsed.get("summary", ""))[:160],
                "novelty": bounded_probability(parsed.get("novelty")),
                "socialPresence": bounded_probability(parsed.get("social_presence")),
                "attentionHint": hint,
                "situation": situation,
                "wakeReason": wake_reason,
                "wakeScore": bounded_probability(parsed.get("wake_score")),
                "confidence": bounded_probability(parsed.get("confidence")),
                "eyeContact": bounded_probability(parsed.get("eye_contact")),
                "engagement": bounded_probability(parsed.get("engagement")),
                "bodyLanguage": body_language,
                "gesture": gesture,
                "approach": approach,
                "reaction": reaction,
                "conversationValue": bounded_probability(parsed.get("conversation_value")),
                "objectLabel": str(parsed.get("object_label", ""))[:60],
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
