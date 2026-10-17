# Recent prints

Recent prints lists the last jobs on this Mac, newest first, and can export them as CSV. An empty list says so.

## Sub-features

- `history-rows` shows the job, when it started, how long it took, and Finished, Failed, or Printing.
- `history-empty` says no prints are on this Mac yet, and Export CSV is disabled.
- `history-export` runs the export action when Export CSV is pressed.
- `history-back` leaves History when Back is pressed.

## How to get to it (user POV)

- Click the printer icon, click …, and choose History.
- Read the rows. With more than one printer, a row also names the printer.
- Click Export CSV to save the list. Click the back arrow, or press Esc, to return to the print card.

## Driving it with Screen

Preconditions:

- `verify-printglance.sh doctor` exits 0.
- No other `swift test` started by this script is running.

- **Rows and export.** Run `.cursor/skills/verify-printglance/verify-printglance.sh drive history`. `PanelScreenTests/testHistoryRowsSayHowEachPrintEnded` exits 0. After the History title, the rows end with · Printing, · 2h 05m · Failed, and · 2h 05m · Finished. Pressing Export CSV runs the export action once.
- **Empty list and Back.** The same drive runs `PanelScreenTests/testEmptyHistory`. The text is History, No prints on this Mac yet. Export CSV is disabled. Pressing Back runs the close action once.
- **Clear is absent while a job is open.** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'PanelScreenTests/testClearHistoryIsOfferedOnlyWhenThereIsSomethingToClear$'`. A list with only a print in progress has no Clear History… control.

## Gotchas

- The … menu that opens History is modal. The drive opens `HistoryView` directly. Report the menu entry point as not driven. Do not call the History screen a click on ….
- Clear History… in the running app asks with a modal alert first. `PanelScreenTests` presses the button with a stand-in action. A press in that test is not proof that the alert's Cancel keeps the list.
- Export CSV in the test counts the action. It does not write a file into the evidence directory. Do not look for a CSV there.
- One printer's rows do not include the printer name. A row that contains X2D in the single-printer test is a failure.
