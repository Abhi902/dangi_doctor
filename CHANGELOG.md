## 0.2.3

- **AI pooling for large screens**: when a request exceeds the provider's token limit (413),
  issues are split into batches of 40 and analysed in parallel passes with a compact system
  prompt. A final summarisation call combines all batch findings into a unified health report.
- **Auto-retry on rate limits (429)**: parses the `"try again in Xs"` wait time from Groq /
  OpenAI error responses and retries automatically — no manual re-runs needed.
- **Groq model switched** to `llama-3.1-8b-instant` (30 000 TPM free tier vs 12 000 for 70B),
  making Groq reliably usable without upgrading.
- **Stable tappables polling**: crawler now waits for the tappable-element count to stabilise
  before exploring a screen, catching async-loaded content (API-driven lists, lazy widgets).
- **Smart post-tap waiting**: replaced fixed 1 200 ms delay with a poll-until-screen-changes
  strategy — faster on quick navigations, patient on slow ones.

## 0.2.2

- Expanded Layer 1 AI knowledge with 5 new flutter.dev sources:
  - Layout constraints (`flutter.dev/ui/layout/constraints`)
  - DevTools performance profiling (`flutter.dev/tools/devtools/performance`)
  - DevTools memory & leak detection (`flutter.dev/tools/devtools/memory`)
  - Android deployment guide (`flutter.dev/deployment/android`)
  - Networking & async cookbook (`flutter.dev/cookbook/networking/fetch-data`)
- AI diagnosis now free for everyone: added Groq (free tier, no credit card) and
  Ollama (fully local, no account) to README with setup instructions.
- Knowledge auto-updates every Monday via GitHub Actions.

## 0.2.1

- Fixed pub.dev score issues:
  - Shortened `pubspec.yaml` description to fit 60–180 character limit.
  - Updated `repository`, `homepage`, and `issue_tracker` to the correct GitHub URL.
  - Bumped `vm_service` dependency to `^15.0.0` (latest compatible version).
  - Added `example/main.dart` (canonical example file pub.dev looks for).
  - Fixed HTML angle brackets in dartdoc (`GlobalKey<NavigatorState>` → backtick-quoted).
  - Added dartdoc comments to `DiscoveredScreen` fields, `ScreenNavigator` fields,
    and `HtmlReportGenerator` to push API documentation coverage above 20%.

## 0.2.0

- **Phase 2 navigation completely rewritten** — replaced nav-bar heuristic detection with
  universal tappable exploration. Uses `adb shell uiautomator dump` to get exact pixel bounds
  for every clickable element; taps each one and detects new screens by root widget type change
  or significant source-file delta. Works on any Flutter app with no hardcoded assumptions.
- ListView deduplication: elements with multi-line data labels (e.g. `&#10;` entities) are
  grouped by screen column; only the first item per group is tapped, preventing wasted taps on
  long ListView.builder lists.
- Depth-aware back navigation: `navDepth` tracks forward push steps from home; back-presses
  are capped at `navDepth + 2` so the crawler never overshoots past the target screen.
- Overshoot detection: `_returnToScreen` stops immediately if it lands on the home screen
  before reaching the intended target (fixes cascade failures from tab-switch navigation).
- Back-button filtering now catches unlabelled AppBar icons — elements at top-left corner
  (cx < 200, cy < 380) with no text or auto-generated `tap(cx,cy)` label are skipped.
- Explored paths persisted to `.dangi_doctor/explored_paths.json`; subsequent runs offer
  continue-from-last-run or restart-fresh options.
- Fixed broken `example/` file (was importing nonexistent `package:cli/cli.dart`).
- Fixed all `dart analyze` warnings; `dart format` applied throughout.
- `lib/cli.dart` now exports the real public API (`DiscoveredScreen`, `ScreenNavigator`,
  `AppAnalysis`, `AppAnalyser`).

## 0.1.0

- Initial release.
- Live Flutter app crawler via Dart VM service WebSocket.
- Widget tree analyser: deep nesting, Provider overload, anti-patterns with exact file:line.
- Performance measurement via VM Timeline API (grade A–F per screen).
- Static bug detectors: `setState` after dispose, stream subscription leaks, build side-effects, late field double-init.
- AI diagnosis (Claude, OpenAI, Gemini, Groq, Ollama) with 3-layer knowledge system.
- Integration test generator: smoke, interaction, and performance test files per screen.
- HTML health report auto-opened in browser after every run.
- Port remapping via `/proc/net/tcp` — handles Flutter's incorrect observatory port reporting on Android.
- Project fingerprint (Layer 3) generated on first run, saved to `.dangi_doctor/project.json`.
