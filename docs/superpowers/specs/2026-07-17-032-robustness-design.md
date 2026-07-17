# 0.3.2 "trustworthy" — robustness release design

Date: 2026-07-17
Status: awaiting approval
Source: three-agent code audit of 0.3.1 (crawler/analysis, AI/knowledge, generator/CLI/packaging), cross-checked against the 2026-07-15 REVIEW.md.

## Context

0.3.1 is verifiably healthy: `dart analyze` clean, publish dry-run clean, 19/19 tests pass,
generated tests compile, knowledge pipeline honest. The audit found a focused set of
remaining defects — one resource leak, several still-open items from the July review,
provider bugs that defeat their own features, and two "honesty gaps" where generated
tests cannot fail. This release fixes those and adds the two regression guards that
protect the package's core promise.

## Goals

Ship 0.3.2 with the confirmed defects fixed and CI guards in place. No new features,
no new platforms, no adoption work (that's 0.4.0).

## Non-goals (deferred)

- Knowledge auto-publish loop, CI sample workflow, JSON report, pub.dev polish → M2 (0.4.0).
- New detectors, scrolling/text-input/deep-link crawling, structured AI output → M3 (0.5.0).
- iOS support → separate effort after M3.
- `UnknownScreen` fingerprint re-keying and resume-state redesign → M3 (resume robustness);
  0.3.2 only fixes the failed-tap-marked-explored bug within the current keying scheme.

## Fixes

### A. Crawler / analysis

1. **Performance-capture leak** (`lib/crawler/screen_navigator.dart:499-505`, `:307-310`,
   `:333-335`; `lib/analysis/performance.dart`). Add `PerformanceCapture.abandon()` that
   cancels the `onExtensionEvent` subscription and resets VM timeline flags without
   producing a result. Every code path that starts a capture must end it: non-navigating
   tap, navigation to an already-known screen, failed Phase-1 route. Guard with a test
   using a mock/spy capture asserting start/stop pairing across those paths.
2. **Failed tap recorded as explored** (`screen_navigator.dart:481`, `:509`). Record the
   coordinate in `_exploredTappables` only after `AdbRunner.tap` returns success, so an
   adb hiccup doesn't permanently blacklist an unexercised element.
3. **uiautomator XML parsing: extract + fix + test** (`screen_navigator.dart:563-610`).
   Extract `_getAllTappables` parsing into a testable top-level function; decode XML
   entities (`&amp;`, `&quot;`, `&lt;`, `&gt;`, `&#10;`, `&apos;`) before labels feed
   dangerous-label / back-button / dialog matching; add fixture tests (real uiautomator
   dump samples, entity cases, `_deduplicateListItems` interaction).
4. **Fallback tree-capture timeouts** (`screen_navigator.dart:1088-1092`,
   `screen_crawler.dart:163-167`). Apply the same 6s timeout the primary call has.

### B. Launcher / VM location

5. **VM detection** (`lib/crawler/vm_locator.dart:37-60`). Verify the endpoint is a Dart
   VM (fetch and check the response body / attempt a `getVersion` over ws) instead of
   accepting any HTTP 200; `close()` the `HttpClient` and drain responses in a `finally`.
   Port list stays as-is (the launcher path already learns the real port).
6. **Isolate selection** (`lib/crawler/screen_crawler.dart:26`). Choose the isolate that
   exposes `ext.flutter.*` extensions (iterate `vm.isolates`, inspect `extensionRPCs`)
   instead of `.first`; fail with a clear message when none qualifies or the list is empty.
7. **Launcher stdout parsing** (`lib/crawler/app_launcher.dart:123`, `:161-171`). Feed
   stdout/stderr through `LineSplitter`; make the completion guard race-free by claiming
   completion synchronously (set a flag before the first `await`), so two chunks can't
   both pass the guard. Kill the orphaned `flutter devices` process on timeout (`:48-52`).

### C. AI providers

8. **OpenAI param** (`lib/ai/knowledge/ai_providers.dart:253`). Send
   `max_completion_tokens` (accepted by both generations) so `DANGI_OPENAI_MODEL`
   overrides to current models work.
9. **Gemini output handling** (`ai_providers.dart:127-135`, `:321`). Concatenate all
   text parts instead of `parts.first`; set an explicit thinking budget / higher
   `maxOutputTokens` so reasoning tokens don't consume the answer; surface partial
   output on `MAX_TOKENS` instead of throwing.
10. **Claude multi-block text** (`ai_providers.dart:80-87`). Join all text blocks.
11. **Default model refresh** (`ai_providers.dart:147-159`). Update OpenAI, Groq, and
    Ollama defaults to current mid-2026 models (verify exact IDs against provider docs
    at implementation time); align README table.
12. **Retry hygiene** (`ai_providers.dart:680-691`). Cap `Retry-After` sleeps at 60s
    (beyond that, fail the screen — per-screen isolation keeps the run alive); apply the
    existing backoff to timeout retries.
13. **Fence escaping** (`ai_providers.dart:541-557`). Strip or entity-escape literal
    `</crawled_data>` in `screenContext`/`issueText` before interpolation.
14. **Updater write-after-check** (`tool/update_knowledge.dart:98-109`). Fail on
    `missingSections` *before* writing `layer1_content.dart`, so a failed local run
    can't leave a degraded file in the tree.

### D. Generator / report / CLI

15. **`integration_test` prerequisite** (`lib/generator/test_generator.dart`). At
    generation time, parse the target project's pubspec; if `integration_test` /
    `flutter_test` dev-dependencies are missing, print the exact stanza to add (and note
    it prominently in the generated README and package README). Add the dependency to
    `playground/`.
16. **Honest perf test** (`bin/dangi_doctor.dart:222`, `test_generator.dart:522-543`).
    Plumb real `interactionResults` from the crawl into the generator; generated perf
    test asserts a frame-budget threshold derived from the measured refresh rate, so it
    can actually fail. If no data was collected, generate a clearly-labeled skip, not a
    fake passing test.
17. **`build_side_effects` dead assertion** (`test_generator.dart:380-393`). Replace the
    never-thrown error-message grep with an honest generated test: reference the detected
    file/line and fail with the explanation (same pattern as the leak test's
    "delete once fixed" design), rather than silently always passing.
18. **Generated-code lint cleanliness** (`test_generator.dart:466`, `:481`, perf-test
    imports). Remove the unused import; add braces to single-statement `for` loops, so
    output is analyzer-clean under default `flutter_lints`.
19. **Escape `screenName` in generated Dart** (`test_generator.dart:231`, `:499`, `:537`)
    via the existing `esc()` helper.
20. **`_analyseAppState` fallback** (`lib/generator/app_analyser.dart:133-135`). When
    the class-name regex fails but fields matched, extract the actual class name from
    the file instead of assuming `AppState`; if none found, skip state-priming rather
    than emit a nonexistent class.
21. **HTML report** (`lib/report/html_report.dart:16-25`, `:43-45`, `:131`, `:264`).
    Escape `projectName` (and add `'` to `_esc`); add seconds to the report filename;
    Windows open via `start "" <path>` (empty title argument).
22. **CLI odds and ends** (`lib/src/cli_config.dart:6`, `bin/dangi_doctor.dart:130-133`).
    Add `--rescan` flag (deletes/ignores the cached fingerprint — closes the July
    review's remaining fingerprint item); reject unexpected positional args with usage
    exit 64; use `exitCode` not `exit()` for the no-VM-URL error; add a test asserting
    `kDangiVersion` matches `pubspec.yaml`.

## Regression guards (CI)

23. **Fixture-compile job**: GitHub Actions workflow with the Flutter SDK that runs the
    generator against `playground/` and `flutter analyze`s the emitted
    `integration_test/dangi_doctor/` — must report 0 issues (fix #18 makes this
    achievable). This is the automated version of the manual check the audit performed
    and the single highest-value guard for the package's core promise.
24. **Parser fixtures**: tests for the extracted uiautomator parsing (#3), plus
    `AppLauncher` VM-URL line parsing and `/proc/net/tcp` parsing
    (`app_launcher.dart:126-167`, `:221-252`) with recorded fixtures, and
    `VmEvaluator._dartLiteral` escaping (`vm_evaluator.dart:338-339`).
25. **Capture-lifecycle test**: pairing test from fix #1.
26. Replace the placeholder `test/cli_test.dart` assertion with the `kDangiVersion`
    sync test (#22) and positional-arg rejection test.

## Testing / verification

- `dart analyze` and `dart test` clean throughout; new fixtures land beside the fixes.
- The fixture-compile CI job (#23) is the release gate for the generator changes.
- Crawler changes (#1-#4) that can't be fully unit-tested get a manual on-device
  verification pass before release, same as 0.3.0 did.
- Version bump to 0.3.2, CHANGELOG entry, tag `v0.3.2` → existing OIDC publish workflow.

## Risks

- #16 (plumbing `interactionResults`) touches the crawler→generator seam; the
  `InteractionEngine` execute path is currently dead code, so the data source is the
  Phase-2 captures in `ScreenNavigator`, not `InteractionEngine` — implementation must
  confirm which measurements actually exist at `bin/dangi_doctor.dart:222`.
- #11 model-ID refresh must be verified against live provider documentation at
  implementation time, not assumed.
- #6 isolate selection needs care with lazily-registered extensions (poll briefly
  before failing).
