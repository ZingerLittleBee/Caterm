LAST_CHOICE_FILE := .claude/.last-make-choice

.DEFAULT_GOAL := menu
.PHONY: menu dev dev-server dev-op dev-server-op build check-types tauri tauri-dev tauri-build check fix install db-push db-generate db-studio db-migrate db-start db-stop env-sync macos

ITEMS := \
	"dev           — Run Tauri desktop + server" \
	"dev-server    — Run server only" \
	"dev-op        — Run Tauri desktop + server (with 1Password)" \
	"dev-server-op — Run server only (with 1Password)" \
	"env-sync      — Sync .env to 1Password" \
	"tauri-dev     — Run Tauri desktop dev" \
	"build         — Build all packages" \
	"tauri-build   — Build Tauri desktop" \
	"check-types   — Type check all packages" \
	"check         — Lint check" \
	"fix           — Lint fix" \
	"macos-run-app — Build + sign + wrap + launch Caterm.app (default dev loop)" \
	"macos-run     — Build + sign bare binary (build smoke only — crashes on APS register)" \
	"macos-run-bg  — Launch macOS app in background" \
	"macos-build   — Build macOS app (debug)" \
	"macos-ghostty-kit — Init Ghostty submodule + build GhosttyKit" \
	"macos-test    — Run macOS Swift tests" \
	"macos-kill    — Kill running macOS dev process" \
	"macos-clean   — Clean macOS .build" \
	"macos-doctor  — Show macOS toolchain diagnostics" \
	"db-start      — Start PostgreSQL (Docker)" \
	"db-stop       — Stop PostgreSQL (Docker)" \
	"db-push       — Push schema to database" \
	"db-generate   — Generate migrations" \
	"db-migrate    — Run migrations" \
	"db-studio     — Open Drizzle Studio" \
	"install       — Install dependencies"

menu:
	@last=""; \
	if [ -f $(LAST_CHOICE_FILE) ]; then \
		last=$$(cat $(LAST_CHOICE_FILE)); \
	fi; \
	if [ -n "$$last" ]; then \
		choice=$$(printf '%s\n' $(ITEMS) | awk -v last="$$last" '{ if ($$1 == last) { found=$$0 } else { rest = rest $$0 "\n" } } END { if (found) print found; printf "%s", rest }' | gum choose --header "Select a command:"); \
	else \
		choice=$$(gum choose --header "Select a command:" $(ITEMS)); \
	fi; \
	target=$$(echo "$$choice" | awk '{print $$1}'); \
	if [ -n "$$target" ]; then \
		mkdir -p $$(dirname $(LAST_CHOICE_FILE)); \
		echo "$$target" > $(LAST_CHOICE_FILE); \
		$(MAKE) $$target; \
	fi

dev:
	bun run --filter server dev & bun run --filter web desktop:dev

dev-server:
	bun run --filter server dev

build:
	bun run --filter '*' build

check-types:
	bun run --filter '*' check-types

tauri:
	bun run --filter web tauri --

tauri-dev:
	bun run --filter web desktop:dev

tauri-build:
	bun run --filter web desktop:build

check:
	bun x ultracite check

fix:
	bun x ultracite fix

install:
	bun install

db-push:
	bun run --filter @Caterm/db db:push

db-generate:
	bun run --filter @Caterm/db db:generate

db-studio:
	bun run --filter @Caterm/db db:studio

db-migrate:
	bun run --filter @Caterm/db db:migrate

db-start:
	bun run --filter @Caterm/db db:start

db-stop:
	bun run --filter @Caterm/db db:stop

# Run with 1Password environment variables
dev-op:
	op run --env-file ./apps/server/.env.op -- bun run --filter server dev & \
	op run --env-file ./apps/server/.env.op -- bun run --filter web desktop:dev

dev-server-op:
	op run --env-file ./apps/server/.env.op -- bun run --filter server dev

# macOS app — delegates everything to apps/macos/Makefile.
# Usage: `make macos-run`, `make macos-test`, `make macos-clean`, ...
# `make macos` shows the macOS Makefile help.
macos:
	@$(MAKE) -C apps/macos help

.PHONY: macos-theme-catalog
macos-theme-catalog: macos-ghostty-submodule
	bash apps/macos/Scripts/build-theme-catalog.sh

.PHONY: macos-ghostty-kit
macos-ghostty-kit: macos-theme-catalog
	@$(MAKE) -C apps/macos ghostty-kit

macos-%:
	@$(MAKE) -C apps/macos $*

# Sync local .env to 1Password Caterm item
env-sync:
	@echo "Syncing .env to 1Password (Caterm)..."
	@op item delete "Caterm" --vault=Developer 2>/dev/null || true
	@op item create --vault=Developer --category="Server" --title="Caterm" \
		"DATABASE_URL[password]=$$(grep DATABASE_URL apps/server/.env | cut -d= -f2-)" \
		"BETTER_AUTH_SECRET[password]=$$(grep BETTER_AUTH_SECRET apps/server/.env | cut -d= -f2-)" \
		"BETTER_AUTH_URL[text]=$$(grep BETTER_AUTH_URL apps/server/.env | cut -d= -f2-)" \
		"CORS_ORIGIN[text]=$$(grep CORS_ORIGIN apps/server/.env | cut -d= -f2-)" \
		"ENCRYPTION_KEY[password]=$$(grep ENCRYPTION_KEY apps/server/.env | cut -d= -f2-)" \
		"NODE_ENV[text]=$$(grep NODE_ENV apps/server/.env | cut -d= -f2-)" \
		--tags="env,server,caterm"
	@echo "Done! Updated 1Password Developer/Caterm"
