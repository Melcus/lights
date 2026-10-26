APP := Lights
BUILD := build
XCODEBUILD := xcodebuild -project Lights.xcodeproj -scheme $(APP) -derivedDataPath $(BUILD) -quiet
DEBUG_APP := $(BUILD)/Build/Products/Debug/$(APP).app
RELEASE_APP := $(BUILD)/Build/Products/Release/$(APP).app
INSTALLED_APP := /Applications/$(APP).app

.PHONY: build release test run install uninstall snapshots clean

build:
	$(XCODEBUILD) -configuration Debug build

release:
	$(XCODEBUILD) -configuration Release build

test:
	cd LightsKit && swift test

run: build
	-pkill -x $(APP) && sleep 1
	open $(DEBUG_APP)

install: release
	-pkill -x $(APP) && sleep 1
	rm -rf $(INSTALLED_APP)
	ditto $(RELEASE_APP) $(INSTALLED_APP)
	open $(INSTALLED_APP)

uninstall:
	-pkill -x $(APP)
	rm -rf $(INSTALLED_APP)

# Renders the panel in every state, light and dark, without showing anything on screen.
snapshots: build
	mkdir -p $(BUILD)/snapshots
	$(DEBUG_APP)/Contents/MacOS/$(APP) -designSnapshots $(abspath $(BUILD)/snapshots)
	open $(BUILD)/snapshots

clean:
	rm -rf $(BUILD) LightsKit/.build
