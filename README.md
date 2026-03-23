# Dangi Doctor 🩺

**Your Flutter app's personal physician.**

Dangi Doctor connects to your live Flutter app, crawls every screen automatically, finds real bugs through static analysis, measures performance, and generates Flutter integration tests — all without you writing a single line of test code.

---

## What's new in v0.2.3

- **AI pooling for large screens** — when a screen has too many issues for a single API call, they are automatically split into batches of 40, each analysed separately, then combined into one unified health report.
- **Auto-retry on rate limits** — Groq/OpenAI 429 errors are handled silently: the wait time is parsed from the error response and the request retries automatically.
- **Groq free tier now reliable** — switched to `llama-3.1-8b-instant` (30 000 TPM) so Groq works without hitting limits on typical Flutter projects.
- **Smarter crawler** — tappable exploration now waits for async-loaded content to stabilise, and post-tap waits poll for screen changes instead of a fixed delay.

---

## What it does

### 1. Live app crawling
Connects to your running Flutter app via the Dart VM service. Walks every reachable screen by tapping navigation triggers (bottom nav, buttons, drawers). No emulator required — works on real physical devices.

### 2. Static analysis — detects real bugs before they reach production
Scans your `lib/` source code for patterns that cause crashes at runtime:

| Bug type | What it catches |
|---|---|
| `late_field_double_init` | `late` field assigned in a method called from `didChangeDependencies()` without a guard → `LateInitializationError` |
| `setState_after_dispose` | `setState()` in async method without `if (mounted)` → "setState called after dispose" |
| `stream_subscription_leak` | `StreamSubscription` field with no `.cancel()` in `dispose()` → memory leak |
| `build_side_effects` | `setState()` or `await` directly inside `build()` → infinite rebuild loop |

### 3. Generated integration tests — with exact fix instructions
For every screen and every detected bug, Dangi Doctor writes Flutter integration tests directly into your project at `integration_test/dangi_doctor/`. Each failing test tells you:
- Exact file and line number
- Plain-English explanation of the bug
- Copy-pasteable fix code

```
BUG: pages/SplashScreen/splashScreenPage.dart:74 —
late field `_appLinks` double-init in `initDeepLinks()`

━━━ BUG DETECTED ━━━
File: pages/SplashScreen/splashScreenPage.dart:74

Problem:
Late field `_appLinks` is assigned in `initDeepLinks()` which is called
from `didChangeDependencies()` without an initialization guard...

Fix:
  bool _initDeepLinksCalled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initDeepLinksCalled) {
      _initDeepLinksCalled = true;
      initDeepLinks();
    }
  }
━━━━━━━━━━━━━━━━━━━
```

### 4. HTML health report
After every diagnosis, Dangi Doctor opens a health report in your browser automatically.

- Overall health score (0–100)
- Per-screen performance grade (A–F) with build time, jank %, memory
- All issues listed with severity (error / warning / info)
- Static analysis bugs table with file locations and fix code
- Saved to `.dangi_doctor/report_<timestamp>.html`

### 5. AI diagnosis (optional)
If you have a Claude, OpenAI, Gemini, Groq, or Ollama API key, Dangi Doctor gives each screen a written diagnosis — what's wrong, why it matters, and a prioritised fix list.

The AI is powered by a 3-layer knowledge system that stays current automatically:
- **Layer 1** — Flutter official knowledge: widget lifecycle, performance rules, state management error patterns for Provider / BLoC / Riverpod / GetX, common Flutter errors by category, and the last 5 Flutter version changelogs. Updated weekly by pulling directly from the Flutter GitHub repo.
- **Layer 2** — Community anti-patterns: most common mistakes found across thousands of real production Flutter apps.
- **Layer 3** — Your project: auto-detected on first run. State management, dependencies, folder structure, naming conventions, largest files. Stored at `.dangi_doctor/project.json`.

---

## Requirements

- Dart SDK ≥ 3.0
- Flutter project with a physical Android device or emulator
- `adb` installed (Android Debug Bridge)

---

## Installation

```bash
dart pub global activate dangi_doctor
```

Or add to your Flutter project's dev dependencies:

```yaml
dev_dependencies:
  dangi_doctor: ^0.1.0
```

---

## Usage

From the root of your Flutter project:

```bash
cd /path/to/your/flutter/app
dangi_doctor
```

Dangi Doctor auto-detects your project from the current directory. If you need to point it at a different path, use the `DANGI_PROJECT` env var.

