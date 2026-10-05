# P2: Distribution and depth

> **Done.** Shipped in [#57](https://github.com/talic/PrintGlance/pull/57). Kept as a record of the scope and the decisions behind it. Don't execute it again; the code has moved on. Still open from Task 1: the signing secrets don't exist yet, so releases ship ad-hoc (the `ponytail:` fallback in `release.yml`) and the README keeps its "Open Anyway" steps.

**Goal:** remove the Gatekeeper steps from every install and update, and add the details that make a glance enough: temperatures while heating, plain-language reasons, notifications that lead somewhere, and a decision on a camera view.

**Size:** 7 tasks. Task 1 needs the user's Apple Developer account. Task 6 is a research spike with no shipped UI.

**Start a session with:**

> Execute docs/plans/p2-distribution-and-depth.md end to end.

## 0. Before you start

1. P0 and P1 must be merged into `main`. This plan uses P0's render harness, `displayRow()`, the panel-open reset, and the "Error <code> · Look up" block, plus P1's link status and setup window. If either isn't merged, stop and ask.
2. Create `feat/p2-depth` from `main`.
3. Read in full: `Makefile`, `.github/workflows/release.yml` and `test.yml`, `Info.plist`, `AppUpdate.swift`, `BambuSnapshot.swift`, `GlanceContent.swift`, `GlanceView.swift`, `GlanceModel.swift`, `ComingOff.swift`, `PrintNotify.swift`, `README.md`, and their tests.
4. Run `make test` for a green baseline.
5. If the code differs from this plan, trust the code, adapt, and say so in the PR.
6. Do Task 1 first, so the user can work on the account steps while you do the rest. Tasks 2–6 are independent.
7. Tasks 1 and 6 may already have run early, in parallel with P0. If `main` already signs with `SIGN_ID` and notarizes, only do Task 1's README part. If `docs/plans/camera-spike.md` exists, start Task 6 from it instead of redoing the research.

## Ground rules

- `make test` for tests (bare `swift test` fails on this Mac). Keep tests independent of locale, time zone, and clock.
- Never `make install`. Ask before launching a built app: it connects to the user's real printers, and the installed copy is running.
- The app only publishes `pushall`. Never send printer commands. No requests to Bambu's servers from the app; opening a page in the user's browser on click is fine.
- No new dependencies.
- `Printer`, `PrintDoc`, `AMSTray` stay `Codable`; only add optional fields. Don't touch the Python feed, `.env*`, or launchd.
- Don't restructure `PinMenuBarExtra`, `HugMenuBarPanel` / `HugWindowView`, or the retry logic around `link.failed`.
- Never ask for, print, or commit secrets: certificates, passwords, API keys, access codes.
- Logic goes in pure functions with XCTest coverage. Use P0's vocabulary and casing.
- Commit after each task (`feat:`, `fix:`, `build:`, `docs:`, lower case). Don't bump the version. Note out-of-scope findings under "Found, not fixed".

## Decisions already made

1. **Notarize with a Developer ID.** No Sparkle and no Homebrew cask in this phase; a cask is an easy follow-up once releases are notarized.
2. **The bundle id stays `local.PrintGlance`.** Changing it would drop everyone's saved printers.
3. **Camera is a spike only**: a written go/no-go, no shipped UI.
4. **Plain-language reasons cover a short curated list of common codes, in our own words.** Every other code keeps "Error <code> · Look up".
5. **Clicking a notification selects that printer for the next panel open.** Opening the panel from code happens only if a reliable method exists on the user's macOS (time-boxed).
6. **"Print finishing soon" lead time choices: 5, 10, 15, or 30 minutes.** Default 10.

## Tasks

### 1. Notarized releases (M; needs the user)

**The user does these** (write them as a checklist in the PR; never ask for the values in chat):
1. Join the Apple Developer Program.
2. Create a "Developer ID Application" certificate and export it as `.p12`.
3. Create an App Store Connect API key (Key ID, Issuer ID, `.p8` file).
4. Add GitHub secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_P8_BASE64`.

**You do:**
- **Makefile:**
  - `make app` stays ad-hoc signed by default.
  - Add `SIGN_ID ?= -`. When it isn't `-`, sign with `--options runtime --timestamp`.
  - Add a `notarize` target: zip with `ditto -c -k --keepParent`, run `xcrun notarytool submit … --wait` (a keychain profile via `NOTARY_PROFILE` locally, or API key flags in CI), `xcrun stapler staple` the app, then re-zip.
  - Check that the hardened runtime needs no entitlements: the app isn't sandboxed, and it uses TLS client sockets, UDP multicast for discovery, notifications, and `SMAppService`. Confirm by running the signed build, with the user's OK.
- **release.yml:**
  - Import the certificate into a temporary keychain, build signed, notarize, staple, zip, verify with `spctl -a -vv`, then attach to the release.
  - Add a `workflow_dispatch` trigger that does everything except attaching, and uploads the zip as a workflow artifact, so the setup can be tested without a tag.
  - Keep the tag/version check and the test step.
- **Update button:** read the `PrintGlance.zip` asset's `browser_download_url` from the release JSON that `AppUpdateChecker` already fetches. Open that, falling back to the release page.
- **Risks to check and note in the PR:**
  - macOS may ask once more for Local Network access and Login Item approval after the signature changes.
  - Users upgrading straight from 1.1.7 may get a Keychain prompt from `AccessCodeStore`.
- **README:** "Install" and "Update" drop the "Open Anyway" steps. That text must ship together with the first notarized release, so tell the user to tag right after merging, or keep the old steps until then. Ask which they prefer.
- Tests: zip-URL parsing in `AppUpdateTests`.

Commit: `build: sign and notarize release builds`

### 2. Temperatures while starting (S)

- Parse `nozzle_temper`, `nozzle_target_temper`, `bed_temper`, `bed_target_temper`, and `chamber_temper` when present.
- Dual-nozzle printers may report per-nozzle temperatures under `device.extruder.info[]`, possibly packed. Verify with a real payload: use P0's "Real payloads" procedure, ask first, and scrub before saving fixtures.
- Add optional fields to `Printer`, filled only while Starting. That keeps `content` from changing on every report during printing.
- Starting card: "Nozzle 186 / 220°  ·  Bed 48 / 60°", showing only the active nozzle on dual-nozzle printers. Use Celsius as the printer reports it.
- Render and test.

Commit: `feat: show heating progress while a print starts`

### 3. Notification click-through (S)

- Put the printer's serial in each notification's `userInfo`. Implement `didReceive` in `PrintNotifyPresenter` to store a pending selection on the model. P0's panel-open reset then uses the pending selection (once) instead of clearing it.
- Time-box 1 hour: see whether the menu bar panel can be opened from code reliably on the user's macOS, for example by finding the status item's button and calling `performClick`. Ship it only if it works across repeated tries and doesn't break the Tahoe workarounds; otherwise leave it out and record what you found.
- Tests: the pending selection is consumed exactly once.

Commit: `feat: clicking a notification shows that printer`

### 4. "Print finishing soon" lead time (S)

- Make `ComingOff.windowS` a preference: 5, 10, 15, or 30 minutes, default 10, with a new key.
- Add a picker under "Print Finishing Soon" in the Notifications submenu.
- The body reads "About N minutes left." `jumpS` and the Quiet Hours logic stay as they are.
- Tests in `ComingOffTests`: each lead time, plus changing the value while a notice is scheduled (reschedule once, no duplicates).

Commit: `feat: choose how early "finishing soon" arrives`

### 5. Plain-language reasons for common errors (M)

- Build a small table (20–30 entries) of the most common pause and failure codes:
  - filament runout (AMS and external)
  - AMS feed and cutter errors
  - nozzle clog
  - first-layer inspection
  - spaghetti detection
  - purge chute pile-up
  - build plate missing or mismatched
  - door or cover open
  - heater and temperature faults
- Sources: Bambu's wiki page per code (the primary source). ha-bambulab's code tables are useful as a cross-check; respect its license and don't copy wording. Write short sentences in our own words.
- Where a code encodes the AMS unit and slot, name it ("AMS A, slot 2") using P0's slot labels. Research the bit layout before relying on it.
- Card: the reason line goes above "Error <code> · Look up". Notifications: the reason starts the body.
- Unknown codes behave exactly as today.
- Tests: table lookups, slot decoding, fallback.

Commit: `feat: explain common pause and failure codes`

### 6. Camera spike (M; no UI)

- Ask the user which printer models they own. The repo's `.env.example` and fixtures name an X2D.
- Find out, with sources:
  - How each relevant family exposes its camera on the LAN. Reportedly the P1 and A1 families use TLS on port 6000 with JPEG frames, and the X1 and H2 families use RTSPS on port 322. Verify, and cover the user's models.
  - Which printer settings it needs (LAN-mode live view, Developer Mode).
  - Whether one still frame can be fetched without new dependencies. AVFoundation doesn't play RTSP, so RTSP would mean writing RTP/H.264 depacketizing plus VideoToolbox decoding.
  - Cost: connection limits on the printer, CPU, battery, and interaction with the app's MQTT session.
- A throwaway prototype in the scratchpad is fine. Don't commit it.
- Deliverable: a section in the PR with a recommendation: build for all models, build for JPEG models only, or don't build. Include the effort for each. The user decides.

No commit unless the user approves building it.

### 7. README (S)

- Notifications (lead time, click-through), the Starting row of the state table, and the Install and Update sections per Task 1's timing.
- Every UI string must match the app.

Commit: `docs: describe notarized installs and new details`

## Needs the user

- Task 1's account steps and secrets, then one `workflow_dispatch` run, then tagging the first notarized release.
- Approval to run the signed build locally, and to capture a raw payload for Task 2.
- Their printer models for Task 6, and the go/no-go on the camera.

## Done when

- [ ] Tasks 1–7 done, or deferred with a reason (Task 1 may wait on the user; land everything that doesn't need their secrets).
- [ ] `make test` green, `make app` builds, and the release workflow passes a dispatch run if the secrets exist.
- [ ] Every new render viewed in light and dark.
- [ ] Branch pushed and a PR opened to `main` (not merged), with what changed, research sources, the camera recommendation, "Needs the user", and "Found, not fixed".

## Not in this phase

Plate thumbnails (FTPS), desktop widgets, Homebrew cask, Sparkle, iPhone notifications, and any printer control.
