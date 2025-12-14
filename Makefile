SHELL := /bin/bash
WORKSPACE := Alona.xcworkspace
SCHEME := Alona
DESTINATION := 'platform=macOS,arch=arm64'
CONFIGURATION := Debug
# Fresh derived data per invocation to avoid LS/register cache contention.
DERIVED_DATA_PATH ?= $(shell mktemp -d /tmp/alona-dd-XXXXXXXX)
# Freeze the value so mktemp isn't re-run per recipe expansion.
DERIVED_DATA_PATH := $(DERIVED_DATA_PATH)
XCBEAUTIFY := $(shell command -v xcbeautify 2>/dev/null)
SWIFTFORMAT := $(shell command -v swiftformat 2>/dev/null)
MODEL_DIR := Alona/Resources/Models
MODEL_FILE := $(MODEL_DIR)/ggml-base.en.bin
MODEL_URL := https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin

ifeq ($(XCBEAUTIFY),)
PIPE_CMD := cat
else
PIPE_CMD := xcbeautify
endif

.PHONY: help setup build test lint format clean run download-model

help:
	@echo "Available targets:"
	@echo "  make setup   # regenerate buildServer.json"
	@echo "  make build   # build macOS app"
	@echo "  make test    # run unit tests"
	@echo "  make lint    # run swiftformat --lint"
	@echo "  make format  # apply swiftformat"
	@echo "  make clean   # clean derived data"
	@echo "  make run     # build and launch the macOS app"
	@echo "  make download-model # fetch ggml-base.en.bin into Resources/Models"

setup:
	xcode-build-server config -workspace $(WORKSPACE) -scheme $(SCHEME)

build:
	set -o pipefail && xcodebuild \
		-workspace $(WORKSPACE) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		-destination $(DESTINATION) \
		build | $(PIPE_CMD)

test:
	set -o pipefail && xcodebuild \
		-workspace $(WORKSPACE) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA_PATH) \
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
	xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA_PATH) clean
	rm -rf DerivedData

run: build
	@APP_PATH=$$(xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA_PATH) -showBuildSettings | awk -F' = ' '$$1 ~ /^[[:space:]]*BUILT_PRODUCTS_DIR$$/ {dir=$$2} $$1 ~ /^[[:space:]]*FULL_PRODUCT_NAME$$/ {name=$$2} END {gsub(/^[[:space:]]+|[[:space:]]+$$/, "", dir); gsub(/^[[:space:]]+|[[:space:]]+$$/, "", name); printf "%s/%s", dir, name}'); \
	if [ ! -d "$$APP_PATH" ]; then \
		echo "Unable to locate built app at $$APP_PATH"; \
		exit 1; \
	fi; \
	open "$$APP_PATH"

download-model:
	@mkdir -p $(MODEL_DIR)
	@if [ -f $(MODEL_FILE) ]; then \
		echo "Model already present at $(MODEL_FILE)"; \
	else \
		echo "Downloading Whisper base model..."; \
		curl -L "$(MODEL_URL)" -o $(MODEL_FILE); \
		echo "Saved model to $(MODEL_FILE)"; \
	fi