On first run, Dangi Doctor will ask how to connect:

```
┌─────────────────────────────────────────────┐
│  How do you want to connect?                │
│                                             │
│  1. Launch app now (Dangi Doctor runs it)   │
│  2. App already running — paste VM URL      │
└─────────────────────────────────────────────┘
```

Choose **1** to let Dangi Doctor launch your app, or **2** to paste the VM service URL from a running `flutter run --debug` session.

### Run generated tests

```bash
flutter test integration_test/dangi_doctor/<screen>_smoke_test.dart \
  -d <device_id>
```

With auth token (for apps requiring login):

```bash
flutter test integration_test/dangi_doctor/<screen>_smoke_test.dart \
  --dart-define=TEST_TOKEN=your_token \
  -d <device_id>
```

### AI diagnosis — free options

You do not need a paid subscription to get AI diagnosis.

| Provider | Cost | How to get a key |
|---|---|---|
| **Groq** | Free tier (14,400 req/day) | Sign up at `console.groq.com` — no credit card |
| **Ollama** | Free, runs locally | Install from `ollama.com`, run `ollama pull llama3` |
| Claude | Paid | `console.anthropic.com` |
| OpenAI | Paid | `platform.openai.com` |
| Gemini | Paid | `aistudio.google.com` |

If no API key is set, Dangi Doctor asks at runtime which provider to use. Choose **Groq** for the quickest free setup, or **Ollama** for fully offline diagnosis.

### Environment variables

| Variable | Description |
|---|---|
| `DANGI_PROJECT` | Path to your Flutter project (auto-detected from cwd if omitted) |
| `CLAUDE_API_KEY` | Claude API key for AI diagnosis |
| `OPENAI_API_KEY` | OpenAI API key for AI diagnosis |
| `GEMINI_API_KEY` | Gemini API key for AI diagnosis |
| `GROQ_API_KEY` | Groq API key for AI diagnosis |

---

## How it works

```
dart run dangi_doctor
        │
        ├── 1. Detect AI provider (Claude / OpenAI / Gemini / Groq / Ollama)
        │
        ├── 2. Connect to Flutter app via Dart VM service WebSocket
        │         └── Port remapping: reads /proc/net/tcp on device to find
        │             the real VM port, then adb forward tcp:8181 tcp:<actual>
        │
        ├── 3. Wait for splash screen to dismiss
        │
        ├── 4. Crawl all screens
        │         └── Tap nav triggers (bottom nav, buttons, drawers)
        │         └── Capture widget tree per screen via VM service
        │         └── Measure frame performance via VM Timeline API
        │         └── Detect widget tree issues (nesting, anti-patterns)
        │
        ├── 5. AI diagnosis per screen (if API key present)
        │         └── 3-layer knowledge prompt → Claude/GPT/Gemini
        │
        ├── 6. Static analysis
        │         └── Scan lib/ for KnownRisk patterns
        │         └── LateInitializationError, setState after dispose,
        │             stream leaks, build() side effects
        │
        ├── 7. Generate integration tests
        │         └── integration_test/dangi_doctor/<screen>_smoke_test.dart
        │         └── integration_test/dangi_doctor/<screen>_interaction_test.dart
        │         └── integration_test/dangi_doctor/<screen>_perf_test.dart
        │         └── integration_test/dangi_doctor/test_helper.dart
        │
        └── 8. Generate HTML report → open in browser
                  └── .dangi_doctor/report_<timestamp>.html
```

---

## Knowledge auto-update

Layer 1 knowledge is bundled as a Dart constant in the package and updated weekly by a GitHub Actions workflow that pulls from the Flutter GitHub repo. You get the latest Flutter version notes, breaking changes, and bug patterns every time you run `dart pub upgrade dangi_doctor`.

To update manually (for contributors):

```bash
dart run tool/update_knowledge.dart
```

---

## Output files

After a diagnosis run, your Flutter project will contain:

```
integration_test/
  dangi_doctor/
    test_helper.dart                  ← shared setup: Firebase init, auth injection
    <screen>_smoke_test.dart          ← launch test + bug-specific targeted tests
    <screen>_interaction_test.dart    ← tap every button, verify navigation
    <screen>_perf_test.dart           ← frame timing assertions

.dangi_doctor/
  project.json                        ← Layer 3 project fingerprint
  report_<timestamp>.html             ← HTML health report
  vm_service_url.txt                  ← cached VM URL for reconnection
```

---

## License

MIT
