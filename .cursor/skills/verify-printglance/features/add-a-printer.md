# Add a printer

Add a printer finds printers on this Wi-Fi, takes the access code, and stays open until the printer answers. The first printer then explains that PrintGlance is in the menu bar.

## Sub-features

- `setup-pick` lists found printers, refuses one that is already saved, and fills the name from the pick.
- `setup-code` enables Connect once an access code is typed, and hints until it is 8 characters.
- `setup-connect` shows Connected after the printer answers, with Open at login on, and Done closes the window.
- `setup-fail` shows the rejected-code sentence and Try Again.

## How to get to it (user POV)

- The Add Printer window opens the first time PrintGlance opens, and whenever it opens with no printer saved.
- To add another, click the printer icon, click …, and choose Add Printer….
- Under Printers on this Wi-Fi, click the printer, type the access code from the printer's screen, and click Connect.
- If the list is empty, click Enter IP and serial instead, then type the IP address and the serial.

## Driving it with Screen

Preconditions:

- `verify-printglance.sh doctor` exits 0.
- No other `swift test` started by this script is running.
- The drive uses the test's fake discovery hits. It does not scan the network.

- **Pick a printer.** Run `.cursor/skills/verify-printglance/verify-printglance.sh drive add-a-printer`. `SetupScreenTests/testFoundPrintersArePickedAndAddedOnesAreNot` exits 0. The Office X1C row is disabled and its label ends with Added. Pressing Garage P1S, P1S · 192.0.2.20 fills the name Garage P1S. Connect stays disabled until the access code is typed.
- **Access code length.** The same drive runs `SetupScreenTests/testTypingTheAccessCodeEnablesConnectAndHintsAtItsLength`. After a short code, the card contains Access codes are usually 8 characters. and Connect is enabled. After 8 characters, that hint is gone.
- **Connect.** The same drive runs `SetupScreenTests/testConnectingWelcomesAfterThePrinterAnswers`. After Connect, the card contains Connecting to X2D…. After the fake printer accepts, the text is Connected, PrintGlance is in your menu bar. Click it to see your print. Open at login starts on. The test turns it off before Done. Done runs the close action.
- **Rejected code.** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'SetupScreenTests/testFailureSaysWhyAndOffersTryAgain$'`. The card contains The access code was rejected. Check it on the printer: Settings, then LAN or Network. and Try Again is enabled.

## Gotchas

- Do not press Add Printer on the print card, and do not call `PrinterDiscovery.scan` or `SetupWindow.show`. Those scan Wi-Fi and can prompt for Local Network. The drive builds `SetupView` with the hits the test already has.
- Leave Open at login off before the test finishes. Turning it on registers the test runner as a login item.
- The access code in the test is a fixture. Do not print a real access code, and do not read `.env`, while driving this.
- The first-launch window in the running app is not this drive. Report that entry point as not driven. The Connected text is the offscreen window only.
- Esc and ⌘W cancel the real setup window. The drive presses Cancel in `SetupScreenTests/testCancelCloses` only if you run that filter yourself. The bundled drive does not.
