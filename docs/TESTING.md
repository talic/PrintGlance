# Testing PrintGlance

The suite has two parts: **291 Swift tests** (XCTest, `Tests/PrintGlanceTests`) for the app, and **64 Python tests** (unittest, `Tests/Feed`) for the feed. Together they run in about 20 seconds and never touch the network (beyond loopback), Notification Center, this Mac's preferences, or a real printer. How the app works is in [ARCHITECTURE.md](ARCHITECTURE.md).

## Running

```bash
make test
```

That runs `swift test` and then the feed's tests. On a Mac whose `xcode-select` points at the Command Line Tools (no XCTest, no SwiftUI macros), bare `swift test` fails; the Makefile sets `DEVELOPER_DIR` to Xcode. CI runs both on every pull request (`.github/workflows/test.yml`).

One Swift class or test:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GlanceModelTests
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter "SetupScreenTests/testConnectingWelcomesAfterThePrinterAnswers"
```

The feed alone (the repo `.venv` has paho-mqtt; system `python3` skips the two paho tests):

```bash
.venv/bin/python -m unittest discover -s Tests/Feed -v
```

Pictures of every card, menu bar, list, history, and setup state in light and dark, for looking at, not asserting:

```bash
PG_RENDER_DIR=/tmp/pg-renders make test
```

## Layers

| Layer | Files | What it proves | Speed |
|---|---|---|---|
| **Parsing and presentation** (pure functions) | `PrintDocTests`, `PrepareAmsHmsTests`, `BambuSnapshotTests`, `FilamentAlertTests`, `RunoutTrackerTests`, `ComingOffTests`, `PrintNotifyTests`, `JobLogTests`, `AppUpdateTests`, `PrinterDiscoveryTests`, `SetupFlowTests`, `MenuBarHugTests`, `MQTT311ClientTests`, `AccessCodeStoreTests`, `SavedPrintersTests` | Each report field becomes the right row; each row becomes the right words; each rule (ranking, notifications, runout, history, quiet hours, backoff) decides right, with fixed `now`, `Calendar`, and `Locale`. | ms |
| **Workflows** (`GlanceModel` with fakes) | `GlanceModelTests`, `SetupWorkflowTests` | The app as a whole: adding a printer dials it with the code, a report becomes the card and menu bar, a rejected code retries without searching, a printer that moved is found and its new IP saved only once it answers, removing and editing printers, every notification and its identifier, history files, the setup window's connect/fail/retry/cancel/edit. | ms; a few wait for the real 1 s backoff |
| **Wire** (real `MQTT311Client`, real TLS on loopback) | `MQTTWireTests` | The exact bytes of CONNECT, SUBSCRIBE, PUBLISH; CONNACK codes; refused ports; frame reassembly across reads and in one read; 150 KB reports; QoS 1; hostile frames (garbage lengths, topics longer than their packet, truncated packets, non-UTF-8 topics, unknown packet types); a disconnect or replaced socket staying silent. | ~1.5 s |
| **UI** (SwiftUI read through accessibility) | `UI/CardScreenTests`, `UI/PanelScreenTests`, `UI/SetupScreenTests`, `UI/LayoutTests` | What a person sees and can do in each state: exact text in reading order, which buttons exist and are enabled, VoiceOver names for every control, no `Optional(…)` leaking into text, pressing buttons and typing into fields, the full setup flow driven through the window, size limits for small displays and long names. | ~4 s |
| **Security and privacy** | `SecurityTests`, `UpdateCheckTests`, parts of `MQTTWireTests` | The access code only ever travels as the MQTT password (never in the log, client ID, notifications, or publishes); the app only ever publishes `pushall`; outbound URLs carry no serial; updates download only from `https://github.com`; seeded fuzzing of reports, error codes, and discovery packets never crashes or prints an optional. | ~0.5 s |
| **Shipping** | `ShippingTests` | `Info.plist` keys the app relies on; README promises (four printers, 50 jobs, 20%, 5%, Quiet Hours 10 PM–7 AM, lead times, 2-minute network settle, stage words, the paused example, the lost-connection wording, "only fetches GitHub") checked against the constants and functions that keep them. | ms |
| **Renders** | `RenderStatesTests` | PNGs of every state, skipped unless `PG_RENDER_DIR` is set. | — |
| **Python feed** | `Tests/Feed/test_feed.py` | Merging, rows, AMS, the snapshot cache under threads, the read-only MQTT callbacks, the HTTP endpoints and token, `/print.json` never carrying the serial, IP, or code, `bambu.self_test()`. | ~0.6 s |

