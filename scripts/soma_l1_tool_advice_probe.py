#!/usr/bin/env python3
"""Exercise the E2B tool-advice protocol without starting the camera runtime."""

from __future__ import annotations

import argparse
import json
import subprocess
import time
import uuid


def read_envelope(process: subprocess.Popen[str]) -> dict:
    assert process.stdout is not None
    line = process.stdout.readline()
    if line:
        return json.loads(line)
    assert process.stderr is not None
    diagnostic = process.stderr.read()[-1_000:]
    raise RuntimeError(f"worker exited with {process.poll()}: {diagnostic}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", required=True)
    parser.add_argument("--worker", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--transcript", default="지금 카메라에 뭐 보여?")
    args = parser.parse_args()

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

    cycle_id = str(uuid.uuid4())
    turn_id = str(uuid.uuid4())
    request = {
        "type": "tool_advice",
        "requestID": 1,
        "request": {
            "cycleID": cycle_id,
            "threadID": "e2b-probe",
            "turnID": turn_id,
            "observedAt": time.time(),
            "latestUserTranscript": args.transcript,
            "recentConversation": [],
            "availableTools": ["capture_view", "get_robot_body_state"],
            "toolsAlreadyCalled": [],
        },
    }
    started = time.perf_counter()
    process.stdin.write(json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n")
    process.stdin.flush()
    result = read_envelope(process)
    wall_ms = (time.perf_counter() - started) * 1_000
    if result.get("type") != "tool_advice_result" or result.get("requestID") != 1:
        raise RuntimeError(f"tool-advice inference failed: {result}")
    content = json.loads(result["content"])
    if str(content.get("cycle_id", "")).lower() != cycle_id:
        raise RuntimeError("cycle ID mismatch")
    if content.get("thread_id") != "e2b-probe":
        raise RuntimeError("thread ID mismatch")
    if str(content.get("turn_id", "")).lower() != turn_id:
        raise RuntimeError("turn ID mismatch")
    action = content.get("action")
    if not isinstance(content.get("confidence"), (int, float)):
        raise RuntimeError("confidence is missing")
    if not str(content.get("rationale", "")).strip():
        raise RuntimeError("rationale is missing")
    if action == "recommend_tool":
        if content.get("tool_name") not in request["request"]["availableTools"]:
            raise RuntimeError("worker recommended an unavailable tool")
        quote = " ".join(str(content.get("grounding_quote", "")).lower().split())
        transcript = " ".join(args.transcript.lower().split())
        if len(quote) < 2 or quote not in transcript:
            raise RuntimeError("worker returned an ungrounded quote")
    elif action == "no_assist":
        if content.get("tool_name") is not None or content.get("grounding_quote") is not None:
            raise RuntimeError("no_assist carried tool residue")
    else:
        raise RuntimeError(f"unsupported action: {action}")

    process.stdin.write('{"type":"shutdown"}\n')
    process.stdin.flush()
    process.wait(timeout=10)
    print(json.dumps({
        "backend": "e2b_shared_mlx",
        "worker_pid": ready.get("pid"),
        "worker_load_ms": ready.get("loadMS"),
        "inference_ms": result.get("inferenceMS"),
        "wall_ms": wall_ms,
        "advice": content,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
