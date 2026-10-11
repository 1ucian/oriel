# Legacy LCU Frame Compatibility

Oriel's native Mac app replaces the Python `hermescap.py` stream helper while preserving the existing LCU filesystem contract. The native bridge starts once with the app, owns the cache through an atomic PID claim, and holds one ScreenCaptureKit stream under Oriel's stable bundle identity.

The bridges in this document are compiled only into builds made with the `ORIEL_LOCAL_BRIDGES` Swift compilation condition: Debug builds, or a Release build made with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=ORIEL_LOCAL_BRIDGES`. The notarized download leaves them out, so the preferences below do nothing there, and the Developer ID release script refuses a build that has them: any process running as the user can write a preference.

The bridge is off unless the owner turns it on: any process running as the user can read the screen through these files, under Oriel's Screen Recording permission. Turn it on only for a local tool you trust, then restart Oriel:

```text
defaults write com.67enterprise.oriel.mac localCaptureBridge.enabled -bool true
```

## Live compatibility directory

```text
~/.hermes/cache/oriel/
├── pid
├── frame.raw
├── raw
├── fps
├── req
└── latest.png
```

- `pid` identifies the current cache owner. Oriel refuses startup when another live process owns it and replaces only stale ownership.
- `raw` enables raw-frame publishing while its modification time is less than three seconds old.
- `fps` requests an exact clamped rate from 5 through 60 FPS while fresh; the bridge returns to 5 FPS after three seconds.
- `req` requests a PNG of the latest retained frame. The bridge writes `latest.png` atomically and keeps an unserved request pending until a frame exists.

## Wire format

`LegacySharedFrameWriter` writes a fixed 64-byte little-endian header followed by the complete BGRA pixel plane:

| Offset | Type | Meaning |
|---:|---|---|
| 0 | `UInt32` | Magic `0x48524331` (`HRC1`) |
| 4 | `UInt64` | Monotonic frame sequence |
| 12 | `UInt32` | Pixel width |
| 16 | `UInt32` | Pixel height |
| 20 | `UInt32` | Bytes per row |
| 24–63 | bytes | Reserved, zero-filled |
| 64+ | bytes | BGRA rows including row padding |

Pixels are synchronized before the sequence-bearing header is published. Consumers should still read the sequence before and after copying a frame and retry if it changed.

## Resource and lifecycle rules

- Raw pixel writes are disabled unless a live LCU consumer refreshes `raw`.
- PNG encoding happens only after `req` changes.
- Oriel performs no automatic capture retry loop after a TCC denial, preventing stacked permission prompts.
- Partial startup stops any opened stream and releases only Oriel's own PID claim.
- Normal app termination waits for bridge shutdown before allowing AppKit to exit.
- The Python LaunchAgent must remain loaded until the installed Oriel build has produced a valid HRC1 frame and a fresh `latest.png` through the live LCU reader. It can then be disabled, not deleted, for rollback.

## Local goal bridge

A local tool can also hand Oriel's assistant one goal and read back its trace and answer, with no paired phone. The goal bridge is off unless the owner turns it on, because any process running as the user can then drive the Mac through the assistant. It starts only once the capture bridge above is running, and it shares that bridge's cache. Turn it on, then restart Oriel:

```text
defaults write com.67enterprise.oriel.mac localAssistantBridge.enabled -bool true
```

```text
~/.hermes/cache/oriel/assistant/   (mode 0700)
├── goal.json     written by the tool: write a temporary file, then rename it
├── cancel        written by the tool: the id of the run to stop
├── trace.jsonl   written by Oriel: one line per trace event, restarted for each run
└── result.json   written by Oriel, atomically
```

- `goal.json` holds `{"id": string, "instruction": string, "app": string?, "maxSteps": 1-30, "typeAllowed": [string]?, "readOnly": bool?}`.
  - `maxSteps` is required.
  - `app` is the app the run is confined to, for example `"Citrix Viewer"`.
  - `typeAllowed` lists the exact texts the run may type.
  - `readOnly` (default false) makes the run observe and answer only: any click, typing, key, scroll or app switch ends it as `blocked` with `why` = `read-only run`, and the planner is told to answer from what is on screen now.
- Oriel checks for a goal every 50 ms. A goal with an id it has not run before starts a run, unless a run is already in progress, from this bridge or from the phone. In that case the result for the new goal is `busy`; write the goal again with a new id later.
- A goal that was already in the folder when Oriel started is not run.
- The run uses the same assistant runtime and the same model settings as a phone run. Screenshots are not shared with the model.
- Each line of `trace.jsonl` is `{"t": ISO time, "kind": trace kind, "text": summary}`. Typed text is kept by length only, as in the activity log.
- `result.json` is `{"id", "status", "answer"?, "steps", "elapsedMs", "why"?}`. `id` is null when `goal.json` could not be read.
- The run's start and end are written to the activity log.
- A `cancel` file naming the active run stops it, and Oriel removes the file. A run that is still going after ten minutes stops as `timeout`.

| Status | Meaning |
|---|---|
| `done` | The goal was met; `answer` holds the result. |
| `failed` | The run ended without meeting the goal, for example at the step limit, after a question, or with `why` = `executor model unreachable`. |
| `cancelled` | Stopped by `cancel`, or because Oriel quit. |
| `needs_approval` | A step needed approval. |
| `blocked` | A step was refused. |
| `timeout` | Stopped after ten minutes. |
| `busy` | Another run was in progress. |
| `invalid` | The goal could not be read or failed validation. |

Nobody is there to approve or answer, so a local run follows stricter rules than a phone run. The runtime checks every step against these rules after the shared policy, right before acting:

- A step the policy routes to approval ends the run as `needs_approval`, and nothing is sent. A step the policy blocks ends the run as `blocked`.
- Clicks go only to a listed control or OCR text line whose label is known, so the policy's sign, attest and password rules always see a label. A screen point, an unknown id or a shape region is refused.
- The run types only texts that are exactly in `typeAllowed`.
- `openApplication` is allowed only for the goal's `app`.
- With `app` set, every click, key, typing or scroll checks the frontmost app first. The run stops if another app is in front.
- Oriel's own windows stay off limits.
- A question from the planner or the executor ends the run as `failed`.
- If the executor's model fails twice in a row, the run ends as `executor model unreachable`.
- Input goes through the input broker's session check. The session is open only while the run is going. Nothing is sent once the run has ended or been told to stop.

## Local input bridge

The same local tool can also drive the Mac one input primitive at a time, through Oriel's own input pipeline, so Oriel's cursor is visible while the tool acts and the same pointer handling applies. It shares the goal bridge's folder and opt-in flag, and starts with it. These are plain input primitives, so no approval policy runs here; the tool is expected to refuse sign-like actions on its side.

```text
~/.hermes/cache/oriel/assistant/
├── input.json         written by the tool: write a temporary file, then rename it
└── input-result.json  written by Oriel, atomically
```

- `input.json` holds `{"id": string, "action": "click"|"doubleClick"|"rightClick"|"key"|"type"|"scroll", "app": string, ...}`.
  - `app` is the app that must be frontmost; the request is refused if it is not.
  - `x`, `y` are screen points, for `click`, `doubleClick`, `rightClick` and `scroll`.
  - `chord` is for `key`: modifiers joined to a key with `+`, for example `"cmd+f"`, `"return"`, `"pagedown"`. Keys: `return enter tab esc escape space delete backspace left right down up home end pageup pagedown f1`–`f12`, letters and digits. Modifiers: `cmd`/`command`, `shift`, `option`/`alt`, `control`/`ctrl`, `fn`.
  - `text` is for `type`.
  - `lines` and `columns` are for `scroll`: positive `lines` scrolls down, positive `columns` scrolls the content right (later columns into view, for lists that run off-screen sideways). At least one is required; either may be `0`. Oriel sends `16` px of wheel per line or column.
- Oriel checks every 50 ms and runs one request at a time.
- `type` sends one key down and up per character with real virtual key codes and Shift for capitals and symbols (a Citrix lookup field ignores unicode-string key events); a character with no key code goes as a unicode event, and `\n` types Return. There are 12 ms between characters.
- The pointer shows on every move and stays visible until 1.5 s after the last action, so it is seen through a chain.
- `input-result.json` is `{"id", "status": "done"|"refused"|"failed"|"busy", "why"?, "ms"}`. `id` is null when `input.json` could not be read.
- One line per request is written to the activity log, with the action and status, never the typed text.

| Status | Meaning |
|---|---|
| `done` | The input was sent. |
| `refused` | The request was malformed, named an app that is not frontmost, was off the display, or targeted Oriel's own window. Nothing was sent. |
| `failed` | The input could not be posted. |
| `busy` | A goal run or another input request was in progress. |

## Verification

`LegacySharedFrameWriterTests` verifies the HRC1 bytes and pixel publication order. `LocalCaptureBridgeTests` verifies:

- atomic PID ownership and live-owner refusal;
- exact FPS forwarding and 5 FPS idle behavior;
- demand-gated raw publication;
- pending PNG requests;
- partial-start cleanup and owned-PID release.

`LocalAssistantBridgeTests` covers:

- goal validation, and the null id for an unreadable goal;
- `busy`, `cancel` and `timeout`;
- `needs_approval` with no input sent;
- refusals of point clicks, of typing outside `typeAllowed`, and of input while another app is in front;
- questions and an unreachable executor;
- a read-only goal blocking any action and still answering from the screen;
- typed text kept out of `trace.jsonl`;
- `result.json` replaced rather than rewritten in place;
- the bridge being off by default.

`LocalInputBridgeTests` covers:

- request validation, chord and keystroke mapping;
- malformed, wrong-frontmost-app, off-display and own-window refusals, each with nothing sent;
- a click reaching the broker at the right normalized point, typing as key strokes, a scroll's direction, and a key chord;
- `busy` while a goal run or another request is in progress;
- `input-result.json` replaced rather than rewritten in place;
- the pointer hidden after the idle timer.

Release rollout additionally requires a real installed-app TCC grant, a live LCU screenshot reporting `engine=hermescapture`, a raw-frame read with advancing sequence, and confirmation that Python is no longer running.
