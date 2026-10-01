# Builds PrintGlance.app. `make install` copies it to ~/Applications.
# `swift test` does not exercise Gatekeeper or the menu bar extra.
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

# Notarization needs the hardened runtime and a secure timestamp; ad-hoc builds get neither.
SIGN_FLAGS  := $(if $(filter-out -,$(SIGN_ID)),--options runtime --timestamp)
NOTARY_AUTH := $(if $(NOTARY_PROFILE),--keychain-profile "$(NOTARY_PROFILE)",--key "$(NOTARY_KEY)" --key-id "$(NOTARY_KEY_ID)" --issuer "$(NOTARY_ISSUER)")

.PHONY: test release app zip notarize install clean icon

test:
	swift test

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

# Staple the ticket to the app, then zip again so the download carries it.
notarize: zip
	xcrun notarytool submit $(ZIP) --wait --timeout 30m $(NOTARY_AUTH)
	xcrun stapler staple $(APP)
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
