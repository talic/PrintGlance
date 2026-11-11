---
name: verify-printglance
description: Drive PrintGlance's menu bar print card, printer list, history, and Add Printer window through the offscreen Screen harness and keep PNG proof. Use when a change is user-visible, before a UI pull request, or when asked to prove what the card shows.
---

# Verify PrintGlance

PrintGlance is a macOS 14+ menu bar app. A user clicks the printer icon and reads the print card. Agents prove that card, the printer list, History, and the Add Printer window with the repo's `Screen` harness, which renders the real SwiftUI views offscreen and reads them the way VoiceOver does. The installed app is out of bounds for this skill.

## Launch

Verification does not open `dist/PrintGlance.app` and does not run `make app`, `make install`, or `open`. That copy talks to printers on the LAN, only one copy can run (`LSMultipleInstancesProhibited`), and `make install` rewrites saved printers from `.env`.

Each drive is its own `swift test` process. There is no server to wait for. Ready means the doctor below exits 0: Xcode's Swift is on the path and `DEVELOPER_DIR` is Xcode, not the Command Line Tools. The Command Line Tools have no XCTest and no SwiftUI macros, so bare `swift test` fails on the owner's Mac until the Makefile's `DEVELOPER_DIR` is set. The script sets it when `/Applications/Xcode.app/Contents/Developer` exists.

From the repo root:

```bash
.cursor/skills/verify-printglance/verify-printglance.sh doctor
.cursor/skills/verify-printglance/verify-printglance.sh drive watch-a-print
```

A drive is usable when the named test passes and, for `watch-a-print`, `detail-printing-light.png` and `detail-printing-dark.png` exist in the evidence directory. A passing process with no PNG is not ready.

Two drives must not run at once. They share `.build`. The script refuses to start a drive while one it started is still running.

## Doctor

Run this first, and again after any drive that exits non-zero, before the next drive.

```bash
.cursor/skills/verify-printglance/verify-printglance.sh doctor
```

It is read-only. It checks that `swift` runs, that `DEVELOPER_DIR` is Xcode, and that no drive this script started is still alive. It does not attach to a PrintGlance the user already opened. Exit 0 means this machine can drive the card. Any other exit means stop. Do not launch the menu bar app to get around a failed doctor.

## Drive

The harness is `Screen` (`Tests/PrintGlanceTests/Support/Screen.swift`). It presses controls by accessibility label and reads static text in order. Prefer those labels over coordinates. The script runs the test that already performs the presses. Do not add a test-only endpoint and do not call `GlanceModel.start()`.

```bash
.cursor/skills/verify-printglance/verify-printglance.sh drive <feature-id>
```

Feature ids: `watch-a-print`, `why-it-stopped`, `several-printers`, `history`, `add-a-printer`. The map in `features/` is the source for which labels and end states matter. One green test does not cover a feature whose map lists another entry point.

`watch-a-print` also sets `PG_RENDER_DIR` and runs `RenderStatesTests/testRenderPrinterDetail`, which writes 2x light and dark PNGs of every card state. The proof for that feature is the printing pair named below. The other PNGs are extra output of the same test, not proof of the other features.

## Evidence

Proof goes to `/tmp/printglance-verify-evidence/<run-id>/`. Override the root with `PG_VERIFY_EVIDENCE`. The run id is `PG_VERIFY_RUN_ID` or a timestamp. Cleanup never deletes this directory.

A proof of a feature contains:

- `doctor.txt` for that run, including the Swift version and `DEVELOPER_DIR`
- `drive.log`, the `swift test` command, its output, and its exit code
- for `watch-a-print`, `renders/detail-printing-light.png` and `renders/detail-printing-dark.png`

Standards:

- Drive the production view through `Screen` or `RenderStatesTests`. Do not satisfy a check by assigning `GlanceModel.content` or another internal setter.
- Capture the action and the result. A printing-card proof includes the test that reads the card text and the PNG of that card. The log alone is not the picture.
- The tests use `ModelHarness` and `FakeMQTT`, which is the production boundary the suite already uses instead of a printer. They must not open a socket except loopback, and the MQTT wire tests are not this skill.
- Do not treat a skipped render (`PG_RENDER_DIR` unset) as a successful picture. `make test` skips renders on purpose.
- The menu bar click is a real entry point and is not what `Screen` drives. Say so. Do not report the offscreen card as proof that the status item opened.

Attach `doctor.txt`, `drive.log`, and the printing PNGs to a UI pull request.

## Cleanup

```bash
.cursor/skills/verify-printglance/verify-printglance.sh cleanup
```

Cleanup signals the `swift test` pid this run recorded, if that pid is still alive, then removes the pid file under `/tmp/printglance-verify-runs/`. It does not kill by process name, does not quit a PrintGlance the user opened, and does not delete `/tmp/printglance-verify-evidence`.

After cleanup, the evidence directory from the drive must still be there. A cleanup that removes it is a failed run.

## Helpers

`verify-printglance.sh` is the only helper. It is executable. Run it from anywhere; it finds the repo root by its own path.

```bash
.cursor/skills/verify-printglance/verify-printglance.sh doctor
.cursor/skills/verify-printglance/verify-printglance.sh drive watch-a-print
.cursor/skills/verify-printglance/verify-printglance.sh cleanup
```

Keep the feature map honest with `/maintain-verification-skill` when these screens change.
