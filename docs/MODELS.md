# Models Oriel uses

Two brains, both open, both yours.

## Profiles

Settings, Assistant, Models offers two ready-made sets, downloaded through Ollama only when
one is chosen, and Custom for anything else.

| Profile | Memory | Planner (plans, reads answers) | Executor (navigates) | Eyes | Download |
|---|---|---|---|---|---|
| Lite | 16 GB | Qwen3.5 4B | Apple on-device, else Qwen3.5 4B | Qwen3.5 4B | 3.3 GB |
| Standard | 32 GB | Qwen3.5 9B | Apple on-device, else Qwen3.5 4B | Qwen3.5 4B | 9.9 GB |

Both navigate with the same small, fast models, so clicks and typing are equally quick;
Standard spends its memory on the planner. The profile that suits the Mac's memory is marked
recommended, and settings that already match a profile show as that profile.

| Role | What it does | Default model | License | Where it runs |
|---|---|---|---|---|
| Planner (the prefrontal cortex) | Turns your instruction into small, screen-verifiable sub-tasks; pre-scripts the certain steps as direct actions; revises when the executor is stuck. Sees text only, never pixels. | Apple on-device (macOS 26), else Qwen3.5 9B (or any larger local model, or your own frontier key) | Apache-2.0 | Ollama on the Mac or your network, an OpenAI-compatible server, or Anthropic with your key |
| Executor (the cerebellum) | Reads the screen on the Mac and carries out each sub-task click by click; reports back only at sub-task boundaries or when stuck. | Apple on-device (macOS 26), else Qwen3.5 4B | Apache-2.0 | On the Mac (or your network) |
| Executor's eyes | A vision model used only when the text picture of the screen isn't enough, or when the executor asks to look. | Qwen3.5 9B (multimodal) or the built-in Qwen3-VL 4B | Apache-2.0 | On the Mac (or your network) |

On macOS 26 with Apple Intelligence, both brains default to Apple's on-device foundation
model: nothing to download, nothing on the network, loaded and unloaded by the system, text
only with a 4,096-token window. The executor's eyes stay a vision model (Qwen2.5-VL on
Ollama or the built-in Qwen3-VL). Pick Qwen3 8B, a larger local model, or your own frontier
key for the planner when a task needs more room than the window gives.

The screen is rebuilt as text before any model sees it:

| Tier | What | Implementation | License |
|---|---|---|---|
| Controls | The frontmost app's accessibility tree: roles, labels, positions, enabled state. Secure fields are dropped, and values are never read. | Apple Accessibility API | System framework |
| Text | On-device OCR with positions. Lines that look like codes, card numbers or secrets are redacted. | Apple Vision text recognition | System framework |
| Shapes | Contour-detected regions for apps that expose no accessibility tree. | Apple Vision contours | System framework |
| Pixels | A downscaled JPEG, only for the vision model, only where the sharing policy allows. | Core Image | System framework |

Rules the code enforces (see `ScreenshotSharingPolicy`, `AgentApprovalPolicy` and their tests):

- A model on this Mac or on the user's own network may receive screenshots. A model on the internet receives text only, unless the user switches "Share screenshots with an executor on the internet" on in Settings and allows it on the phone for that run.
- The planner never receives pixels, wherever it runs.
- Models load when the phone connects and stay loaded while it is connected (Ollama `keep_alive`, at most ten idle minutes), so no run waits for them; they are released when the phone disconnects. Nothing stays loaded while no phone is connected.
- Protected surfaces (passwords, one-time codes, payments, security dialogs, CAPTCHA, destructive and public actions, medical-record signing) are refused or routed to the owner before any input reaches the Mac.

## Licenses of the defaults

- Qwen3.5 4B and 9B: Apache-2.0 (Alibaba Cloud). Commercial use permitted. The 9B takes images, so one model can plan and see.
- Qwen3 4B and 8B, Qwen3-VL 4B (built-in engine): Apache-2.0.
- Qwen2.5-VL 7B: Apache-2.0; still works as the eyes. The 3B variant is under the Qwen Research License (non-commercial) and is not a default.
- Apple on-device model: part of macOS 26 (Apple Intelligence); no weights to distribute.
- Ajax (PewDiePie's Qwen3.5-9B fine-tune): not adoptable as of 2026-10-02, with no public weights, model card, benchmarks or weights license. Revisit when those ship; its base model is already a default here.
- Qwen3-VL 2B/4B: Apache-2.0.
- Ollama (runtime): MIT. MLX and mlx-swift-lm (built-in engine, planned): MIT.
- Apple frameworks are used under Apple's developer agreements and are not redistributed.

Ultralytics code or weights, GPL/AGPL code, and model weights without a clear license stay out of the shipped product (see THIRD_PARTY_NOTICES.md).
