# P1: Setup and several printers

**Goal:** a first run that works without reading the README, a setup flow that proves the printer connects before it says "done", a printer list you can scan at a glance, and notifications that say when they can't reach you.

**Size:** 7 tasks, one commit each. Mostly medium.

**Start a session with:**

> Execute docs/plans/p1-setup-and-printers.md end to end.

## 0. Before you start

1. P0 (`docs/plans/p0-attention-and-honesty.md`) must be merged into `main`. This plan builds on its render harness (`RenderStatesTests`, `PG_RENDER_DIR`), `PrinterDetail`, `displayRow()`, the panel-open reset, and the vocabulary. If P0 isn't merged, stop and ask.
2. Create `feat/p1-setup` from `main`.
3. Read in full: `GlanceView.swift`, `PrinterSettingsView.swift`, `GlanceModel.swift`, `PrinterSettings.swift`, `PrinterDiscovery.swift`, `PrintGlanceApp.swift`, `PrintNotify.swift`, `FilamentAlert.swift`, `ComingOff.swift`, `LoginItem.swift`, `README.md`, and their tests.
4. Run `make test` for a green baseline.
5. If the code differs from this plan, trust the code, adapt, and say so in the PR.

## Ground rules

- `make test` for tests (bare `swift test` fails on this Mac). Keep tests independent of locale, time zone, and clock.
- Never `make install`. Ask before launching a built app: it connects to the user's real printers, and the installed copy is running.
- The app only publishes `pushall`. Never send printer commands. No requests to Bambu's servers from the app.
- No new dependencies. `Network` (for `NWPathMonitor`) and `ServiceManagement` are system frameworks, so they're fine.
- `Printer`, `PrintDoc`, `AMSTray` stay `Codable`; only add optional fields. Don't touch the Python feed, `.env*`, or launchd.
- Don't restructure `PinMenuBarExtra`, `HugMenuBarPanel` / `HugWindowView`, or the retry logic around `link.failed` in `GlanceModel`.
- Presentation and decision logic go in pure functions with XCTest coverage. Views stay thin.
- Menu items use title case; everything else uses sentence case. Use P0's vocabulary.
- Request notification permission only through the existing pattern in `GlanceModel.deliver` (`Task { try? await …requestAuthorization }`). A `@MainActor` completion closure traps.
- Commit after each task (`feat:`, `fix:`, `refactor:`, `docs:`, lower case). Don't bump the version. Note out-of-scope findings under "Found, not fixed".

## Decisions already made

1. **Printer setup and editing move out of the popover into a small window.** The popover closes when you click elsewhere, and people walk to the printer to read the access code. The form also makes the panel jump width, and first launch has nothing to show. The popover keeps the card, the printer list, and History.
2. **First launch with no printer opens the setup window.** Reopening the app from Finder while no printer is set opens it too.
3. **Discovery first.** Pick a found printer, then type only the access code. IP and serial sit behind "Enter IP and serial instead".
4. **Connect saves the printer, then waits for the real connection.** The window shows the result. Cancel always restores the printers as they were when the window opened, so a failed Add leaves nothing behind.
5. **The access code is shown as typed**, not masked. It's copied by hand from the printer's screen, and masking only causes typos.
6. **With two or more printers, the card shows the selected printer's detail first, with the list of all printers below it.** This changes the review's "list on top": the top of the card stays the same for one printer or many, and it matches the menu bar.
7. **Remove works for the last printer too** (with a confirmation). The app goes back to the setup state.
8. **Open at Login is offered once, after the first successful setup.** The toggle starts on and applies when the user clicks Done.
9. **Notification permission is requested when the first setup finishes.** First-print asking stays for existing installs.
10. **Quiet Hours stay, and the label shows the hours.** Alternative: remove them. If the user wants that, they'll say so before you start.

## Tasks

### 1. Publish per-printer link status (S)

- In `GlanceModel`, add `@Published private(set) var linkStatus: [String: LinkStatus]`, where `enum LinkStatus: Equatable { case connecting, connected, failed(reason: String?) }`.
- Set it in `beginConnect`, `didConnect`, the connect timeout, and `didDisconnect`. Clear entries for removed printers.
- Keep it independent of `content` and `link.failed`, so the Tahoe-sensitive retry path is untouched.

