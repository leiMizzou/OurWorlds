# Bilingual UI (中文 / English) — Design

**Date:** 2026-06-07
**Status:** Approved (brainstormed), implementing.
**Scope (this phase):** ALL user-facing **UI** strings (menus + HUD + chat + prompts) become switchable 中文/English with a one-click toggle. World content (region names, block names, descriptions, build-template labels) stays Chinese for a later phase.

## Goal
A 语言/Language control in the settings/pause menu that instantly switches the whole interface between 中文 and English, persisted across sessions, defaulting to the OS locale.

## Mechanism (runtime dictionary — headless/export-safe)
Godot's editor-imported `.csv`/`.po` translations are unreliable for a project built headless + via `--export`. Instead:
- **`i18n/ui_strings.json`** — `{ "KEY": {"zh": "…", "en": "…"}, … }`, loaded at runtime via `FileAccess.open("res://i18n/ui_strings.json")` (readable in editor, headless, and inside the exported `.pck`).
- **`scripts/Locale.gd` (autoload `Locale`)**:
  - `t(key: String) -> String` — returns the string for the current language; falls back to the other language, then the key itself.
  - `set_language(lang: String)` — `"zh"|"en"`; updates current lang, persists to settings, emits `language_changed`.
  - `current() -> String`; `available() -> ["zh","en"]`.
  - `init(saved)` — default = saved preference, else OS locale (`OS.get_locale()` starts with `zh` → `zh`, else `en`).
  - Registered as an autoload in `project.godot` so any script can call `Locale.t(...)`.
- **UI files** — replace hardcoded Chinese with `Locale.t("KEY")`; each UI gains `_retranslate()` (re-applies its labels) called on build **and** connected to `Locale.language_changed` → instant switch with no reload.
- **Toggle** — an option/button in the settings (pause menu) calls `Locale.set_language(...)`. Persisted via the existing `settings.json` (`language` key).

## Components / decomposition (implementation tasks)
1. **Framework + toggle** — `Locale` autoload + `ui_strings.json` (seeded with the settings/menu keys) + `project.godot` autoload + a 中文/English control in the settings/pause menu + persistence + OS-default. Unit test `tests/test_locale.gd`.
2. **Migrate menus** — PauseMenu, TitleScreen, NetMenu, LoginScreen: extract strings → `ui_strings.json` (zh from current text + en) → `Locale.t()` + `_retranslate()`.
3. **Migrate in-game UI** — HUD, ChatPanel, build/action prompts/toasts: same migration.

## Testing
- `tests/test_locale.gd`: `set_language` flips `t(KEY)` zh↔en; persistence round-trip; OS-locale default; missing-key fallback returns the key.
- Regression: existing UI tests (`test_pause_menu`, `test_chat_panel`, `test_net_menu`, `test_login_screen`, `test_title_screen`, `test_hud_*`) must stay green; update them only where they assert exact Chinese text (prefer asserting via `Locale.t(key)` or that the label is non-empty).
- Full suite (`bash tests/run_all.sh`) green.

## Out of scope (later phase)
World/region/block/template names + descriptions; right-to-left languages; per-string pluralization.

## Notes
Visible result (toggle + English UI) appears after relaunching the native client and re-exporting the web build.
