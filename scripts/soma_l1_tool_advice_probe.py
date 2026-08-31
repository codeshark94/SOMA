#!/usr/bin/env python3
"""Verify SOMA's primary L1 model through Ollama native tool calling."""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.request


SYSTEM_PROMPT = (
    "You are SOMA's primary L1 tool-selection process. Never answer the participant. "
    "Select exactly one supplied function only when it is required for a grounded response. "
    "A status report requires get_activity_overview. The grounding_quote argument must be "
    "an exact substring of the participant transcript."
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="http://127.0.0.1:11434/api/chat")
    parser.add_argument("--model", default=os.environ.get("SOMA_L1_MODEL", "gemma4:31b-cloud"))
    parser.add_argument("--transcript", default="Status report.")
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()

    body = {
        "model": args.model,
        "stream": False,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": args.transcript},
        ],
        "tools": [{
            "type": "function",
            "function": {
                "name": "get_activity_overview",
                "description": "Return the robot's current activity and operating state.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "grounding_quote": {
                            "type": "string",
                            "description": "Exact substring of the participant transcript.",
                        }
                    },
                    "required": ["grounding_quote"],
                },
            },
        }],
        "options": {"temperature": 0, "num_predict": 96},
    }
    request = urllib.request.Request(
        args.endpoint,
        data=json.dumps(body, separators=(",", ":")).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    started = time.perf_counter()
    with urllib.request.urlopen(request, timeout=args.timeout) as response:
        result = json.load(response)
    wall_ms = (time.perf_counter() - started) * 1_000

    calls = result.get("message", {}).get("tool_calls", [])
    if len(calls) != 1:
        raise RuntimeError(f"expected one native tool call, received {len(calls)}")
    function = calls[0].get("function", {})
    if function.get("name") != "get_activity_overview":
        raise RuntimeError(f"unexpected tool: {function.get('name')}")
    arguments = function.get("arguments", {})
    if isinstance(arguments, str):
        arguments = json.loads(arguments)
    quote = " ".join(str(arguments.get("grounding_quote", "")).lower().split())
    transcript = " ".join(args.transcript.lower().split())
    if len(quote) < 2 or quote not in transcript:
        raise RuntimeError("native tool call returned an ungrounded quote")

    print(json.dumps({
        "backend": "primary_l1_31b",
        "protocol": "ollama_native_tool_calls",
        "model": result.get("model", args.model),
        "wall_ms": round(wall_ms, 2),
        "tool_call": calls[0],
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
