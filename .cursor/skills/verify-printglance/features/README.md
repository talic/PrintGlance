# PrintGlance verification map

This directory is the maintained source for verifying what a person sees in PrintGlance. Read this index, then use the matching feature file.

## Baseline preconditions

- Run `.cursor/skills/verify-printglance/verify-printglance.sh doctor` and require exit 0.
- Doctor passes only when `swift` runs and `DEVELOPER_DIR` is `/Applications/Xcode.app/Contents/Developer`.
- Do not open `dist/PrintGlance.app`, and do not run `make app` or `make install`.
- Leave `PG_VERIFY_EVIDENCE` at `/tmp/printglance-verify-evidence` unless two people need separate proof trees.
- Never drive while a `swift test` this script started is still running. They share `.build`.

## Driving conventions

- Start from a passing doctor.
- Drive with `verify-printglance.sh drive <feature-id>`. The feature file names the test filter and the accessibility labels that test presses.
- Treat filter strings as literal.
- The menu bar status item is a user entry point the harness cannot click. Do not mark it verified because an offscreen card passed.
- Restore nothing in the user's preferences. The tests use a scratch domain. Do not delete proof files during cleanup.

## Proof and skip reporting

- Record the feature id, the test filter, and the evidence directory with every artifact.
- A UI proof includes `drive.log` (command, output, exit code) and, when the feature file names PNGs, those files.
- A press proof is the test that presses the control and checks the text afterwards. The log has to contain that test's name and exit 0.
- Report an unreachable entry point with the command you would have run and the unmet precondition. Do not report it as verified through the offscreen card.

## Feature entry contract

Each feature file starts with an H1 and one paragraph, then exactly these four H2 sections, in order: `Sub-features`, `How to get to it (user POV)`, `Driving it with Screen`, `Gotchas`.

## Features

- [Watch a print](./watch-a-print.md) covers the printing card, the starting card, and the menu bar sentence.
- [Why a print stopped](./why-it-stopped.md) covers a paused print with a reason and a failed print.
- [Several printers](./several-printers.md) covers the list under the card and switching printers.
- [Recent prints](./history.md) covers History rows, an empty list, and Export CSV.
- [Add a printer](./add-a-printer.md) covers picking a found printer, typing the access code, and connecting.