Commit: `feat: publish connection status per printer`

### 2. Setup window (M)

- Add `SetupWindow.show(model:mode:)` with `mode` either `.add` or `.edit(serial:)`:
  - One reusable AppKit `NSWindow` hosting SwiftUI via `NSHostingController`: titled, closable, not resizable, centered, `isReleasedWhenClosed = false`.
  - Call `NSApp.activate()` so it comes in front of other apps (this is an `LSUIElement` app).
  - Title "Add Printer" or "Edit <name>". Esc and ⌘W act like Cancel.
- Open it on launch when `!settings.isComplete`: from `PrintGlanceApp.init` after `model.start()`, on the next run-loop turn.
- Add an `NSApplicationDelegateAdaptor` whose `applicationShouldHandleReopen` opens the window in add mode when no printer is set, and otherwise does nothing.
- Changes in the popover:
  - Remove the in-panel form: `showPrinter`, `draft`, `editingSerial`, and the `.onAppear` auto-open.
  - "Add Printer…" and "Edit …" open the window.
  - Empty states: no printer shows "Add your printer" with an **Add Printer** button. A rejected access code shows an **Update Access Code…** button that opens edit mode for that printer.
- Keep `model.setRediscoverPausedSerial`: set it when edit mode opens, clear it when the window closes.
- Verify:
  - The window doesn't open on a normal launch with a printer saved.
  - It comes to the front.
  - Closing it doesn't quit the app.
  - The panel no longer changes width.

Commit: `feat: set up printers in a window`

### 3. Discovery-first form (M)

Replace `PrinterSettingsView` with the new form; delete the old file if nothing uses it.

