.DEFAULT_GOAL := tauri-dev
.PHONY: dev build check-types tauri tauri-dev tauri-build check fix install

dev:
	bun run --filter '*' dev

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
