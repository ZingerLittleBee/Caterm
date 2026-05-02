# Caterm macOS dev Makefile
#
# Quick start:
#   make run         # build + codesign + launch the bare binary (fastest dev loop)
#   make run-app     # wrap the signed binary in a Caterm.app bundle and launch it
#                    # (REQUIRED to test UserNotifications, NSWorkspace bundle
#                    # identity, App Groups, etc. — those frameworks raise an
#                    # uncatchable Obj-C NSException when there is no .app
#                    # bundle / CFBundleIdentifier around the binary)
#   make test        # swift test
#   make clean       # nuke .build
#
# When to use which:
#   - `make run`     — default. Faster, no bundle assembly. Anything that doesn't
#                      need a bundle identity (terminal, SSH, sync, keychain via
#                      access groups) works fine.
#   - `make run-app` — needed when you're touching code that calls
#                      UNUserNotificationCenter, NSWorkspace bundle APIs,
#                      LSCopyApplication*, NSUserActivity / Handoff, App Groups,
#                      or anything that asserts a CFBundleIdentifier exists.
#                      The bare binary will crash on first such call.
#
# Codesign identity is auto-detected from the login keychain. Override with
# either the Common Name or the 40-char SHA-1 fingerprint (preferred when
# auto-renewed Apple Development certs share the same Common Name):
#   make run-app CATERM_DEV_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567

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

.PHONY: ghostty-submodule
ghostty-submodule: ## init/update Ghostty submodule
	git -C "$(ROOT)/../.." submodule update --init --recursive apps/macos/Vendor/ghostty

.PHONY: ghostty-kit
ghostty-kit: ghostty-submodule ## build Frameworks/GhosttyKit.xcframework
	bash Scripts/build-libghostty.sh

.PHONY: sign
sign: build ## codesign caterm + caterm-askpass with dev identity
	@if [ -z "$(CATERM_DEV_IDENTITY)" ]; then \
	    echo "No codesign identity detected. Set CATERM_DEV_IDENTITY=..."; \
	    exit 1; \
	fi
	CATERM_DEV_IDENTITY="$(CATERM_DEV_IDENTITY)" bash Scripts/dev-codesign.sh

.PHONY: run
run: sign ## build + sign + launch caterm in foreground (no .app bundle — UserNotifications etc. will crash)
	@echo "Launching $(CATERM_BIN)"
	@"$(CATERM_BIN)"

.PHONY: run-app
run-app: sign ## build + sign + wrap in Caterm.app + launch — use this for anything needing bundle identity
	# Why a separate target?
	#   `make run` launches the bare `caterm` binary, which has no Info.plist
	#   and no CFBundleIdentifier. Several Apple frameworks (most notably
	#   UserNotifications, NSWorkspace, App Groups) raise an uncatchable
	#   Obj-C NSException ("bundleProxyForCurrentProcess is nil") when called
	#   from a process with no bundle identity, killing the whole app.
	#
	#   This target wraps the already-signed binaries in a minimal Caterm.app
	#   shell, writes an Info.plist with CFBundleIdentifier=app.caterm.dev,
	#   re-seals the bundle, and launches it via `open` so Launch Services
	#   treats it as a real app. See Scripts/dev-run-app.sh for details.
	#
	# Override the bundle id (e.g. to share Keychain state with another build):
	#   make run-app CATERM_DEV_BUNDLE_ID=app.caterm.dev2
	@if [ -z "$(CATERM_DEV_IDENTITY)" ]; then \
	    echo "No codesign identity detected. Set CATERM_DEV_IDENTITY=..."; \
	    exit 1; \
	fi
	CATERM_DEV_IDENTITY="$(CATERM_DEV_IDENTITY)" \
	    CATERM_DEV_BUNDLE_ID="$(CATERM_DEV_BUNDLE_ID)" \
	    bash Scripts/dev-run-app.sh

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
