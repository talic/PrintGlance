# P0: Attention and honesty

**Goal:** the menu bar and the print card answer "Does it need me?" and "When is it done?" correctly in every state and with several printers, and never show stale or misleading information. This phase is presentation, copy, and small model additions. No new windows.

**Size:** 11 tasks, one commit each. About half small, half medium.

**Start a session with:**

> Execute docs/plans/p0-attention-and-honesty.md end to end.

## 0. Before you start

1. `main` must contain `fix/review-hardening` (it splits `GlanceContent` out of the view, which this plan edits). If it isn't merged, ask the user whether to branch from `fix/review-hardening` instead.
2. Create `feat/p0-attention` from `main`.
3. Read in full: `Sources/PrintGlance/GlanceView.swift`, `GlanceContent.swift`, `GlanceModel.swift`, `BambuSnapshot.swift`, `PrintDoc.swift`, `PrintNotify.swift`, `JobLog.swift`, `ComingOff.swift`, `FilamentAlert.swift`, `README.md`, and the tests that cover them.
4. Run `make test` for a green baseline.
5. If the code differs from this plan (names, behavior), trust the code, adapt, and say so in the PR.
6. Tasks 7, 8 and 11 start with web research. They are independent of each other; run that research in parallel (for example with subagents) before writing their code. Cite sources in the PR.

## Ground rules

- Run tests with `make test`. Bare `swift test` fails on this Mac (CI runs `swift test` on GitHub, which is fine). Tests must not depend on the machine's locale, time zone, or clock: pass `Locale`, `Calendar`, and `now` explicitly.
- Never run `make install`. It kills the running app and rewrites saved printers from `.env`. `make app` is fine.
- Ask the user before launching a built app. It connects to their real printers, and the installed copy is already running (`LSMultipleInstancesProhibited`).
- Read-only promise: the app only ever publishes `pushall` to `device/<serial>/request`. Never send pause, stop, resume, print, or any other command.
- No requests to Bambu's servers from the app. Opening a Bambu web page in the user's browser when they click is fine.
- No new dependencies. The package has none.
- Keep `Printer`, `PrintDoc` and `AMSTray` `Codable`. Only add optional fields with `= nil` defaults; the JSON fixtures pin the Python feed's format. Don't touch `bambu.py`, `print_loop.*`, `.env*`, or launchd.
- Load-bearing macOS workarounds: `PinMenuBarExtra` (PrintGlanceApp.swift), `HugMenuBarPanel` / `HugWindowView` (PrintGlancePanel.swift), the "do not `.id(strip)`" comment, and the "keep `failed` through retries" comment in `GlanceModel.beginConnect`. Don't restructure them. Changing the strip's image name or title text is fine.
- Presentation decisions go in pure `static` functions on `GlanceContent` (payload parsing on `BambuPrint`), each with XCTest coverage. Views stay thin.
- Copy: English only, short plain sentences. Menu items use title case ("Add Printer…"); everything else uses sentence case. Follow the vocabulary below.
- Commit after each task with the repo's style: `type: short imperative summary`, lower case (`fix:`, `feat:`, `refactor:`, `test:`, `docs:`). Don't bump the version.
- Scope is the tasks below. Note anything else you find under "Found, not fixed" in the PR.

## Vocabulary

| Idea | Use |
|---|---|
| States | Starting, Printing, Paused, Finished, Failed, Idle, Offline |
| No connection at all | Can't reach printer |
| AMS slots | A1…D4 (unit letter + slot 1–4); external spool: External |
| Error codes | Error 0700-2000-0002-0001 |

"Done" and "feed" disappear from the UI.

## Decisions already made

