.DEFAULT_GOAL := menu
.PHONY: menu dev dev-server dev-web build check-types tauri tauri-dev tauri-build check fix install db-push db-generate db-studio db-migrate db-start db-stop

menu:
	@choice=$$(gum choose --header "Select a command:" \
		"dev           — Run all packages in dev mode" \
		"dev-server    — Run server only" \
		"dev-web       — Run web only" \
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
		"install       — Install dependencies") && \
	target=$$(echo "$$choice" | awk '{print $$1}') && \
	$(MAKE) $$target

dev:
	bun run --filter '*' dev

dev-server:
	bun run --filter server dev

dev-web:
	bun run --filter web dev

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
