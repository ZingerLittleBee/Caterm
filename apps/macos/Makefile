# Caterm macOS dev Makefile
#
# Quick start:
#   make run-app     # build + codesign + wrap in Caterm.app bundle + launch
#                    # (default dev loop — needed because AppDelegate registers
#                    # for APS push on every launch, which requires a bundle
#                    # identity. The bare binary will crash on launch.)
#   make run         # build + codesign + launch the bare binary
#                    # (only useful for quick build/sign sanity checks — does
#                    # NOT survive into AppDelegate.applicationDidFinishLaunching
#                    # because of the APS register call there.)
#   make test        # swift test
#   make clean       # nuke .build
#
# When to use which:
#   - `make run-app` — default. Required for anything that exercises the running
#                      app: UNUserNotificationCenter / APS, NSWorkspace bundle
#                      APIs, LSCopyApplication*, NSUserActivity / Handoff, App
#                      Groups, or anything that asserts a CFBundleIdentifier
#                      exists. CloudKit push subscriptions count — AppDelegate
#                      calls `NSApp.registerForRemoteNotifications()` on every
#                      launch, so the bare binary path is unsafe by default.
#   - `make run`     — fast build+sign smoke test only. Use when you just want
#                      to confirm the binary builds and signs cleanly without
#                      actually running the UI.
#
# Codesign identity resolution (priority high → low):
#   1. CATERM_DEV_IDENTITY env var / make argument
#   2. apps/macos/.dev-identity (gitignored, one line — Common Name or
#      40-char SHA-1; Conductor worktrees symlink this to the main repo
#      via conductor.json setup, so writing it once in the main repo
#      propagates to all worktrees)
#   3. Auto-detect from login keychain (`security find-identity` first match
#      — unreliable when multiple "Apple Development" certs share a CN, which
#      Apple's auto-renewal flow regularly produces)
#
# SHA-1 fingerprint is preferred over Common Name because it disambiguates
# duplicate / renewed certs:
#   echo 28A2AF9F761AB261B3144E4AF67373EC0F883ED1 > apps/macos/.dev-identity
# or one-shot override:
#   make run-app CATERM_DEV_IDENTITY=0123456789ABCDEF0123456789ABCDEF01234567

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

ROOT := $(shell pwd)
BIN_DIR := $(ROOT)/.build/debug
CATERM_BIN := $(BIN_DIR)/caterm
ASKPASS_BIN := $(BIN_DIR)/caterm-askpass

# Resolve codesign identity (see header comment for priority chain).
# Only runs the lookup when CATERM_DEV_IDENTITY is not already set on the
# command line / environment.
# (awk -F'"' avoids nested parens that confuse make's $(shell ...) tokenizer.)
ifeq ($(origin CATERM_DEV_IDENTITY), undefined)
  ifneq ("$(wildcard $(ROOT)/.dev-identity)","")
    CATERM_DEV_IDENTITY := $(shell tr -d '[:space:]' < $(ROOT)/.dev-identity)
  else
    CATERM_DEV_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2;exit}')
  endif
endif

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
run: sign ## build + sign + launch bare binary (build smoke only — APS register in AppDelegate will crash without bundle id; use run-app for actual dev)
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
	-pkill -f "Caterm.app/Contents/MacOS/caterm" || true

.PHONY: dist
dist: build-release ## Distribution build: release config + dist signing + bundle assembly
	# Production-signed Caterm.app for two-Mac smoke / external distribution.
	#
	# Required env (these are NOT auto-detected):
	#   CATERM_DIST_IDENTITY       Developer ID / Mac App Distribution identity
	#                              (CN or SHA-1; same form as CATERM_DEV_IDENTITY).
	#   CATERM_DIST_PROFILE_PATH   path to the Distribution .provisionprofile
	#                              (App ID configured with aps-environment=
	#                              production and icloud-container-environment=
	#                              Production).
	#
	# This target intentionally does NOT launch the app — distribution builds
	# are for the test Macs, not local dev. Output: .build/release/Caterm.app.
	@if [ -z "$$CATERM_DIST_IDENTITY" ]; then \
	    echo "Set CATERM_DIST_IDENTITY=... (Developer ID / Mac App Distribution cert)"; \
	    exit 1; \
	fi
	@if [ -z "$$CATERM_DIST_PROFILE_PATH" ]; then \
	    echo "Set CATERM_DIST_PROFILE_PATH=... (Distribution .provisionprofile)"; \
	    exit 1; \
	fi
	bash Scripts/dev-codesign.sh --profile distribution
	bash Scripts/dist-package.sh

.PHONY: dmg
dmg: ## wrap .build/release/Caterm.app in a UDZO dmg (run after `make dist`)
	# Optional env (mirrors build-dmg.sh):
	#   CATERM_DIST_VERSION    name suffix; default 1.0.0
	#   CATERM_DIST_IDENTITY   if set, sign the dmg with the same Developer ID
	#   CATERM_NOTARY_PROFILE  if set, notarize + staple the dmg
	bash Scripts/build-dmg.sh

.PHONY: release
release: ## full release pipeline: build + sign + notarize + staple + dmg (pass flags via ARGS=)
	# One command for the whole Distribution chain. Auto-resolves the
	# Developer ID identity + provisioning profile + notary keychain
	# profile; see Scripts/release.sh header for env overrides.
	#
	#   make release                       full notarized .app + .dmg
	#   make release ARGS=--skip-notary    signed-only (two-Mac smoke)
	#   make release ARGS=--skip-dmg       .app only, no disk image
	bash Scripts/release.sh $(ARGS)

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