- Width about 360 pt. One line of help: "Pick your printer, then enter its access code. On the printer, open Settings, then LAN or Network." Match the README's wording for the printer menus.
- **Found printers:**
  - Scan on open. Show "Searching…" with a spinner, then a **Search Again** button.
  - Each row: model name, printer name, IP. Map `Hit.model` (SSDP `DevModel.bambu.com`) to the marketing name; research the codes (for example Bambu Studio's printer profiles, or ha-bambulab). Unknown codes show as-is.
  - The selected row shows a checkmark.
  - In add mode, printers already saved show "Added" and can't be picked. Match serials case-insensitively, like `PrinterDiscovery.ipChanges`.
- **"Enter IP and serial instead"** disclosure. It opens automatically when nothing is found, and in edit mode.
- **Access code:** a plain `TextField` in monospaced type, trimmed. If the code isn't 8 characters, show a soft hint ("Access codes are usually 8 characters."). Confirm the length from Bambu's docs first, and drop the hint if it isn't reliable.
- **Name** (optional), prefilled from discovery.
- **Buttons:** Remove… (edit mode, with confirmation), Cancel, and **Connect** in add mode or **Save** in edit mode as the default button.
- Render the form states in the harness: searching, found (with an "Added" row), nothing found, and manual entry.
- Tests: model-name mapping, "Added" matching, the access-code hint.

Commit: `feat: pick a found printer and enter only the access code`

### 4. Connect and confirm (M)

- On Connect or Save: capture the current `SavedPrinters`, save the new settings, then show "Connecting to <name>…" with a spinner, watching `linkStatus[serial]`.
- **Connected:** show a ✓ with "Connected".
  - If this is the first printer ever, show a success step instead of closing:
    - Text: "PrintGlance is in your menu bar. Click it to see your print."
    - An **Open at login** toggle, starting on.
    - A **Done** button that applies the toggle with `LoginItem.setEnabled`. If `SMAppService` reports `.requiresApproval`, show "Allow PrintGlance in System Settings > General > Login Items" with a button that calls `SMAppService.openSystemSettingsLoginItems()`. Done then requests notification permission and closes.
  - Otherwise close after about 1 second.
- **Failed:** show the error inline and keep the form editable, with a **Try Again** button.
  - Access code rejected: "The access code was rejected. Check it on the printer: Settings, then LAN or Network."
  - Connection refused: P0's LAN-mode text.
  - Timed out: "No answer from <IP>. Check that the printer is on and on the same Wi-Fi as this Mac."
  - Stop waiting after about 20 seconds and show the timed-out message. Links retry with backoff, so don't wait forever.
  - Auto-rediscovery can adopt a new IP while you wait. A success after that is fine.
- **Cancel** restores the captured `SavedPrinters` (Decision 4).
- `applySettingsAndConnect` reconnects every printer on any save. Leave that alone and mention it in the PR.
- Render: connecting, connected, the first-run success step, and each failure.
- Tests: a pure function from `LinkStatus` plus the IP to the message.

Commit: `feat: confirm the printer connects before closing setup`

### 5. Printer list for two or more printers (M)

- Order: the card's header and detail (P0 rules), then a divider, then every printer as a row, in saved order so rows don't jump.
- Row: a status symbol (orange when Paused, red when Failed; otherwise neutral), the name, and on the right "52% · 4:25 PM" when printing, or the state word.
- The card's printer gets a subtle background plus `.accessibilityAddTraits(.isSelected)`. Clicking a row selects it (P0 behavior).
- Each row has a context menu: Edit…, Remove… (with confirmation).
- The accessibility label includes the finish time when printing.
- Render three printers (printing, paused, idle) in light and dark.
- README: "Watch more than one printer".

Commit: `feat: printer list shows every printer's progress at a glance`

### 6. Notifications (M)

- **Permission state:** read `UNUserNotificationCenter.current().notificationSettings()` at start and each time the panel opens. If denied, the Notifications submenu starts with "Notifications Are Off…", which opens System Settings at Notifications for PrintGlance. Research the URL on macOS 14, 15, and 26 (for example `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.PrintGlance`). The toggles stay usable.
- **Offline alert:**
  - Menu label "Lost Connection".
  - Title "Lost connection to <name>". Body "<job> was at 52%. PrintGlance keeps trying." (just the name when there's no job).
  - Don't send it when this Mac has no network, or its network changed in the last 2 minutes (`NWPathMonitor`). Put that decision in a pure function with tests.
- **Low Filament toggle:** default on, key `pg.notify.lowFilament`. It gates `FilamentAlert` delivery.
- **Quiet Hours label:** "Quiet Hours (10 PM–7 AM)", built from `QuietHours.startHour` / `endHour` in the user's hour format. If the user chose removal instead, delete the pref, `QuietHours`, the quiet path in `ComingOff`, `finishTrigger`, and their tests and README lines.
- Tests: the offline suppression rule, Low Filament gating, prefs load and save with the new key.

Commit: `feat: say when notifications are off and skip offline alerts this Mac caused`

### 7. README (S)

- Rewrite "Install" step 6 and "Connect to your printer" around the setup window.
- Update the notifications list and defaults, and the multi-printer section.
- Every UI string must match the app.

Commit: `docs: describe the setup window and printer list`

## Needs the user

- **Live first-run test:** this requires no saved printers. Only with the user's OK:
  1. Quit PrintGlance.
  2. `defaults export local.PrintGlance <scratchpad>/backup.plist`.
  3. `defaults delete local.PrintGlance`.
  4. Run `dist/PrintGlance.app` and go through setup.
  5. Quit, then `defaults import local.PrintGlance <scratchpad>/backup.plist`.
  6. Confirm `defaults read local.PrintGlance printers` shows their printers again before you finish. Never leave their settings deleted.
- Seeing the window come to the front, and checking the login-item approval path, on their macOS.

## Done when

- [ ] Tasks 1–7 committed, or deferred with a reason.
- [ ] `make test` green and `make app` builds.
- [ ] Every new render viewed in light and dark.
- [ ] Branch pushed and a PR opened to `main` (not merged), with what changed, research sources, "Needs the user", and "Found, not fixed".

## Not in this phase

- **P2:** notarization, temperatures, notification click-through, lead time, plain-language error text, camera.
- Reconnecting only the printer that changed, instead of all of them.
