# Third-Party Notices

The iOS app has no third-party dependencies; its voice input records with Apple frameworks and leaves the speech model to the Mac. The Mac companion links the built-in assistant engine and the voice input engine listed below; neither app bundles model weights, which are fetched by the user on first use under their own licenses.

| Mac companion component | Version | License | Notes |
|---|---|---|---|
| mlx-swift-lm (MLXLLM, MLXVLM, MLXLMCommon, MLXHuggingFace) | 3.32.3 | MIT | On-device inference for the built-in planner, executor and vision models. Preserve the MIT notice in the shipped bundle. |
| mlx-swift (MLX, MLXNN) | 0.32.3, the copy mlx-swift-lm resolves | MIT | Metal and CPU kernels, used directly by the voice input engine too. Preserve the MIT notice. |
| Whisper on MLX (`Apps/HermesCaptureMac/Speech/Whisper/`) | ported from mlx-whisper 0.4.3 | MIT | A Swift port of Apple's mlx-examples Whisper (Copyright 2023 Apple Inc.), itself derived from OpenAI's Whisper (Copyright 2022 OpenAI). Preserve both MIT notices. |
| Whisper large-v3 weights (downloaded on first use) | `mlx-community/whisper-large-v3-mlx`, fp16 | MIT | Voice input's speech model, the one Hermes uses. Not redistributed by Oriel; the Mac downloads it from Hugging Face, or reuses a complete copy already in the user's Hugging Face cache. |
| Whisper tokenizer vocabulary (`vocab.json`, downloaded on first use) | `openai/whisper-large-v3` | Apache-2.0 (per its model card) | Read by the Swift tokenizer; not redistributed by Oriel. |
| swift-huggingface | 0.9.x | Apache-2.0 | Fetches model weights into Oriel's own folder. Preserve the Apache notice. |
| swift-transformers (Tokenizers) | 1.3.x | Apache-2.0 | Tokenizers for the built-in models. Preserve the Apache notice. |
| Qwen3 4B / 8B, Qwen3-VL 4B (weights, downloaded on first use) | mlx-community 4-bit conversions | Apache-2.0 | Not redistributed by Oriel; the user downloads them from Hugging Face. Qwen2.5-VL 3B is under a research-only license and is not offered. |

The Oriel app targets otherwise use Apple platform frameworks and local HermesCapture modules only. The optional relay service has the direct runtime dependencies below. The generated source SBOM at `artifacts/HermesCapture.spdx.json` inventories source files and these declared direct dependencies; regenerate it with `python3 scripts/generate_sbom.py` before each release candidate.

| Shipped component | Declared version | License | Release requirement |
|---|---|---|---|
| Python runtime / official `python:3.12-slim` container base | 3.12-slim | Python is PSF-2.0; container OS packages have their own licenses | Pin the image by digest and generate a resolved image SBOM and notice set before deployment. |
| cryptography | `>=42,<47` | Apache-2.0 OR BSD-3-Clause | Preserve upstream notices and scan the resolved release version. |
| websockets | `>=14,<16` | BSD-3-Clause | Preserve upstream notices and scan the resolved release version. |

The repository-level SPDX document records declared ranges, not a claim that all transitive packages are resolved. A deployed relay image is blocked until its exact Python, wheel, and OS package versions are captured by an image-level SBOM and reviewed for licenses and vulnerabilities.

Additional components considered for later phases must pass license and provenance review before they are added:

| Component | Expected license | Release requirement |
|---|---|---|
| Hermes Agent compatibility code | MIT | Preserve copyright and license notice for copied substantial portions. |
| OpenCV | Apache-2.0 | Preserve notices and document bundled modules. |
| WebRTC | BSD-3-Clause plus transitive notices | Generate and ship the complete upstream third-party notice set. |
| MCP SDK | MIT | Preserve copyright and license notice if distributed. |

Ultralytics code and Ultralytics-provided model weights are prohibited from the closed-source consumer build unless 67 Enterprise obtains a separate commercial license. GPL, AGPL, unverified model weights, and datasets without documented commercial rights are release blockers.

Apple platform frameworks are provided under Apple's developer agreements rather than open-source licenses and are not redistributed by this repository.
