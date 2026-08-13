# Labelled VAD evaluation

`soma-vad-eval` reads labelled WAV clips and evaluates the exact local
`VoiceActivityGate` used by `soma-subconscious`. It does not retain audio and
does not change the runtime gate.

The manifest is a JSON array. Paths may be relative to the manifest:

```json
[
  {"id":"speech-01","path":"speech-01.wav","label":"speech"},
  {"id":"noise-01","path":"noise-01.wav","label":"noise"}
]
```

Run:

```sh
swift run soma-vad-eval --manifest /absolute/path/to/labelled-audio.json
```

The report scores fixed 16 ms PCM blocks and includes the gate's intentional
96 ms onset confirmation. It reports block-level precision, recall, F1, and
accuracy; it is not a claim of speaker detection, speech transcription, or
field performance.

The first local smoke baseline is deliberately not committed with raw audio:
four Free Spoken Digit Dataset utterances and two manually labelled non-speech
ESC-50 clips were fetched only into ignored `artifacts/vad-evaluation/data`.
The exact clip URLs and labels are in
[`vad-smoke-manifest.json`](vad-smoke-manifest.json); download them beside a
`data/` directory before running the manifest. The evaluator ignores the
provenance-only `source_url` fields.
Use a consented, deployment-matched corpus before selecting an operating
threshold. The FSDD release is a small spoken-digit corpus, while ESC-50 is a
manually extracted environmental-audio corpus; preserve each source's license
and attribution when recreating or extending the corpus.