## Test doubles and helpers

All in `Tests/PrintGlanceTests/Support`.

| Helper | Use it for |
|---|---|
| `ModelHarness(self, saved:, connectTimeout:)` | A `GlanceModel` wired to fakes with its own preferences domain, history file, and log. `add(_:)` saves printers like the setup window and returns their connections; `relaunch()` builds a new model over the same storage; `row(serial)`, `doc`, `logText`, `jobsURL`. `start()` is never called (it touches Notification Center's delegate, GitHub, and NSWorkspace). |
| `FakeMQTT` | One printer connection. The test plays the printer: `accept()` (CONNACK 0), `report([...])` (one `{"print": …}` message), `send(Data)` (raw bytes), `drop("MQTT CONNACK 5")`. Records `dials`, `subscriptions`, `publishes`, `disconnects`. |
| `FakePrinters` | Every connection the model opened; `latest(serial)` finds the newest for a printer. Saving settings opens new ones. |
| `NotificationLog` | Records what the model asked of Notification Center as plain values (`posted` with id, title, body, serial, trigger delay or calendar date; `cancelled`; `permissionRequests`); set `denied` to simulate notifications off. |
| `FakeNetwork` | What discovery finds (`hits`) and how often it searched (`scans`). |
| `Report` | Bambu `print` payloads: `running(...)`, `state("FINISH")`, `ams(remain:)`. Combine with `.merging(...)`. |
| `FakeBroker` | A TLS MQTT broker on `127.0.0.1` with a self-signed certificate generated by `/usr/bin/openssl` and imported in memory only (needs macOS 15; nothing is written to a keychain or the repo). Records client packets, sends bytes as separate TLS records, hangs up. |
| `ClientEvents` | Collects an `MQTT311Client`'s callbacks and spins the main run loop until a condition holds. |
| `Screen(view)` | Renders a SwiftUI view in an offscreen window and reads its accessibility tree: `texts` (static text in reading order), `controls`, `find(label)`, `control(label)`, `has(text)`, `press(label)`, `type(text, into: label)`, `size`. SwiftUI only builds the tree once an assistive app asks; `Screen` sets the private `AXEnhancedUserInterface` flag the way VoiceOver does, and skips if a future macOS drops it. Typing goes through the field editor because setting the accessibility value never reaches SwiftUI's binding. |
| `assertReadsWell(screen)` | Every control has a VoiceOver name, no unnamed images, no `Optional(` in any text. Call it on every screen you build. |
| `Rows` | Printer rows in every state (`printing`, `starting`, `paused`, `failed`, `finished`, `idle`, `offline(was:)`), AMS layouts up to four units plus HT and two externals, and `card(row)` laid out like the panel. |
| `Fuzz`, `SplitMix64` | Seeded random reports and strings, so a failure reproduces from its seed. |
| `scratchDefaults()`, `scratchDirectory()` | A throwaway preferences domain or folder, removed after the test. |
| `eventually { … }` | Polls a main-actor condition for up to 3 s, for work the model does in tasks (rediscovery, backoff, permission). |
| `Counter` | A count a polling closure can read; Swift 6 won't let a `@MainActor` closure capture a `var`. |

## Rules

- **Never touch `UserDefaults.standard`, `~/Library`, or the Keychain's real items.** Use `scratchDefaults()`, `scratchDirectory()`, and `ModelHarness`. `SavedPrinters.load` reads the Keychain for rows with an empty access code; give test printers a code or an empty serial.
- **Never call `UNUserNotificationCenter.current()`.** It traps in a test process (no app bundle). Inject a `Notifier`.
- **No network except loopback.** Don't call `PrinterDiscovery.scan()`, `SetupFlow.scan()` without a fake `discover`, `SetupWindow.show`, or `GlanceModel.start()`.
- **Don't press buttons with side effects outside the app** in UI tests: **Look up** opens the browser, **Add Printer** and **Update Access Code…** open the setup window and scan the Wi-Fi, **Remove…** shows a modal alert, the **More** menu opens a modal menu, **Open System Settings** opens System Settings.
- **Keep `openAtLogin` false** before calling `SetupFlow.finish()`: true registers the test runner as a login item.
- **No dependence on the clock, time zone, or locale.** Pass `now`, `Calendar`, and `Locale` to pure functions. Views format with the Mac's locale, so UI tests match clock text by prefix ("Last update ") or use rows whose `eta` is already a string.
- **Prefer exact expectations.** Assert the whole reading order (`XCTAssertEqual(s.texts, [...])`) where the state is fixed; it catches extra and missing lines.
- **Waits:** use `eventually` with a condition, never a bare sleep to "let things settle". The few fixed sleeps check that something does *not* happen and sit well inside the window that matters (e.g. 1.5 s against a 1 s redial).
- **Fuzzing is seeded.** Change the seed only on purpose; a failure must reproduce.
- **Swift 6.1 in CI.** CI builds with Xcode 16.4, older than a current Mac. Avoid capturing `var`s in `@MainActor` or `@Sendable` closures (use `Counter` or a reference type), and expect the PR's CI to be the real check for concurrency diagnostics.

## Coverage map

| Feature | Tests |
|---|---|
| Report parsing: state, Starting detection, stage words, progress, ETA, job label, temperatures, dual nozzle | `PrintDocTests`, `PrepareAmsHmsTests` |
| Merge semantics (deltas, nested objects, job change) | `PrepareAmsHmsTests.testNestedObjectsMergeKeyByKey`, `PrintDocTests.testMergeClearsLayerOnNewJob`, `GlanceModelTests.testPartialReports…`, `…testANewJobDropsTheOldLayerCount` |
| AMS slots, units, HT, external spools, humidity, filament names, colors | `PrepareAmsHmsTests`, `FilamentAlertTests`, `CardScreenTests.testIdle…` |
| Online/offline/stale/grace/sleep | `BambuSnapshotTests`, `GlanceModelTests.testDroppedPrinterKeepsItsProgressThroughTheGrace`, `CardScreenTests.testOffline…` |
| Menu bar title, icon, accessibility label | `PrintDocTests`, `CardScreenTests.testMenuBarItemReadsAsOneSentence`, `LayoutTests.testMenuBarTitleKeepsItsWidthAsThePercentGrows` |
| Menu bar ranking and focus | `PrintDocTests.testDisplayRowRanksWhoNeedsYou`, `GlanceModelTests.testMenuBarShowsThePausedPrinter…`, `…testClickingAPrinterFocuses…`, `PanelScreenTests.testPrintingCardWithTheListAndSwitchingPrinters` |
| Connecting, handshake, read-only | `GlanceModelTests` (first section), `MQTTWireTests`, `SecurityTests.testOnlyEverAsksForAFullReport` |
| Rejected code, timeout, refused, backoff | `GlanceModelTests` ("Losing the printer"), `MQTT311ClientTests`, `MQTTWireTests`, `PanelScreenTests.testRejectedCode…`, `CardScreenTests.testRejectedCodeOffersToUpdateIt` |
| Rediscovery at a new IP, candidate commit/revert, edit pause | `GlanceModelTests.testPrinterThatMoved…`, `…testANewAddressThatFails…`, `…testEditingAPrinterPausesRediscovery`, `…testReconnectDuringTheSearchIsNotRedialed`, `SetupWorkflowTests.testEditingPausesRediscovery…`, `PrinterDiscoveryTests` |
| Saved printers: cap, edit, focus, migration, Keychain | `SavedPrintersTests`, `AccessCodeStoreTests`, `PrintDocTests.testMigrateSingularSettings`, `…testReplacingOntoExistingSerial…` |
| Setup window | `SetupFlowTests`, `SetupWorkflowTests`, `SetupScreenTests` |
| Notifications: finish, fail, pause, lost connection, dedupe, permission, quiet hours, network settle, click | `PrintNotifyTests`, `GlanceModelTests` ("Notifications"), `ComingOffTests.testQuietHours…` |
| Finishing soon | `ComingOffTests`, `GlanceModelTests.testFinishingSoon…`, `…testLeadTime…` |
| Low filament and runout | `FilamentAlertTests`, `RunoutTrackerTests`, `GlanceModelTests.testLowFilament…`, `…testFallingSpool…`, `CardScreenTests.testRunoutLineUnderTheBar` |
| Error codes, reasons, lookup URLs | `PrepareAmsHmsTests`, `CardScreenTests.testPaused…`, `…testFailed`, `SecurityTests.testErrorLookupSendsOnlyTheModelPrefix`, `SecurityTests.testRandomErrorCodesNeverCrash` |
| History and CSV | `JobLogTests`, `GlanceModelTests.testFinishedPrintIsLogged…`, `…testExportWritesCSV`, `PanelScreenTests` (History), `LayoutTests.testHistoryScrollsInsteadOfGrowing` |
| Update check | `AppUpdateTests`, `UpdateCheckTests`, `SecurityTests.testUpdate…` |
| Panel sizing math | `MenuBarHugTests`, `LayoutTests` |
| Accessibility | Every `UI/` test via `assertReadsWell`; `CardScreenTests.testPrinterListRowsSayStateAndProgress` |
| README and Info.plist | `ShippingTests` |
| Hostile input | `SecurityTests` (fuzzing), `MQTTWireTests` (frames), `GlanceModelTests.testGarbageMessagesChangeNothing`, `PrepareAmsHmsTests.testHostileNumbersDoNotTrap`, Python `ActiveFilamentTests.test_garbage_shapes_do_not_raise` |

## What isn't automated

Run these by hand before a release, or when touching the area. Ask the owner before launching a build: it connects to their real printers, and the installed copy is running (`LSMultipleInstancesProhibited`). Never run `make install` without asking; it rewrites saved printers from `.env`. To try a build, quit the installed app (`osascript -e 'tell application id "local.PrintGlance" to quit'`), `make app`, and `open dist/PrintGlance.app`.

| Check | Why it can't be automated here |
|---|---|
| The menu bar item appears, sits right of the front app's menus, and opens the panel on click | `MenuBarExtra` needs a real status bar; `performClick` doesn't open a window-style extra on macOS 27, and computer-use tools can't target a menu-bar-only app. |
| The panel hugs the card: no clear band, shrinks when the card shrinks (e.g. close History), keeps its top-right corner | Only real clicks show the timing (a debug hook that opens the panel without making it key hid this bug once). |
| **More** menu: every item, Notifications submenu toggles persist, Lead Time disabled when Finishing Soon is off, version row, Quit | Opening the menu is modal. |
| Overflow **Edit…/Remove…** context menu on list rows, the Remove confirmation | Context menus and `NSAlert` are modal. |
| First launch: Add Printer window opens; Local Network prompt; notification prompt after Done; Open at Login (and Login Items approval) | System prompts and `SMAppService` need a signed app bundle. |
| A real print: progress, Starting stages with heaters, pause with a real HMS code and **Look up**, finish notification, Quiet Hours delay | Needs a printer; the fakes are modeled on captured reports. |
| Sleep and wake mid-print, Wi-Fi off/on (no Lost Connection notice from the Mac's own drop), printer moved to a new IP | Needs real power and network events. |
| The 20 s keep-alive ping and "ping timeout" | Too slow for the suite; the code path is small (`MQTT311Client.startPing`). |
| `PrinterDiscovery.scan` on a real Wi-Fi, including while Bambu Studio holds UDP 2021 | Real multicast sockets. |
| **Update available** and **Download PrintGlance x.y.z** | `GlanceModel.availableUpdate` is set only from `start()`. `UpdateCheckTests` covers the checker itself. |
| Gatekeeper on the downloaded zip, notarization | `release.yml` checks this for signed builds. |

To watch the running app from the shell without UI automation, a temporary `DistributedNotificationCenter` observer in `PrintGlanceApp.init` can run commands and write to `~/Library/Logs/PrintGlance.log`; remove it before committing. Mask serials and IPs when sharing the log.

## Findings from building this suite

Fixed in the same change, each with a test that fails without the fix:

- **A printer that reconnected during a rediscovery scan was redialed** a second later, dropping a healthy connection and flashing Connecting (`GlanceModelTests.testReconnectDuringTheSearchIsNotRedialed`).
- **VoiceOver read the setup window's text fields as just "text field"** (`SetupScreenTests`, via `assertReadsWell`).
- **A long printer name wrapped the finished/failed caption** onto several lines and grew the panel (`LayoutTests.testLongNamesTruncateInsteadOfGrowingTheCard`).

Open, for the owner to decide:

- **CSV formula injection** (low): `JobLog.csv()` quotes commas, quotes, and newlines but leaves cells starting with `=`, `+`, `-`, or `@` as they are. A job name crafted by someone who can send prints to the printer could run a formula when the export is opened in a spreadsheet. The usual fix prefixes such cells with `'`.
- **Unbounded MQTT frame buffer** (low): `MQTT311Client` waits for as many bytes as a frame's length field claims (up to 256 MB) before parsing. Only the printer, or something impersonating it (TLS trusts any certificate), can send that.
- **Python feed** (`bambu.py`, `print_loop.py`; left unchanged by policy):
  - A report with `Infinity` or a huge number in `mc_percent`, `mc_remaining_time`, `layer_num`, `remain`, or `tray_now` raises `OverflowError`; every `/print.json` request then fails until the printer overwrites the field.
  - Deeply nested JSON raises `RecursionError` in the MQTT callback, which kills paho's network thread; the feed then serves OFFLINE forever. Catching `Exception` in `_on_message_v2` (or `client.suppress_exceptions = True`) fixes it.
  - It listens on `0.0.0.0:8080` with no token by default, so anything on the LAN can read printer state and job names.
  - The token is compared with `==` (use `hmac.compare_digest`), idle HTTP/1.1 connections hold a thread with no timeout, and the `Server` header discloses the Python version.
  - `tray_now` across several AMS units is matched by slot id only, so AMS B's spools are read wrong (`test_tray_now_is_global_across_ams_units`, marked expected failure).
- Both the app and the feed strip only one file extension (`Benchy.gcode.3mf` shows as `Benchy.gcode`) and cut real sizes like "20mm" from job names as if they were layer heights.

## Adding a test

**A new report field or presentation rule.** Add a pure function to `BambuPrint` or `GlanceContent` and test it next to its neighbors (`PrepareAmsHmsTests`, `PrintDocTests`) with fixed `now`, `Calendar`, `Locale`. Then show it in a `CardScreenTests` case and, if it's new, add the state to `RenderStatesTests.detailStates()`.

**A connection or notification workflow.**

```swift
@MainActor
final class MyTests: XCTestCase {
    func testSomething() async throws {
        let h = ModelHarness(self)
        let link = try XCTUnwrap(h.add(.x2d()).first)
        link.accept()
        link.report(Report.running())
        link.report(Report.state("FINISH"))
        XCTAssertEqual(h.notifications.titles(), ["Print finishing soon", "Print finished"])
        link.drop("closed")
        let searched = await eventually { h.network.scans == 1 }
        XCTAssertTrue(searched)
    }
}
```

**A screen.**

```swift
@MainActor
func testPausedCard() throws {
    let s = try Screen(Rows.card(Rows.paused()))
    assertReadsWell(s)
    XCTAssertEqual(Array(s.texts.prefix(2)), ["Benchy", "Paused"])
    XCTAssertEqual(try s.control("Look up error 0700-2000-0002-0001").role, "AXLink")
}
```

**Bytes on the wire.** Use `FakeBroker` and `ClientEvents` in `MQTTWireTests`; `broker.send(...)` for what the printer says, `broker.packets(ofType:)` for what the app said.

**A README promise.** Add a `ShippingTests` case that checks both the README sentence and the constant or function behind it.

**The feed.** Add to `Tests/Feed/test_feed.py`; stdlib `unittest`, Python 3.9, `@unittest.skipUnless(bambu.mqtt is not None, …)` for anything that needs paho.
