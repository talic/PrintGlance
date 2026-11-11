# Watch a print

Watch a print shows the job name, the state, the finish time, the time left, the percent, the layer, and the filament on the print card, and a short sentence in the menu bar.

## Sub-features

- `card-printing` shows a running print's finish time, time left, percent, layer, and filament.
- `card-starting` shows the stage word and how far the heaters have got.
- `menubar-sentence` reads the menu bar item as one VoiceOver sentence.
- `card-png` writes a light and a dark picture of the printing card.

## How to get to it (user POV)

- Click the printer icon in the menu bar. The print card opens on the printer the menu bar is showing.
- While a print is running, the menu bar shows the percent and the finish time. While it is starting, the menu bar shows the stage, such as Heating.

## Driving it with Screen

Preconditions:

- `verify-printglance.sh doctor` exits 0.
- No other `swift test` started by this script is running.

- **Printing card.** Open the card for a running Benchy at 52%. Run `.cursor/skills/verify-printglance/verify-printglance.sh drive watch-a-print`. The `CardScreenTests/testPrinting` result in `drive.log` is exit 0, and the test's text is Benchy, Printing, 16:25, 1h 24m left, 52%, Layer 18 / 29, PLA Matte  80%.
- **Menu bar sentence.** The same drive does not run the menu bar test. Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'CardScreenTests/testMenuBarItemReadsAsOneSentence$'` from the repo root and keep the log next to `drive.log`. The label is `X2D, printing, 52 percent, finish 16:25, layer 18 / 29`.
- **Starting card.** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'CardScreenTests/testStartingShowsTheStageAndHeaters$'`. The card reads Benchy, Heating, and Nozzle 186 / 220° · Bed 48 / 60°.
- **Pictures.** The `watch-a-print` drive also runs `RenderStatesTests/testRenderPrinterDetail`. Require `renders/detail-printing-light.png` and `renders/detail-printing-dark.png` under the evidence directory. Both show Benchy at 52%.

## Gotchas

- Clicking the real menu bar icon is not driven here. `MenuBarExtra` needs a status bar, `performClick` does not open a window-style extra on macOS 27, and computer-use tools cannot target a menu-bar-only app. Launching `dist/PrintGlance.app` to try anyway connects to real printers. Report that entry point as unreachable.
- `make test` skips PNG renders unless `PG_RENDER_DIR` is set. The drive script sets it. A log with no PNG is not proof of `card-png`.
- `testRenderPrinterDetail` also writes the other card states. Only the two printing filenames prove this feature.
- The printing card has no button. There is nothing to press. The proof is the text plus the PNG.
- Times on the card are already strings in the test rows. Do not assert a clock formatted from the machine's timezone.
