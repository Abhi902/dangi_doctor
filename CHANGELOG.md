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
