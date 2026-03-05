LAST_CHOICE_FILE := .claude/.last-make-choice

.DEFAULT_GOAL := menu
.PHONY: menu dev dev-server build check-types tauri tauri-dev tauri-build check fix install db-push db-generate db-studio db-migrate db-start db-stop

ITEMS := \
	"dev           — Run Tauri desktop + server" \
	"dev-server    — Run server only" \
	"tauri-dev     — Run Tauri desktop dev" \
	"build         — Build all packages" \
	"tauri-build   — Build Tauri desktop" \
	"check-types   — Type check all packages" \
	"check         — Lint check" \
	"fix           — Lint fix" \
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
