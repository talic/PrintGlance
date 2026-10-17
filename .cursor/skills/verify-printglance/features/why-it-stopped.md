# Why a print stopped

Why a print stopped shows a short reason and the error code when a print pauses or fails, and a Look up link for that code.

## Sub-features

- `paused-reason` shows time left, the filament-ran-out sentence, the error code, and Look up.
- `paused-no-code` says that no error was reported.
- `failed-reason` shows Failed, the reason, and the error code, without a progress percent.

## How to get to it (user POV)

- Click the printer icon while the menu bar shows a pause icon, or an X.
- On the paused card, read the reason under the layer line, then the error code. Look up opens Bambu's page in the browser.
- On the failed card, read Failed, the reason, and the error code.

## Driving it with Screen

Preconditions:

- `verify-printglance.sh doctor` exits 0.
- No other `swift test` started by this script is running.

- **Paused with a code.** Run `.cursor/skills/verify-printglance/verify-printglance.sh drive why-it-stopped`. `CardScreenTests/testPausedSaysWhyAndOffersTheLookup` exits 0. The card contains Filament ran out in AMS A, slot 1., Error 0700-2000-0002-0001, and a link named Look up error 0700-2000-0002-0001. It shows 1h 24m left and does not show a finish clock.
- **Failed.** The same drive runs `CardScreenTests/testFailed`. The card contains Benchy, Failed, The nozzle overheated. Turn the printer off and have it checked., and Error 0300-806E. It does not contain 37%.
- **No code.** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'CardScreenTests/testPausedWithoutACodeSaysSo$'`. The card contains No error reported. and has no link.

## Gotchas

- Do not press Look up. It opens the browser. The drive checks that the control's role is AXLink and stops there.
- A paused card shows time left, not a finish time. The finish time would keep moving while the printer is paused.
- The menu bar click that opens this card is the same unreachable status item as in Watch a print. Report it as unreachable. Do not call the offscreen card a click on the icon.
