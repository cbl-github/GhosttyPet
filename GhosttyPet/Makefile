APP_NAME := GhosttyPet
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR := $(APP_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
APP_BINARY := $(MACOS_DIR)/$(APP_NAME)
SOURCES := src/main.m src/PetView.m

SDK := $(shell xcrun --show-sdk-path)
CLANG := $(shell xcrun --find clang)
CFLAGS := -fobjc-arc -Wall -Wextra -Werror -O2 -mmacosx-version-min=11.0 -isysroot $(SDK)
LDFLAGS := -framework AppKit

.PHONY: all clean test run

all: $(APP_BINARY)

$(APP_BINARY): $(SOURCES) Info.plist
	mkdir -p "$(MACOS_DIR)"
	cp Info.plist "$(CONTENTS_DIR)/Info.plist"
	$(CLANG) $(CFLAGS) $(SOURCES) $(LDFLAGS) -o "$(APP_BINARY)"

test: all
	bash tests/test_bundle.sh

run: all
	open "$(APP_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"
