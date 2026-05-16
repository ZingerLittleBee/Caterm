# Settings GUI — Manual Smoke

Run after every settings-related change. Refers to spec §9.2.

## Setup
- Build & run: `make run-app`
- Reset state to test migrations:
  ```bash
  rm -rf "$HOME/Library/Application Support/Caterm/settings.plist"
  rm -rf "$HOME/Library/Application Support/Caterm/per-host"
  ```

## Cases

1. **Fresh install (Migration C):** delete `settings.plist` and `~/Library/Application Support/Caterm/config`. Launch. ⌘, opens Preferences with defaults visible (SF Mono / 13 / Catppuccin Mocha / block / tabs titlebar). User config now contains only the placeholder comment.

2. **Migration A (legacy seed):** restore the legacy seed at `~/Library/Application Support/Caterm/config` (use the contents from `SettingsMigrationStep.legacyDefaultV1`); delete `settings.plist`. Launch. Backup file `config.bak-pre-settings-gui-…` created. User config replaced with placeholder. No visual change in any open tab.

3. **Migration B (custom user config):** seed a custom user config:
   ```
   font-family = JetBrains Mono
   font-family = SF Mono
   theme = light:Catppuccin Latte,dark:Catppuccin Mocha
   bell-features = audio,attention,no-title
   palette = 0=#000000
   ```
   Delete `settings.plist`. Launch. Banner appears listing representable + unrepresentable. Click **Import representable keys** → palette / fallback chain / split theme / custom bell-features all preserved; nothing single-line representable was found here so no lines removed. Edit a different config that *does* contain a representable single line (e.g., `cursor-style = bar`); after Import, that single line disappears; palette + fallback remain.

4. **Live: font size** → all open tabs reflow live.
5. **Live: cursor style** → live update on all tabs.
6. **Live: theme** → live update globally.
7. **Per-host theme:** in HostForm, set host A theme to Dracula. Connect to A → tab uses Dracula. Disconnect, reconnect → still Dracula. Connect to B (no override) → uses global theme.
8. **Global change while host-overridden tab open:** host-overridden tab keeps its theme; new tab to any host uses new global.
9. **Scrollback (new-surface):** change scrollback memory → banner "Scrollback change applies to new tabs." appears once. Existing tabs keep old buffer; new tab uses new size.
10. **Titlebar (new-surface):** change titlebar style → banner appears; existing windows unchanged; new window opened with ⌘N has new style.
11. **Diagnostics:** edit user config to add `font-family = ` (empty) and a deliberately unknown key. Open Preferences; diagnostic banner lists messages.
12. **Edit advanced:** click Edit Advanced Config → user config opens in Finder.
13. **Quit during edit:** type in stepper, ⌘Q within 200 ms → on relaunch, change is persisted.
14. **Theme picker:** ⌘, → Themes tab → 9 favorites visible above the fold; "All Themes" grid scrollable; search filters.
15. **Corruption recovery:** write garbage to `settings.plist` while app is closed. Launch. Defaults seeded; original quarantined to `settings.plist.broken-…`.
16. **Override hint:** add `cursor-style = underline` to user config; relaunch. Terminal tab footer shows "1 user-config override active".
