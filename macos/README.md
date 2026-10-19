# GhostHand for macOS

A native macOS port of **[GhostHand](../../README.md)** — the AI desktop assistant — running
entirely against the **local Laya decision model** on this machine. Focus any app, press
**Control + Option**, and tell GhostHand what to do. It reads the app's accessibility tree,
asks Laya which action to take, performs it with native macOS input events, and verifies
the result.

This is a from-scratch Swift implementation that mirrors the Windows C# architecture. The
Windows source is untouched under `../windows/`, but the decision model is **Laya, not Jev**:
nothing is sent to the Vercel AI Gateway and no API key is required.

---

## Quick start

```bash
cd macos

# 1. Start the local Laya model (checkpoints already on disk — no downloads)
Scripts/start-laya.sh --device cpu          # serves http://127.0.0.1:8000

# 2. Build and run the unit tests
Scripts/test.sh

# 3. Verify permissions + Laya connectivity (auto-starts Laya if it is not running)
Scripts/build.sh
.build/scratch/x86_64-apple-macosx/debug/ghosthand check

# 4. Build the menu-bar app bundle and launch it
Scripts/make-app-bundle.sh -c release
open dist/GhostHand.app
```

GhostHand starts the Laya server itself if nothing is listening on `127.0.0.1:8000`
(`LAYA_AUTOSTART=true` by default). The model is local, so **no API key is needed**; an
optional `LAYA_API_KEY` bearer token can be stored in the Keychain if the server requires one.

### Grant permissions (required once)

macOS gates the APIs GhostHand needs. Open **System Settings → Privacy & Security** and enable:

| Permission | Why |
|---|---|
| **Accessibility** | Read the accessibility tree and post synthetic input; required for the global hotkey and automation. |
| **Microphone** *(optional)* | Voice commands. Prompts on first use. |
| **Speech Recognition** *(optional)* | On-device dictation. Prompts on first use. |

`ghosthand check` prints the current Accessibility state.

---

## Usage

1. Focus any app (Notes, Safari, Calculator, Music, …).
2. Press **Control + Option**.
3. The GhostHand overlay appears above the app.
4. Type (or dictate) an instruction, e.g.
   - *"Write a meeting agenda for tomorrow's sprint review"*
   - *"Open Safari and search for Adele"*
   - *"Play Honey Singh on YouTube"*
5. Press **Return** to submit.
6. **Kill switch:** press **Control + Option** again, press **Esc**, or quit from the menu bar.

---

## Laya integration

Laya is the offline decision model (`/Users/threaded/projects/Laya`). GhostHand talks to it
over its HTTP protocol instead of the hosted gateway:

* **Endpoint:** `POST http://127.0.0.1:8000/v1/systemone` (Laya also serves `GET /health`).
* **Question types:** Laya answers `choice`, `score` and `noul` (its yes/no type). Jev's
  `boolean` maps onto `noul`, whose answer is **the probability of yes** (`noul >= 0.5`).
* **Answer confidence:** the code prefers Laya's `answer_confidence` (probability mass on the
  reported answer — the quantity Jev called `confidence`) over Laya's entropy-based `confidence`.
* **Checkpoint selection:** `model` is left empty by default so Laya routes by language
  (`english` / `multilingual`). Set `LAYA_MODEL` to force one
  (`english`, `multilingual`, `typed-decisions`).
* **Token budgets:** the agent offers many candidate actions, so requests raise
  `head_max_len` to 2048 and `max_len` to 4096, and the next-action choice is capped at
  `LAYA_MAX_CHOICE_OPTIONS` (90) options — Laya refuses a choice with more than 100.
* **No network:** the launcher points Laya at the on-disk checkpoints and sets
  `HF_HUB_OFFLINE=1`; every cache stays inside the app-support directory.

`LayaServerManager` launches `Scripts/laya_serve.py` (copied into the `.app` on packaging) with a Python
that has Laya's serve extras (`fastapi`, `uvicorn`, `torch`) and waits for `/health` before the
first prompt. If Laya is already running it is used as-is.

### Configuration

All optional; see `.env.example`.

| Variable | Meaning | Default |
|---|---|---|
| `LAYA_BASE_URL` | server URL | `http://127.0.0.1:8000` |
| `LAYA_MODEL` | force a checkpoint (empty = route by language) | empty |
| `LAYA_API_KEY` | bearer token when the server sets `LAYA_API_KEY` | none |
| `LAYA_AUTOSTART` | start the server when it is not running | `true` |
| `LAYA_PYTHON` | Python with Laya's dependencies | auto-detect |
| `LAYA_HOME` | Laya checkout (package + `models/`) | `/Users/threaded/projects/Laya/laya` |
| `LAYA_MODELS_ROOT` | directory holding the three checkpoints | `<LAYA_HOME>/models` |
| `LAYA_SERVE_SCRIPT` | path to `laya_serve.py` | bundled resource |
| `LAYA_DEVICE` | `cpu` / `mps` / `cuda` | `cpu` |
| `LAYA_THREADS` | torch intra-op threads | `16` |
| `LAYA_MAX_LEN` / `LAYA_HEAD_MAX_LEN` | token budgets | `4096` / `2048` |
| `LAYA_MAX_CHOICE_OPTIONS` | next-action option cap | `90` |
| `LAYA_MIN_CONFIDENCE` | abstention threshold | `0.0` |
| `LAYA_TIMEOUT_SECONDS` | per-request timeout | `120` |

