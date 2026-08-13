# Labelled VAD evaluation

`soma-vad-eval` reads labelled WAV clips without retaining them. It can score
the legacy RMS gate (`--engine rms`) or the bundled Core ML Silero VAD now used
by `soma-subconscious` (`--engine coreml`).

The manifest is a JSON array. Paths may be relative to the manifest:

```json
[
  {"id":"speech-01","path":"speech-01.wav","label":"speech"},
  {"id":"noise-01","path":"noise-01.wav","label":"noise"}
]
```

Run:

```sh
swift run soma-vad-eval --manifest /absolute/path/to/labelled-audio.json --engine coreml
swift run soma-vad-eval --manifest /absolute/path/to/labelled-audio.json --engine rms
```

The RMS report scores fixed 16 ms PCM blocks and includes its intentional 96 ms
onset confirmation. The Core ML report first downmixes and resamples each clip
in memory to 16 kHz, then scores non-overlapping 260 ms model windows. It
reports precision, recall, F1, and accuracy at the selected engine's unit; do
not compare their raw counts or F1 as though they used the same denominator.
Neither report claims speaker detection, transcription, or field performance.

The first local smoke baseline is deliberately not committed with raw audio:
four Free Spoken Digit Dataset utterances and two manually labelled non-speech
ESC-50 clips were fetched only into ignored `artifacts/vad-evaluation/data`.
The exact clip URLs and labels are in
[`vad-smoke-manifest.json`](vad-smoke-manifest.json); download them beside a
`data/` directory before running the manifest. The evaluator ignores the
provenance-only `source_url` fields.
The small smoke corpus produces RMS F1 0.619 (73 TP, 40 FP, 50 FN, 586 TN over
16 ms blocks) and Core ML F1 1.0 (5 TP, 0 FP, 0 FN, 38 TN over 260 ms windows).
The latter is only 43 coarse windows from six public clips; it is a loading and
smoke result, not evidence that the model is ready for live handoff.

Use a consented, deployment-matched corpus before accepting the fixed 0.50
threshold. The FSDD release is a small spoken-digit corpus, while ESC-50 is a
manually extracted environmental-audio corpus; preserve each source's license
and attribution when recreating or extending the corpus.

The gate itself is language-neutral, but its operating quality is not assumed
to be. A deployment corpus must label language or locale where known and report
results by language and acoustic condition; Korean must not become an implicit
default. Language identification, ASR, speaker identity, rapport, and personal
memory are future L1 concerns and are intentionally outside this evaluator.
