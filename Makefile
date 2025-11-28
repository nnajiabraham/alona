SHELL := /bin/bash
WORKSPACE := Alona.xcworkspace
SCHEME := Alona
DESTINATION := 'platform=macOS,arch=arm64'
CONFIGURATION := Debug
XCBEAUTIFY := $(shell command -v xcbeautify 2>/dev/null)
SWIFTFORMAT := $(shell command -v swiftformat 2>/dev/null)

ifeq ($(XCBEAUTIFY),)
PIPE_CMD := cat
else
PIPE_CMD := xcbeautify
endif

.PHONY: help setup build test lint format clean run

help:
	@echo "Available targets:"
	@echo "  make setup   # regenerate buildServer.json"
	@echo "  make build   # build macOS app"
	@echo "  make test    # run unit tests"
	@echo "  make lint    # run swiftformat --lint"
	@echo "  make format  # apply swiftformat"
	@echo "  make clean   # clean derived data"
	@echo "  make run     # build and launch the macOS app"

setup:
	xcode-build-server config -workspace $(WORKSPACE) -scheme $(SCHEME)

build:
	set -o pipefail && xcodebuild \
		-workspace $(WORKSPACE) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination $(DESTINATION) \
		build | $(PIPE_CMD)

test:
	set -o pipefail && xcodebuild \
		-workspace $(WORKSPACE) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination $(DESTINATION) \
		test | $(PIPE_CMD)

lint:
ifeq ($(SWIFTFORMAT),)
	@echo "swiftformat is not installed. Install via 'brew install swiftformat' to run lint." && exit 1
else
	swiftformat Alona AlonaTests --lint
endif

format:
ifeq ($(SWIFTFORMAT),)
	@echo "swiftformat is not installed. Install via 'brew install swiftformat' to format." && exit 1
else
	swiftformat Alona AlonaTests
endif

clean:
	xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) clean
	rm -rf DerivedData

run: build
	@APP_PATH=$$(xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration $(CONFIGURATION) -showBuildSettings | awk -F' = ' '$$1 ~ /^[[:space:]]*BUILT_PRODUCTS_DIR$$/ {dir=$$2} $$1 ~ /^[[:space:]]*FULL_PRODUCT_NAME$$/ {name=$$2} END {gsub(/^[[:space:]]+|[[:space:]]+$$/, "", dir); gsub(/^[[:space:]]+|[[:space:]]+$$/, "", name); printf "%s/%s", dir, name}'); \
	if [ ! -d "$$APP_PATH" ]; then \
		echo "Unable to locate built app at $$APP_PATH"; \
		exit 1; \
	fi; \
	open "$$APP_PATH"
