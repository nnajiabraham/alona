SHELL := /bin/bash
WORKSPACE := Alona.xcworkspace
SCHEME := Alona
DESTINATION := 'platform=macOS,arch=arm64'
CONFIGURATION := Debug
# Default to a stable DerivedData path so macOS permissions stick across runs.
# Override with `DERIVED_DATA_PATH=/tmp/alona-dd-XXXX make test` when you need
# a one-off clean environment.
DERIVED_DATA_PATH ?= $(CURDIR)/DerivedData
XCBEAUTIFY := $(shell command -v xcbeautify 2>/dev/null)
SWIFTFORMAT := $(shell command -v swiftformat 2>/dev/null)
SWIFTLINT := $(shell command -v swiftlint 2>/dev/null)
# Whisper model configuration
# Default to large-v3-turbo for best accuracy/speed balance
# Override with MODEL=base.en or MODEL=small.en for smaller models
MODEL ?= large-v3-turbo
MODEL_DIR := Alona/Resources/Models
MODEL_FILE := $(MODEL_DIR)/ggml-$(MODEL).bin
MODEL_URL := https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$(MODEL).bin

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
	@echo "  make lint    # run swiftformat --lint (+ swiftlint if installed)"
	@echo "  make format  # apply swiftformat"
	@echo "  make clean   # clean derived data"
	@echo "  make run     # build and launch the macOS app"
	@echo "  make download-model # fetch Whisper model (default: large-v3-turbo)"
	@echo "                      # Override: MODEL=base.en make download-model"

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
	@killall Alona 2>/dev/null || true; \
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
ifneq ($(SWIFTLINT),)
	swiftlint lint --quiet
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
	@killall Alona 2>/dev/null || true; \
	APP_PATH=$$(xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA_PATH) -showBuildSettings | awk -F' = ' '$$1 ~ /^[[:space:]]*BUILT_PRODUCTS_DIR$$/ {dir=$$2} $$1 ~ /^[[:space:]]*FULL_PRODUCT_NAME$$/ {name=$$2} END {gsub(/^[[:space:]]+|[[:space:]]+$$/, "", dir); gsub(/^[[:space:]]+|[[:space:]]+$$/, "", name); printf "%s/%s", dir, name}'); \
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
		echo "Downloading Whisper $(MODEL) model..."; \
		curl -L --progress-bar "$(MODEL_URL)" -o $(MODEL_FILE); \
		echo "Saved model to $(MODEL_FILE)"; \
	fi

# Convenience targets for specific models
download-model-tiny:
	$(MAKE) download-model MODEL=tiny.en

download-model-base:
	$(MAKE) download-model MODEL=base.en

download-model-small:
	$(MAKE) download-model MODEL=small.en

download-model-turbo:
	$(MAKE) download-model MODEL=large-v3-turbo
