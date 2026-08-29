# Reproducible setup

SOMA separates dependencies into four classes so a clean checkout never
silently relies on files from the development Mac.

| Class | Source of truth | Installation |
| --- | --- | --- |
| Host build tools | `Brewfile`, `Package.swift` | Homebrew Bundle and Xcode command-line tools |
| Bundled Core ML models | Git plus hashes in `config/bundled-models.sha256` | Present after clone; verified by `soma-doctor` |
| Proprietary OBSBOT SDK | Version and hashes in `config/soma-dependencies.env` | Obtain separately, then stage with `bootstrap-soma.zsh` |
| Runtime services/assets | `.env`, `MODELS.md`, optional Python lock | Ollama, Codex, ArcFace, and optional MLX-VLM setup |

## Supported host

- Apple Silicon Mac
- macOS 13 or newer for the Swift package
- macOS 26 or newer for the full runtime installed by `Brewfile` (current
  Homebrew OpenCV 5 bottle deployment target)
- Swift 6.0 or newer from Xcode command-line tools
- OpenCV 5 and CMake 3.16 or newer

`config/soma-dependencies.env` is the machine-readable compatibility contract.
It pins the externally supplied SDK and model artifacts by SHA-256 and records
the known-good runtime versions. `scripts/soma-doctor.zsh` enforces it.

Homebrew formulae and casks are compatibility-gated rather than byte-pinned:
a new Mac receives the current CMake, OpenCV 5, and Ollama releases, while an
existing Mac is not upgraded by bootstrap. The doctor then enforces minimums,
OpenCV major and deployment-target compatibility, followed by the project
build/tests. Proprietary SDKs, bundled models, Python environments, and local
model checkpoints are the byte-pinned portion of this contract.

The source package's macOS 13 deployment target is not a claim that every
current Homebrew runtime dependency is available there. The bootstrap enforces
the stricter full-runtime minimum, and the doctor reads the installed OpenCV
dylib's deployment target so it cannot approve an unloadable local build.

## Clean-Mac installation

Install Xcode command-line tools and Homebrew first, create the local signing
identity described below, obtain the SDK through the
[official OBSBOT application](https://www.obsbot.com/sdk), place the archive in
`~/Downloads`, then run:

```sh
xcode-select --install
git clone https://github.com/codeshark94/SOMA.git
cd SOMA

scripts/setup-soma.zsh --enable-motion
```

The setup command is safe to rerun. It discovers the exact supported SDK
archive, invokes the existing locked bootstrap, starts Ollama and provisions
the L1 model when absent, runs the tests and runtime doctor, installs the signed
app, and verifies that the process remains active. Use `--plan` for a read-only
preview, `--sdk-archive` for a different archive location, or `--with-l05` for
the optional local semantic helper. `--enable-motion` enables the checked-in
device-profile calibration registry; the runtime then selects the matching
Tiny 2 Lite or Tiny 3 Lite profile after SDK device detection and establishes
the session-specific attitude origin from live gimbal feedback.

The SDK is not published in this public repository or its release assets. The
vendor-supplied archive contains no public redistribution grant and the official
delivery flow is tied to an approved OBSBOT account. If the archive is missing,
the setup command opens the official application page instead of fetching an
unverified third-party copy.

The supported SDK archive has SHA-256
`8f938156575280d966f27395fa9f5d7f132e2bdb69c714843f5fbfb524688792`.
The bootstrap script rejects any other archive and will not overwrite a
different SDK already staged under `Reference/SDK`. After verifying the exact
library hash and Developer ID signature, it removes Safari's quarantine marker
from that dylib; otherwise macOS rejects it at process launch even though the
native helper compiles successfully.

Start Ollama and provision the default L1 model:

```sh
open -a Ollama
ollama pull gemma4:31b-cloud
```

The cloud model may require the operator to sign in to Ollama. Set
`OLLAMA_API_KEY` only if hosted web search/fetch is desired; it is not stored in
Git. L2 Live Voice additionally requires the Codex app, a signed-in account,
and the `realtime_conversation` App Server capability. Set
`SOMA_ENABLE_L2_LIVE_VOICE=0` when that component is intentionally absent.

Before the first local app installation, create a machine-local code-signing
certificate in Keychain Access using Certificate Assistant > Create a
Certificate. Set its name to `SOMA Local Persistent Code Signing`, its identity
type to Self Signed Root, and its certificate type to Code Signing. The private
key stays in that Mac's login keychain. The doctor and installer require this
usable persistent identity and never fall back to ad-hoc signing, so macOS TCC
permissions remain attached to a stable installed application identity across
rebuilds.

For debugging an individual setup stage, the lower-level commands remain
available:

```sh
scripts/soma-doctor.zsh --build
swift build
swift test
scripts/soma-doctor.zsh --runtime
```

Only after all blocking checks pass, install the local app and LaunchAgents:

```sh
scripts/install-soma-subconscious-app.zsh
scripts/soma.zsh status
```

The installer rebuilds from source, signs the local bundle, writes two
LaunchAgents, and starts or restarts SOMA. Camera, Microphone, Speech
Recognition, and Accessibility permissions remain explicit per-Mac user
actions and cannot be made portable through the repository.

## Optional L0.5 MLX-VLM

The optional helper is off by default. To reproduce its known-good Python
environment, including the pinned pip and full transitive package set:

```sh
scripts/bootstrap-soma.zsh --with-l05
```

This locked MLX 0.32 environment requires macOS 26 or newer; the published
Apple Silicon wheels themselves carry that deployment target. Only the Swift
package without the current Homebrew runtime retains the macOS 13 minimum.

Then obtain `mlx-community/gemma-4-e2b-it-4bit` revision
`238767527555cb75a05732a84dff5d6ba0dd6809` after accepting its terms, place it
at `~/Library/Application Support/SOMA/models/gemma-4-e2b-it-4bit`, and enable
`SOMA_ENABLE_L05_VLM=1`. The locked `model.safetensors` SHA-256 is
`038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e`;
`config/l05-model.sha256` verifies the complete runtime checkpoint manifest,
including tokenizer, processor, generation, and chat-template files.

## Optional face identity

ArcFace weights are not redistributable as a general product dependency. For
the research-only identity path, run:

```sh
brew install python@3.12
scripts/install-soma-face-identity-model.zsh
```

That installer requires Python 3.12 and full Xcode 26.6 build 17F113 selected
with `xcode-select`, installs the full
conversion dependency lock from `requirements-arcface.lock.txt`, verifies the
source download and all compiled model files, and installs the result with
owner-only permissions. See `MODELS.md` for licensing and provenance.

## Overrides

Use these only for deliberate nonstandard locations:

- `SOMA_OPENCV_PREFIX`
- `SOMA_CMAKE`
- `SOMA_OBSBOT_SDK_ROOT`
- `SOMA_CODEX_BINARY`
- `SOMA_CODESIGN_IDENTITY`
- `SOMA_ARCFACE_PYTHON`
- `SOMA_ENV_FILE` for doctor-only configuration validation

The repository has no remote SwiftPM dependencies, so there is no
`Package.resolved`. Python dependencies for the optional MLX helper and
ArcFace conversion are pinned in `requirements-l05.lock.txt` and
`requirements-arcface.lock.txt`.