### Running Laya manually

```bash
Scripts/start-laya.sh                      # cpu, port 8000, preloads english
Scripts/start-laya.sh --device mps         # Metal GPU
Scripts/start-laya.sh --preload english,multilingual
curl -s localhost:8000/health
```

`LAYA_PRELOAD_MODELS=""` preloads all three checkpoints (~2.3 GB resident).

---

## Architecture — Windows → macOS map

| Concern | Windows (C#/.NET 8) | macOS (Swift) |
|---|---|---|
| Core logic | `GhostHand.Core` | `GhostHandCore` (platform-independent, no AppKit) |
| Decision model | Jev via Vercel AI Gateway | **Laya, local** (`LayaClient` + `LayaDecisionModel`) |
| Screen reading | FlaUI + Windows UI Automation | `AXScreenReader` (`AXUIElement` tree walk, batched attribute reads) |
| OCR fallback | `Windows.Media.Ocr` | `VisionOcrService` (Vision `VNRecognizeTextRequest`) |
| Input & execution | Win32 `SendInput` + UIA patterns | `CGInputSimulator` (`CGEvent`) + AX `AXPress`/`AXValue` |
| Global hotkey | `WH_KEYBOARD_LL` low-level hook | `EventTapHotkeyService` (`CGEventTap` + `ChordStateMachine`) |
| Window tracking | `GetForegroundWindow` / `EnumWindows` | `MacWindowCaptureService` (`NSWorkspace` + `CGWindowListCopyWindowInfo` + AX) |
| App/URL launching | Registry `App Paths` + Start Menu `.lnk` | `/Applications` scan + `NSWorkspace` |
| Credentials | Windows Credential Manager | `KeychainCredentialStore` (Security framework) |
| Audit log | `%LOCALAPPDATA%\GhostHand\audit` | `~/Library/Application Support/GhostHand/audit` |
| Speech | Whisper.net / `Windows.Media.SpeechRecognition` | `MacSpeechService` (`SFSpeechRecognizer`, on-device) |
| UI | WPF acrylic popup + tray icon | AppKit `NSPanel` + SwiftUI overlay + `NSStatusItem` |

The deterministic agent logic is a faithful port: the agent loop, candidate generation,
risk policy, secret sanitizer, element ranker, loop guard, URL validator and chord state
machine keep the same behaviour, thresholds and regexes as the C# originals. Only the
arbitration model changed (Laya, local).

### Package layout

```
macos/
├── Package.swift
├── Sources/
│   ├── GhostHandCore/       # Models, interfaces, agent loop, Laya client/model, safety, ranking
│   ├── GhostHandPlatform/   # AX, CGEvent, Keychain, Vision, speech, launcher, Laya server manager
│   ├── GhostHandCLI/        # `ghosthand` diagnostic + runner
│   └── GhostHandApp/        # menu-bar app + overlay
├── Tests/GhostHandCoreTests/
├── Resources/Info.plist
└── Scripts/                 # build.sh, test.sh, start-laya.sh, laya_serve.py, make-app-bundle.sh
```

---

## CLI

```
ghosthand check                 # environment, permission and local-Laya checks
ghosthand snapshot [pid|name]   # print the accessibility tree of the frontmost window
ghosthand dry-run "<goal>"      # plan without performing input
ghosthand run "<goal>" --live   # execute for real
```

Add `--target <name|pid>` to aim at a specific app; `--yes` auto-approves any confirmation
(testing only). `run` and `dry-run` refuse to start without Accessibility permission, since
the agent would otherwise act blind — set `GHOSTHAND_ALLOW_NO_AX=1` to override for diagnostics.

---

## Safety model (unchanged from Windows)

- **Deletion is prohibited.** Goals and actions matching `delete`, `deletion`, `erase`,
  `wipe`, `destroy`, `truncate`, `format`, `del` are refused before execution.
- **Password managers are deny-listed** (1Password, Bitwarden, KeePass, …).
- **Passwords and secrets never leave the machine** — password fields are dropped and
  card/token/bearer patterns are redacted before anything reaches the model or the audit log.
- **Every decision is audited** locally as JSONL.
- Jarvis mode executes all *non-deletion* actions automatically, exactly like the Windows
  build's current policy.

Because Laya is local, the state GhostHand sends never leaves the machine at all.

---

## Differences from the Windows build

- **Decision model:** Laya on loopback instead of Jev through the Vercel AI Gateway; no API
  key, no network, and the state never leaves the Mac.
- **Hotkey:** Windows uses `Ctrl + Win`; macOS has no Windows key, so the chord is
  **Control + Option**. The pure `ChordStateMachine` is unchanged — only the key mapping in
  the event tap differs.
- **Elevation:** Windows has UIPI and refuses elevated targets. macOS has no equivalent;
  some hardened-runtime apps still expose a limited accessibility tree.
- **OCR / speech:** native Vision and Speech frameworks instead of Windows.Media.Ocr and
  Whisper.net. No model download required.
- **No ReadyToRun/self-contained binary:** this is a Swift package; `make-app-bundle.sh`
  produces the distributable `.app`.

---

## Building notes

SwiftPM's default caches live under `~/Library` and `$TMPDIR`, and it wraps manifest
compilation in `sandbox-exec` — both fail in restricted environments. All scripts therefore
source `Scripts/swiftpm-env.sh`, which redirects the caches into the package directory and
passes `--disable-sandbox`. Use the scripts rather than calling `swift build` directly.
