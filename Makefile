# Native menu-bar extra plus local print.json feed.
# `make install` copies an ad-hoc-signed .app to ~/Applications and loads the feed LaunchAgent.
# `swift test` does not exercise App Transport Security.

export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

APP_NAME    := PrintGlance
PREFIX      := $(HOME)/Applications
BUILD       := .build/release/$(APP_NAME)
APP         := dist/$(APP_NAME).app
PYTHON      := $(abspath .venv/bin/python)
FEED_LABEL  := local.PrintGlance.feed
OLD_LABEL   := local.amoled.print-loop
FEED_PLIST  := $(HOME)/Library/LaunchAgents/$(FEED_LABEL).plist
FEED_SCRIPT := $(abspath print_loop.sh)
UID         := $(shell id -u)

.PHONY: setup test release app install install-feed clean

setup:
	@if [ ! -x "$(PYTHON)" ]; then python3 -m venv .venv && "$(PYTHON)" -m pip install -r requirements.txt; fi

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

install: setup app install-feed
	-pkill -x $(APP_NAME)
	mkdir -p $(PREFIX)
	rm -rf $(PREFIX)/$(APP_NAME).app
	cp -R $(APP) $(PREFIX)/$(APP_NAME).app
	open $(PREFIX)/$(APP_NAME).app

install-feed:
	chmod +x $(FEED_SCRIPT)
	mkdir -p $(HOME)/Library/LaunchAgents $(HOME)/Library/Logs
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0">' \
	  '<dict>' \
	  '<key>Label</key><string>$(FEED_LABEL)</string>' \
	  '<key>ProgramArguments</key>' \
	  '<array><string>/bin/bash</string><string>$(FEED_SCRIPT)</string></array>' \
	  '<key>RunAtLoad</key><true/>' \
	  '<key>KeepAlive</key><true/>' \
	  '<key>StandardOutPath</key><string>$(HOME)/Library/Logs/PrintGlance-feed.log</string>' \
	  '<key>StandardErrorPath</key><string>$(HOME)/Library/Logs/PrintGlance-feed.log</string>' \
	  '</dict></plist>' > $(FEED_PLIST)
	-launchctl bootout gui/$(UID)/$(OLD_LABEL)
	-launchctl bootout gui/$(UID)/$(FEED_LABEL)
	launchctl bootstrap gui/$(UID) $(FEED_PLIST)

clean:
	rm -rf .build dist
