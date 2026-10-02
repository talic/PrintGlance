# Builds PrintGlance.app. `make install` copies it to ~/Applications.
# `make test` runs the Swift suite and the Python feed's suite; neither exercises Gatekeeper or
# the real menu bar. docs/TESTING.md has the manual checks.
#
# `make app` signs ad-hoc. A release signs with a Developer ID and notarizes:
#   make notarize SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=<notarytool store-credentials profile>
# CI passes NOTARY_KEY (a .p8 path), NOTARY_KEY_ID and NOTARY_ISSUER instead of NOTARY_PROFILE.

export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

APP_NAME := PrintGlance
PREFIX   := $(HOME)/Applications
BUILD    := .build/release/$(APP_NAME)
APP      := dist/$(APP_NAME).app
ZIP      := dist/$(APP_NAME).zip
ICNS     := dist/AppIcon.icns
SIGN_ID  ?= -
# The feed's tests use the repo venv (paho-mqtt) when it exists; without paho two of them skip.
PYTHON   := $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)

# Notarization needs the hardened runtime and a secure timestamp; ad-hoc builds get neither.
SIGN_FLAGS  := $(if $(filter-out -,$(SIGN_ID)),--options runtime --timestamp)
NOTARY_AUTH := $(if $(NOTARY_PROFILE),--keychain-profile "$(NOTARY_PROFILE)",--key "$(NOTARY_KEY)" --key-id "$(NOTARY_KEY_ID)" --issuer "$(NOTARY_ISSUER)")

.PHONY: test release app zip notarize install clean icon

test:
	swift test
	$(PYTHON) -m unittest discover -s Tests/Feed

release:
	swift build -c release

icon: $(ICNS)

$(ICNS): scripts/render-appicon.swift
	mkdir -p dist
	swift scripts/render-appicon.swift $(ICNS)
	test -f $(ICNS)

app: release $(ICNS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BUILD) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	cp $(ICNS) $(APP)/Contents/Resources/AppIcon.icns
	test -f $(APP)/Contents/Resources/AppIcon.icns
	codesign --force -s "$(SIGN_ID)" $(SIGN_FLAGS) $(APP)

zip: app
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)

# notarytool can exit 0 for a rejected submission, so check its status and print Apple's log.
# Stapling can fail for a short while after acceptance, so it retries. Then zip again so the
# download carries the ticket.
notarize: zip
	xcrun notarytool submit $(ZIP) --wait --timeout 1h --output-format json $(NOTARY_AUTH) > dist/notary.json
	@status=$$(plutil -extract status raw -o - dist/notary.json); \
	if [ "$$status" != Accepted ]; then \
	  echo "Notarization: $$status" >&2; \
	  xcrun notarytool log "$$(plutil -extract id raw -o - dist/notary.json)" $(NOTARY_AUTH) >&2; \
	  exit 1; \
	fi
	@for i in 1 2 3 4 5; do xcrun stapler staple $(APP) && exit 0; sleep 20; done; exit 1
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)

install: app
	-pkill -x $(APP_NAME)
	mkdir -p $(PREFIX)
	rm -rf $(PREFIX)/$(APP_NAME).app
	cp -R $(APP) $(PREFIX)/$(APP_NAME).app
	@if [ -f .env ]; then \
	  set -a; . ./.env; set +a; \
	  defaults delete local.PrintGlance printers >/dev/null 2>&1 || true; \
	  defaults delete local.PrintGlance printerFocusId >/dev/null 2>&1 || true; \
	  [ -n "$$BAMBU_IP" ] && defaults write local.PrintGlance printerIP "$$BAMBU_IP"; \
	  [ -n "$$BAMBU_SERIAL" ] && defaults write local.PrintGlance printerSerial "$$BAMBU_SERIAL"; \
	  [ -n "$$BAMBU_ACCESS_CODE" ] && defaults write local.PrintGlance printerAccessCode "$$BAMBU_ACCESS_CODE"; \
	  [ -n "$$BAMBU_NAME" ] && defaults write local.PrintGlance printerName "$$BAMBU_NAME"; \
	fi
	open $(PREFIX)/$(APP_NAME).app

clean:
	rm -rf .build dist
