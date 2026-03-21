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
