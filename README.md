# Lumen

**The screen assistant you can audit.**

Every screen-watching AI asks you to trust it blindly. Lumen shows you exactly
what it sees, what it sends, and what it's doing — in real time.

Hold **⌃⌥**, ask about your screen by voice, release. Lumen captures one frame
and the frontmost app's accessibility tree, streams a terse answer, speaks it,
and **points** — a traveling cursor and highlight boxes anchored to the real
UI elements it's talking about. Ask it to *"walk me through this screen"* and
it gives a narrated, element-by-element tour, each highlight landing exactly
when the voice mentions it.

Inspired by [Clicky](https://www.heyclicky.com/); differentiated on
auditability, grounding architecture, and bring-your-own-model.

## The thesis, made visible

| Guarantee | Where you see it |
|---|---|
| You see exactly what was captured | The **receipt** — the pill renders the same bytes the model receives |
| Passwords never leave the machine | Secure fields are blacked out **in the payload**, not just the preview |
| Nothing is captured between questions | Capture fires only while ⌃⌥ is held |
| Voice never leaves the Mac | STT (Apple Speech) and TTS (AVSpeechSynthesizer) are on-device |
| You know where data goes | **X-Ray mode** shows the live pipeline, real timings, and the actual network destination per turn |
| Fully-local mode exists | Point the BYOK provider at Ollama on localhost — screen, voice, and reasoning all stay home |

## Architecture in one paragraph

Perception is two-channel: the **screenshot** (ScreenCaptureKit, self-excluded,
~1280px JPEG) tells the model what the screen *looks like*; the **AX tree**
(AXUIElement — roles, labels, exact frames, captured speculatively on
hotkey-down in parallel with the frame) tells it where things *are*. The model
answers with inline spatial tags — `[POINT:E12]` / `[BOX:E12]` reference real
elements, so pointing accuracy is a property of the system, not the model's
eyesight; weak local models get strong grounding for free. A streaming
segmenter splits the answer into narration beats; the on-device voice paces
the tour, firing each beat's highlights as its audio starts. Every stage event
lands in an append-only JSONL log — the same stream that powers the X-Ray
overlay and, next, replay and memory.

```
 ⌃⌥ down ──┬─ Apple Speech (on-device, live partials)
            ├─ ScreenCaptureKit frame  ──┐  redact secure fields
            └─ AX tree snapshot        ──┤  (in the payload bytes)
 ⌃⌥ up  ──► Reasoner (BYOK seam) ────────┴─► SSE stream
                │ Claude · api.anthropic.com          │
                │ Ollama/OpenAI-compatible · localhost│
                ▼                                     ▼
        [POINT:E12]/[BOX:E12] tags          caption pill (at cursor)
                ▼                                     ▼
        AnnotationLayer (paced)  ◄── Narrator (on-device TTS, the pacer)
                ▼
        Event log (JSONL) ──► X-Ray overlay (live timings + privacy)
```

Decision records live in [`docs/adr/`](docs/adr/); the build journal in
[`docs/ideation/`](docs/ideation/).

## Build & run

Requirements: macOS 15+ (Liquid Glass materials on macOS 26), Xcode 16+.

```sh
brew install xcodegen   # project.yml is the source of truth
xcodegen generate
open Lumen.xcodeproj    # ⌘R
```

First run, grant four permissions (one time — the build is signed with a
stable identity so grants persist): **Accessibility** (global hotkey +
element grounding), **Screen Recording**, **Microphone**, **Speech
Recognition**. Speech also requires Dictation or Siri enabled in System
Settings. Lumen then introduces itself — the onboarding is the product
giving you its own tour.

**Providers (BYOK):** menu bar → set an Anthropic API key (stored in the
Keychain, never on disk), or flip to the local provider — any
OpenAI-compatible endpoint. For Ollama: `ollama pull qwen3-vl`, done; no key
needed. Switching providers takes effect on the next summon — including
mid-demo.

## Try these

- *"What app am I looking at?"* — the core loop
- *"Where do I click to …?"* — element-anchored pointing
- *"Walk me through everything on this screen"* — the narrated tour
- Menu → **X-Ray mode**, then ask again — watch the pipeline run live
- Menu → **Agent Mode (design preview)** — the trust protocol, choreographed
- Type a password field on screen, then summon — watch the receipt redact it

## Status & roadmap

Built as a 2-day design-partner exercise. Real: capture, AX grounding,
both providers, narrated tours, redaction, X-Ray, event log. Designed-but-
mocked (deliberately): agent-mode *execution* — the trust UX (plan preview,
control-handoff border, instant reclaim) is the part being demonstrated.
Next: multi-display, AX-only context mode (cost), notch presence, replay
from the event log.