1. **Menu bar ranking with several printers:** Paused, then Printing/Starting (the focused one if it's printing, otherwise the one finishing soonest), then Failed, then Finished, then the focused printer, then the first. This refines the review: Failed doesn't take over the menu bar while another printer is printing, because the failure notification already alerted the user and live progress is more useful.
2. **The card opens on the printer the menu bar shows.** Clicking a printer in the list changes the card for that visit only.
3. **Pause alerts are on by default**, and existing installs get them turned on once.
4. **The word is "Finished"**, not "Done".
5. **The menu bar drops "40m ago" after 2 hours**; the checkmark stays.
6. **Error codes link to Bambu's page for that code.** Plain-language reasons come in P2.
7. **The version moves into the … menu**, off every screen.
8. **Starting stages are shortened in the menu bar** (Loading, Unloading, Cleaning). The card keeps the full words.

## Tasks

### 1. Render harness and a data-driven card (M)

There are about ten card states and no previews. You need to see them without a printer in each state.

- Move the card's per-printer body out of `GlanceView` into an internal view that takes plain values, for example `PrinterDetail(row: Printer, endedAt: Date?, now: Date, disconnectReason: String?)`. That covers `printerBody`, `heroText`, `amsBlock`, `amsLine`, `metaRow`, `FilamentDot`, and `CapsuleBar`. `GlanceView` passes model values in. It can stay in `GlanceView.swift`. Make `HistoryView` internal too. No visual change in this task.
- Add `Tests/PrintGlanceTests/RenderStatesTests.swift`. It calls `XCTSkip` unless the env var `PG_RENDER_DIR` is set. When set, it writes 2x PNGs, light and dark, on an opaque window-background color, of:
  - `PrinterDetail`: Printing (single nozzle; dual nozzle "Left"), Starting (Heating), Paused (with error code; without), Failed (with code), Finished (40m ago; unknown time; 2 days ago), Idle (one AMS; two AMS plus External), Offline (was printing; was idle).
  - `StripLabel` for each strip state.
  - Add `HistoryView` and the multi-printer list as later tasks touch them.
- Use `NSHostingView` plus `cacheDisplay(in:to:)` (it renders AppKit-backed controls), or `ImageRenderer`, whichever works under `swift test`.
- Run `PG_RENDER_DIR=<scratch dir> make test`, then open every PNG. Re-render after each later task and look at the affected images before committing.

Accept: renders are legible in both appearances, plain `make test` skips the test, and the app looks unchanged.
Commit: `refactor: render card states without a printer`

### 2. Words, contrast, and the … menu (S)

- `GlanceContent.humanState("FINISH")` returns "Finished". The History caption says "Finished" instead of "Done".
- `.feedDown` headline "Can't update" becomes "Can't reach printer". The strip's accessibility label "Print feed off" becomes "Can't reach printer". The `.doc`-with-no-printer copy ("The feed has no printer.") becomes "No printer".
- Data text (layer, filament, AMS lines, humidity, printer-name captions) uses `.secondary`. Nothing that carries data stays `.tertiary`.
- Remove `VersionLine` from the card, History, and the printer form, and delete the struct.
- Restructure the … menu:

  ```
  Add Printer…                 (only when fewer than 4 printers)
  Edit <card printer name>…
  ─
  History
  Notifications ▸
      Print Paused
      Print Failed
      Print Finished
      Print Finishing Soon
      Printer Went Offline
      ─
      Quiet Hours
  Open at Login
  ─
  PrintGlance 1.1.14           (disabled; the bundled version)
  Download PrintGlance 1.2.0   (only when an update is available)
  ─
  Quit PrintGlance             ⌘Q
  ```

  Until Task 9, "Edit" targets the same printer the current focus logic picks.
- Keep the card's "Update available" button.
- Update the string assertions in tests, and the README's menu names and its sentence about where the version appears.

Commit: `fix: use one word per state and tidy the menu`

### 3. Times in the user's 12- or 24-hour format (S)

- `BambuPrint.etaHM` hard-codes `HH:mm` with `en_US_POSIX`, so 12-hour users see "16:25". Format the time with the locale's hour cycle (`Date.FormatStyle` time `.shortened`, or the `jmm` template). Inject `locale` (default `.autoupdatingCurrent`) next to `calendar` so tests stay deterministic.
- Add one helper, for example `GlanceContent.dayTime(_ date:, now:, calendar:, locale:)`, returning "16:25", "16:25 tomorrow", "16:25 yesterday", "16:25 Mon" (within 6 days either side), or a short date ("Sep 12") beyond that. Day words stay English. ETA uses it now; Tasks 6 and 10 reuse it.
- `formatRemain` at 24 hours or more returns "1d 2h" instead of "26h 05m". This affects remaining time and "ago".
- Tests: en_GB and en_US cases; update `testEtaQualifiesFinishDay`. Newer ICU puts U+202F (narrow no-break space) before AM/PM. Assert against the real formatter output, not a hand-typed space.

Commit: `fix: show times in the user's 12- or 24-hour format`

### 4. Menu bar rules (S)

`GlanceContent.strip(row:)`:

| State | Image | Title |
|---|---|---|
| Starting | `printer.fill` | Short stage: Heating, Leveling, Loading, Unloading, Calibrating, Cleaning, Homing, Starting |
| Printing | `printer.fill` | `52%  4:25 PM` (unchanged), but pad the percent with figure spaces (U+2007), not spaces |
| Paused | `pause.fill` | `52%` |
| Finished | `checkmark` | `40m ago` for the first 2 hours, then empty |
| Failed | `xmark` | empty |
| Idle | `printer` | empty |
| Offline | `printer.slash` (was `printer`, same as Idle) | empty |

- The accessibility label for Paused must not include a finish time. Finished keeps the full "finished 3h 10m ago" in its label even after the visible title drops.
- Tahoe risk: `beginConnect`'s comment says swapping the extra's label can make the icon flash off on macOS 26, and Offline now changes the image. The 30-second offline grace in `BambuSnapshot` damps flapping. If the user lets you run the build, watch one offline-to-online transition. If the icon vanishes, keep `printer` for Offline and record that in the PR.
- Tests: update `testPercentPaddingStableWidth` and `testPauseAndFinishAndFailedStrip`; add offline, finished-collapse, and short-stage cases.

Commit: `fix: menu bar shows offline and drops a stale finish time`

### 5. Card rules per state (M)

Put each rule in a `GlanceContent` function; `PrinterDetail` only renders them.

- **Headline:** the job name for Starting, Printing, Paused, Finished and Failed (and for Offline when the last known state was one of those). The printer name for Idle; today the idle card shows the previous job's name.
- **Hero:**
  - Starting/Printing: the finish time with "1h 24m left" below (unchanged).
  - Paused: "1h 24m left" and no finish time, because the finish time keeps sliding later while paused. No hero when the remaining time is unknown.
  - Finished: "40m ago" when known. Nothing when unknown, so "Finished" doesn't show twice.
  - Failed and Idle: no hero.
- **AMS block** shows for Idle, Finished, Failed, and Paused. A paused runout means you need to see the trays.
- The progress bar is unchanged (orange when Paused, red when Failed).
- Tests for each rule.

Commit: `fix: paused card shows time left and idle card names the printer`

### 6. Offline keeps the last known state (M)

Today a printer that drops off the network (often because the laptop left home) shows only "Can't reach the printer". The print is probably still running.

- `BambuSnapshot`: record `lastReportAt` in `ingest`.
- `Printer`: add `lastSeen: Date? = nil` and `lastState: String? = nil`. `BambuPrint.row` sets them only when the printer is offline and a report exists, so equality doesn't change on every message while online.
- Offline card:
  - Headline per Task 5; subtitle "Offline".
  - "Last update 14:02" (using `dayTime`).
  - If the last state was Printing or Starting: "Was printing · 52% · Layer 18/29", then "Expected to finish 16:25" (`lastSeen + remainingS`), or "Was due to finish 16:25" if that time has passed.
  - If the last state was Paused: "Was paused at 52%".
  - Then the existing `GlanceCopy.feedDownDetail` text, in smaller type.
- Strip accessibility label: "X2D, offline, last update 14:02".
- Don't change `PrintNotify`, `JobLog`, or `ComingOff` behavior.
- Tests: offline rows carry `lastSeen` and `lastState`; online rows don't; the expected-finish math; the past-due wording.

Commit: `feat: keep the last known progress while a printer is offline`

### 7. Why it stopped (M)

**Research first:**
- What `print_error` holds (an integer, 0 when there's no error) and how Bambu Studio formats it for display.
- Which page Bambu Studio and Bambu Handy open for an HMS code and for a `print_error` code. Bambu Studio is open source (github.com/bambulab/BambuStudio); find its HMS link builder and use the same URL pattern. If there's no stable per-code URL, open Bambu's HMS search page and copy the code to the clipboard.

**Then:**
- Add `Printer.printError: String? = nil`, parsed in `BambuPrint.row` (non-zero only). `hmsCode` already exists.
- Paused and Failed cards only: an "Error <code>" line with a **Look up** link button. Show the HMS code first, then `print_error` if it's different; at most two lines. With no code, show "No error reported." Codes are shown only in these two states, because `print_error` can stay set after the problem is gone.
- Paused and Failed notification bodies end with " · Error <code>", replacing today's " · HMS <code>".
- Pause notifications on by default: `PrintNotifyPrefs.default.pause = true`, load fallback `true`, plus a one-time migration (key `pg.notify.pauseOn.v1`) that turns pause on for existing installs. Prefs are saved as a block, so a deliberate "off" can't be told apart from the old default; accept that and say so in the PR.
- Tests: parsing, formatting, the URL builder, notification bodies, and the migration (use a scratch `UserDefaults(suiteName:)`).
- README: notification defaults, and the Paused and Failed rows of the state table.

Commit: `feat: show the error code when a print pauses or fails`

### 8. AMS block (M)

**Research first:** the direction of the AMS humidity index (is 1 or 5 the dry end?) and whether newer firmware sends a percent (for example `humidity_raw`); how Bambu Studio labels AMS HT units; whether dual-nozzle printers send two external spools (for example `vir_slot`). Bambu Studio's source is the primary reference.

**Then:**
- Slot labels match the printer screen: unit 0 → A, 1 → B, and so on, slots 1–4: "A1"…"D4". AMS HT units (ids 128 and up, one slot each) get Bambu's label per your research (fallback "HT1", "HT2"). The external spool is "External". Today's "Slot 0" and the id `512` produced by `uid * 4 + tid` for HT units go away. Add `label: String? = nil` to `AMSTray`.
- Group trays under a unit header ("AMS A · Dry" or "AMS A · 23%") when there's more than one unit or humidity is known. Read humidity per unit; today only the first unit is read. Keep `Printer.humidity` for feed compatibility and add new optional fields.
- Humidity text: the percent when sent. Otherwise a word (Dry / OK / Humid) once the direction is confirmed from a primary source. If you can't confirm it, keep "Humidity n/5" and say so in the PR.
- External spools: list every one the payload has. If that needs a real payload, see "Real payloads" below, or skip with a note.
- Tests: labels for one AMS, two AMS, HT, and External; the humidity mapping.

Commit: `fix: name AMS slots like the printer and show humidity per unit`

### 9. The menu bar shows the printer that needs you (M)

- Replace `PrintDoc.focusRow()` with `displayRow()` using the ranking in Decision 1. Ties go to saved order; nil `remainingS` sorts last.
- The menu bar and the card both start from `displayRow`. Clicking a printer in the list shows it in the card (view-local `selectedId`) and still saves it as focus, which now only breaks ties.
- Each time the panel opens, clear `selectedId` and leave History, so the card matches the menu bar. To detect "panel opened", add a small `NSViewRepresentable` that observes `NSWindow.didBecomeKeyNotification` for its own window. Don't modify `HugWindowView`'s frame logic. Confirm with a temporary log line that it fires once per open, then remove the line. Don't reset while the in-panel printer form is open.
- Anything the card needs must be looked up per serial, not per focus: `occupancyEndedAt(for:)`, `disconnectReason(for:)`. "Edit …" targets the card's printer.
- One printer: no change in behavior.
- Tests: the ranking as a table, including ties; focused-and-printing beats finishing-soonest; Paused beats focused; Failed doesn't beat Printing. Replace `testFocusPrefersRunningThenPauseThenFirst`.
- README: rewrite "Watch more than one printer".

Commit: `feat: menu bar shows the printer that needs you`

### 10. History you can read (S)

- Scrollable, at most about 360 pt tall, showing every stored row (the cap is 50; today only 20 show), newest first.
- Row: job name (or printer name) as the title. Caption like "14:02 yesterday · 4h 43m · Finished", using `dayTime` and `formatRemain`. Failed in red. Include the printer name only when the rows come from more than one printer.
- Header: a back chevron on the left with "History", and Export CSV on the right. Esc goes back (`onExitCommand`). Remove the bottom Back button.
- Add History to the render harness.
- Tests: the caption builder.
- README: the History section.

Commit: `fix: history scrolls and shows when each print ran`

### 11. Connection advice and the README (S)

**Research first:** which printer settings must be on for local MQTT on port 8883, by model family and current firmware (LAN Only Mode, Developer Mode, and Bambu's 2025 authorization changes).

**Then:**
- Rewrite the `ECONNREFUSED` text in `GlanceCopy.feedDownDetail` to name exactly what to turn on. If LAN Only Mode turns off Bambu Handy and cloud features, say so. If sources disagree, keep the current text and flag it in the PR. Update `testFeedDownDetailTokens`.
- Do a full README pass: every UI string matches the app, the state table matches the new behavior, and the "If it cannot connect" list matches the new advice.
- `docs/menu-bar.png` and `docs/print-card.png` are now out of date. Don't fake them. List them under "Needs the user".

Commit: `docs: match the readme to the app`

## Real payloads (optional; ask first)

Field names for `print_error`, HMS, humidity, and external spools vary by model and firmware. If you need a real report, ask the user before capturing one:
- Use a one-off read-only MQTT client with a unique client id (`pg-dump-<random>`).
- Subscribe to `device/<serial>/report`, publish `pushall`, save the first full report to the scratchpad, then disconnect.
- Take credentials from the app's saved settings (`defaults read local.PrintGlance printers`). Never print the access code in chat.
- Scrub serial, IP, SSID, and task ids before using any of it as a test fixture.

## Done when

- [ ] Tasks 1–11 committed, or deferred with a reason in the PR.
- [ ] `make test` green and `make app` builds.
- [ ] Every render viewed in light and dark after the final task.
- [ ] README matches the app.
- [ ] Branch pushed and a PR opened to `main` (not merged). The PR body covers: what changed per task, research sources, "Needs the user" (Tahoe icon check, panel-open reset on the real app, README screenshots), and "Found, not fixed".

## Not in this phase

- **P1:** the setup window and flow, the printer list's visual redesign, notification permission state, offline alert wording, the Low Filament toggle, the Quiet Hours label.
- **P2:** notarization, temperatures, notification click-through, lead time, plain-language error text, camera.
