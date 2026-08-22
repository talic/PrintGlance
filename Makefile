# Builds PrintGlance.app. `make install` copies it to ~/Applications.
# `swift test` does not exercise Gatekeeper or the menu bar extra.

export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

APP_NAME := PrintGlance
PREFIX   := $(HOME)/Applications
BUILD    := .build/release/$(APP_NAME)
APP      := dist/$(APP_NAME).app
ZIP      := dist/$(APP_NAME).zip

.PHONY: test release app zip install clean

test:
	swift test

release:
	swift build -c release

app: release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BUILD) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Info.plist $(APP)/Contents/Info.plist
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign -s - --force $(APP)

zip: app
	rm -f $(ZIP)
	cd dist && zip -ry $(APP_NAME).zip $(APP_NAME).app

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
