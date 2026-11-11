# Several printers

Several printers lists each saved printer under the card. The card opens on the one that needs you. Choosing a row shows that printer until the card is opened again.

## Sub-features

- `list-two` shows a row per printer, with percent and finish time while printing.
- `list-switch` shows the other printer's job after its row is pressed, and remembers that printer as the focus.
- `list-one` hides the list when only one printer is saved.

## How to get to it (user POV)

- Save two printers from Add Printer. Click the printer icon. The card is the printer finishing soonest, and both printers are rows under it.
- Click the other printer's row. The card shows that printer.
- With one printer, the card has no list.

## Driving it with Screen

Preconditions:

- `verify-printglance.sh doctor` exits 0.
- No other `swift test` started by this script is running.

- **Two printers, then switch.** Run `.cursor/skills/verify-printglance/verify-printglance.sh drive several-printers`. `PanelScreenTests/testPrintingCardWithTheListAndSwitchingPrinters` exits 0. Before the press, the card starts with Benchy, Printing. After the press on the P1S row, the card starts with Gears, Printing, and the focused serial is the P1S serial the test saves.
- **Row labels.** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'CardScreenTests/testPrinterListRowsSayStateAndProgress$'`. The controls are named `X2D, Printing, 52 percent, finish 16:25`, `P1S, Paused, 52 percent`, and `A1 mini, Idle`. Pressing the P1S row selects `p1s`.
- **One printer.** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'PanelScreenTests/testOnePrinterHasNoList$'`. The text is X2D, Idle, and the only control is More.

## Gotchas

- The list row's accessibility label is the whole sentence, including the state. Press that label. A press on the printer name alone misses.
- Control-click Edit and Remove on a row is a modal context menu. The drive does not open it.
- Focus changes what the menu bar shows next time. The test reads `focusId` after the press. A card that changed without `focusId` changing is a failed proof.
- Adding the second printer through the real Add Printer window scans Wi-Fi. This feature's drive uses printers the test already saved. Use the Add a printer feature for the window.
