# PrintGlance

A macOS 14+ menu bar app (Swift 6, SwiftUI, no dependencies) that shows Bambu Lab 3D printers' progress by talking MQTT over TLS to each printer on the LAN. Up to four printers, notifications, AMS filament, history.

- **How it works:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Read it before changing behavior.
- **How it's tested:** [docs/TESTING.md](docs/TESTING.md). Read it before writing tests.
- **What users are promised:** [README.md](README.md). `ShippingTests` fails when it and the code disagree.

## Commands

- `make test`: the Swift suite and the Python feed's suite, about 20 s. Bare `swift test` fails where `xcode-select` points at the Command Line Tools; the Makefile sets `DEVELOPER_DIR` to Xcode.
- `PG_RENDER_DIR=/tmp/pg make test`: PNGs of every card, menu bar, list, history, and setup state, light and dark.
- `make app`: builds `dist/PrintGlance.app`, ad-hoc signed.
- `make install`: quits the running app and **rewrites saved printers from `.env`**. Ask before running it. Also ask before launching any build: it connects to real printers, and only one copy can run.

## Rules

- **Read-only.** The only MQTT publish is `pushall` to `device/<serial>/request`. Never send a printer command.
- **LAN only.** The app's only internet request is the daily GitHub release check.
- **Secrets.** Never log, print, or commit an access code. Never print `.env`. Mask serials and IPs in logs you share.
- No new dependencies. Keep `Printer`, `PrintDoc`, `AMSTray` (and friends) `Codable`; add only optional fields with `= nil`.
- Don't edit `bambu.py`, `print_loop.*`, `.env*`, or launchd: the feed runs as a LaunchAgent on the owner's Mac.
- Don't restructure the load-bearing macOS workarounds listed in ARCHITECTURE.md (`PinMenuBarExtra`, `hugMenuBarPanel`, `PanelOpened`, no `.id(strip)`, "keep `failed` through retries", `Notifier`).
- Reach Notification Center only through `Notifier`. It traps in tests, and a MainActor permission completion traps in the app.
- Presentation decisions go in pure `static` functions on `GlanceContent` (report parsing on `BambuPrint`), each tested. Views stay thin.
- Tests never touch `UserDefaults.standard`, Notification Center, the network, or `~/Library`; use `ModelHarness`, `Screen`, `FakeBroker`, and the other helpers in `Tests/PrintGlanceTests/Support`.
- CI builds with Xcode 16.4 (Swift 6.1), older than a current Mac. Concurrency errors can pass locally and fail in CI; keep non-Sendable framework values inside nonisolated helpers.
- Copy: English, short plain sentences; title case for menu items, sentence case elsewhere. States are Starting, Printing, Paused, Finished, Failed, Idle, Offline.
- Commits: `type: short imperative summary`, lower case (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `build:`, `chore:`). Mark deliberate shortcuts with a `ponytail:` comment naming the limit and the upgrade path.
