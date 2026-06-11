# Lumen

**The screen assistant you can audit.**

**Start here:** [CLICKY-90.md](CLICKY-90.md) — what I'd ship at Clicky in the next 90 days.

Every screen-watching AI asks you to trust it blindly. Lumen shows you exactly
what it sees, what it sends, and what it's doing — in real time.

Hold **⌃⌥**, ask about your screen by voice, release. Lumen captures one frame
and the frontmost app's accessibility tree, streams a terse answer, **speaks
it** (voice-first — the transcript is an opt-in toggle), and **points** — a
traveling cursor and highlight boxes anchored to the real UI elements it's
talking about. Ask it to *"walk me through this screen"* and it gives a
narrated, element-by-element tour, each highlight landing exactly when the
voice mentions it.

The **notch is the surface.** Lumen lives in the MacBook notch: it ripples while
listening, shows the capture receipt, and on **hover unfolds into the full
control panel** — provider cards (Claude · Local · Demo, keys in the Keychain),
the X-Ray and transcript toggles, and one-tap **History · Replay · Welcome Tour ·
Agent preview**. **Escape** dismisses everything — transcript, receipt, panel,
mid-answer — instantly. (The menu bar still exists as a secondary surface for the
same actions.)

Inspired by [Clicky](https://www.heyclicky.com/); differentiated on
auditability, grounding architecture, and bring-your-own-model.

## The thesis, made visible

| Guarantee | Where you see it |
|---|---|
| You see exactly what was captured | The **receipt** in the notch renders the same bytes the model receives |
| Passwords never leave the machine | Secure fields are blacked out **in the payload**, not just the preview |
| Nothing is captured between questions | Capture fires only while ⌃⌥ is held |
| Voice never leaves the Mac | STT (Apple Speech) and TTS (AVSpeechSynthesizer) are on-device |
| You know where data goes | **X-Ray mode** shows the live pipeline, real timings, the **EST. PAYLOAD** cost line, and the actual network destination per turn |
| Zero setup earns trust first | The **Demo provider** answers before any key exists — the tour runs offline; it's also the live-demo insurance |
| You can reproduce a past answer | **Replay** re-performs the last exchange from the event log — no model, no network |
| Nothing evaporates | **History** persists every exchange from the same append-only log |
| Fully-local mode exists | Point the BYOK provider at Ollama on localhost — screen, voice, and reasoning all stay home |
| The product teaches itself | A directed **3-chapter tour**, advanced by your own summons, with no setup required |

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
lands in an append-only JSONL log — the **event spine** with three consumers:
the **X-Ray** overlay (live timings + privacy), the **History** window, and
**Replay** (re-performing the last exchange from the logged rects).
**13 unit tests** run hostless (a bundle target — no app launch).

```
 ⌃⌥ down ──┬─ Apple Speech (on-device, live partials)
            ├─ ScreenCaptureKit frame  ──┐  redact secure fields
            └─ AX tree snapshot        ──┤  (in the payload bytes)
 ⌃⌥ up  ──► Reasoner (BYOK seam) ────────┴─► SSE stream
                │ Claude · api.anthropic.com          │
                │ Ollama/OpenAI-compatible · localhost│
                │ Demo · offline fixture (no network) │
                ▼                                     ▼
        [POINT:E12]/[BOX:E12] tags          receipt + caption (in the notch)
                ▼                                     ▼
        AnnotationLayer (paced)  ◄── Narrator (on-device TTS, the pacer)
                ▼
   Event spine (JSONL) ──► X-Ray · History · Replay
```

## Build & run

Requirements: macOS 15+ (Liquid Glass materials on macOS 26), Xcode 16+.

```sh
brew install xcodegen   # project.yml is the source of truth
xcodegen generate
open Lumen.xcodeproj    # ⌘R
```

Builds sign with a personal Apple Development identity (`project.yml` sets the
team — building on your own Mac, swap `DEVELOPMENT_TEAM` for yours), so TCC
permission grants survive rebuilds. There's no notarization on a
free Apple ID — if you run a **downloaded** zip instead of building from
source, first launch is right-click → **Open** to clear Gatekeeper once.

First run, grant four permissions: **Accessibility** (global hotkey + element
grounding), **Screen Recording**, **Microphone**, **Speech Recognition**.
Speech also requires Dictation or Siri enabled in System Settings. Lumen then
introduces itself — the onboarding is the product giving you its own tour, and
because the **Demo provider** answers with no key, the tour runs before you
configure anything.

**Providers (BYOK):** hover the notch (or use the menu bar) → pick a provider
card. **Claude** takes an Anthropic API key (stored in the Keychain, never on
disk); **Local** is any OpenAI-compatible endpoint — for Ollama,
`ollama pull qwen3-vl`, no key needed; **Demo** is the offline fixture.
Switching providers takes effect on the next summon — including mid-demo.

## Try these

- *"What app am I looking at?"* — the core loop
- *"Where do I click to …?"* — element-anchored pointing
- *"Walk me through everything on this screen"* — the narrated tour
- Hover the notch → **X-Ray mode**, then ask again — watch the pipeline run live, EST. PAYLOAD and all
- Hover the notch → **Replay** — the last exchange re-performs from the log, no model
- Hover the notch → **Agent preview** — the trust protocol, choreographed
- Type a password field on screen, then summon — watch the receipt redact it

## Status & roadmap

Built as a 2-day design-partner exercise. **Shipped, all real:** ⌃⌥ capture, AX
grounding, all three providers (Claude · Local · Demo), narrated 3-chapter tour,
secure-field redaction, the notch surface, X-Ray with the EST. PAYLOAD cost line,
the append-only event spine, and its consumers — X-Ray, History, and Replay.
Agent-mode *execution* is deliberately mocked; the trust UX
(plan preview, control-handoff border, instant reclaim) is the part being
demonstrated. **Deferred:** typed summon, multi-display, and a notarized `.dmg`.
