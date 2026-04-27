# Caterm macOS dev Makefile
#
# Quick start:
#   make run         # build + codesign + launch
#   make test        # swift test
#   make clean       # nuke .build
#
# Codesign identity is auto-detected from the login keychain. Override with:
#   make run CATERM_DEV_IDENTITY="Apple Development: Other Name (XXXXXXXX)"

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

ROOT := $(shell pwd)
BIN_DIR := $(ROOT)/.build/debug
CATERM_BIN := $(BIN_DIR)/caterm
ASKPASS_BIN := $(BIN_DIR)/caterm-askpass

# Auto-detect first available codesigning identity if not provided.
# (awk -F'"' avoids nested parens that confuse make's $(shell ...) tokenizer.)
CATERM_DEV_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2;exit}')

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Detected codesign identity: $(CATERM_DEV_IDENTITY)"

.PHONY: build
build: ## swift build (debug)
	swift build

.PHONY: build-release
build-release: ## swift build (release)
	swift build -c release

.PHONY: sign
sign: build ## codesign caterm + caterm-askpass with dev identity
	@if [ -z "$(CATERM_DEV_IDENTITY)" ]; then \
	    echo "No codesign identity detected. Set CATERM_DEV_IDENTITY=..."; \
	    exit 1; \
	fi
	CATERM_DEV_IDENTITY="$(CATERM_DEV_IDENTITY)" bash Scripts/dev-codesign.sh

.PHONY: run
run: sign ## build + sign + launch caterm in foreground
	@echo "Launching $(CATERM_BIN)"
	@"$(CATERM_BIN)"

.PHONY: run-bg
run-bg: sign ## build + sign + launch caterm in background (logs to /tmp/caterm.log)
	@echo "Launching $(CATERM_BIN) (logs: /tmp/caterm.log)"
	@nohup "$(CATERM_BIN)" >/tmp/caterm.log 2>&1 &
	@sleep 0.5
	@echo "Started (pid $$(pgrep -nf '$(CATERM_BIN)' || echo '?'))"

.PHONY: kill
kill: ## kill any running caterm dev process
	-pkill -f "$(CATERM_BIN)" || true

.PHONY: bootstrap-askpass
bootstrap-askpass: sign ## seed Keychain so signed askpass is in the partition list (skips Always Allow dialog)
	@CATERM_ASKPASS_STUFF=1 "$(ASKPASS_BIN)" || true
	@echo "askpass keychain bootstrap done."

.PHONY: test
test: ## swift test (set CATERM_E2E_DOCKER=1 to include the Docker E2E)
	swift test

.PHONY: test-e2e
test-e2e: ## include the Docker E2E SSH integration test
	CATERM_E2E_DOCKER=1 swift test

.PHONY: clean
clean: ## remove .build (forces full rebuild)
	swift package clean
	rm -rf .build/debug.yaml

.PHONY: distclean
distclean: ## nuke .build entirely (incl. SwiftPM caches)
	rm -rf .build

.PHONY: lint
lint: ## ultracite check across the repo
	cd $(ROOT)/../.. && bun x ultracite check

.PHONY: doctor
doctor: ## show toolchain / signing diagnostics
	@echo "swift: $$(swift --version | head -1)"
	@echo "Xcode CLT: $$(xcode-select -p)"
	@echo "codesign identities:"
	@security find-identity -v -p codesigning | sed 's/^/  /'
	@echo "Detected identity: $(CATERM_DEV_IDENTITY)"
	@echo "Build dir: $(BIN_DIR)"
	@if [ -x "$(CATERM_BIN)" ]; then \
	    echo "caterm signature:"; \
	    codesign -dvv "$(CATERM_BIN)" 2>&1 | grep -E "TeamIdentifier|Authority" | sed 's/^/  /'; \
	fi
