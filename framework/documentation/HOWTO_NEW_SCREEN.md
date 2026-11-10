# HOW-TO — Adding a New Screen (ROADMAP C3)

The complete recipe for adding a screen to the framework, verified end-to-end
on 2026-11-05 by building a throwaway `TplCheckScreen` through every step below
(new id → factory arm → BaseScreen subclass → NAV_ORDER entry → EventBus
navigation → cached mount) and deleting it after the gate was green.

A screen = one new file + four one-line edits + translation keys + one test
file. No scene files, no registration lists beyond the ones named here.

## Steps

### 1. Screen id — `core/screen_ids.gd`
Add a constant (PascalCase name, lowercase string value):
```gdscript
const MYSCREEN: StringName = &"myscreen"
```
If the screen must hide ALL shell chrome (header/nav/zones/banner), add it to
`is_fullscreen()` in the same file. Normal screens need nothing else here.

### 2. The screen class — `scripts/screens/my_screen.gd` (new file)
Subclass `BaseScreen`, override `_build_ui()` (called exactly once per instance,
even across tree re-entries) and `_apply_locale()` (re-runs on language switch).
Use the verified template below. Rules:
- **Pin the root container full-rect BEFORE `add_child`** — unanchored Controls
  collapse to minimum size at top-left (TDD §4 layout contract).
- Colors/margins from `ThemeFactory` only; text via `tr("key")`.
- `class_name MyScreen` — then run the import pass (step 6) before anything
  references it.
- Screens are cached and NEVER freed by ScreenManager: state variables survive
  navigation; `_ready()` re-fires on every re-entry, so never build UI there.

Verified template (this exact shape was exercised end-to-end):
```gdscript
class_name MyScreen extends BaseScreen
## One-line description of what the screen shows/does.

var _title: Label = null
var _body: Label = null


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_right", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_top", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_bottom", ThemeFactory.CONTENT_MARGIN)
	# Pin to full rect: an unanchored container shrinks to minimum size at top-left.
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	_title = Label.new()
	_title.theme_type_variation = &"LabelTitle"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title)

	_body = Label.new()
	_body.theme_type_variation = &"LabelDim"
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size.x = 300.0
	vbox.add_child(_body)


func _apply_locale() -> void:
	_title.text = tr("my_screen_title")
	_body.text = tr("my_screen_body")
```
(For tabbed screens, see `profile_screen.gd`/`social_screen.gd`: pages live in
plain hosts and each page is pinned full-rect before `add_child` — same contract,
one level deeper.)

### 3. Factory arm — `core/screen_manager.gd`
One match arm in `_create_screen()`:
```gdscript
		ScreenIds.MYSCREEN:
			return MyScreen.new()
```
Without this, navigation warns `"no screen implementation for 'myscreen'"` and
keeps the current screen.

### 4. Nav entry (optional) — `scripts/ui/screen_shell.gd`
Insert the id into `NAV_ORDER` at its tab position (order = left→right on the
nav bar). The label key is derived automatically: `"nav_" + str(screen_id)` →
`nav_myscreen`. Fullscreen screens are NOT in NAV_ORDER.

### 5. Translations — `assets/translations/en.po` + `es.po`
Add EVERY key the screen uses, in BOTH files (both carry `Language:` headers —
keep them). Minimum: `nav_myscreen` (only if it has a nav entry) + all content
keys. A missing key is not an error: `tr()` returns the key itself, which makes
missing translations visible at a glance but easy to ship accidentally.

### 6. Import pass (new class_name)
```bash
~/tools/godot --headless --path . --import
```
The global class cache only refreshes on import; skipping this gives cascading
"Could not find type MyScreen" parse errors in every file parsed after it.

### 7. Tests — `tests/test_my_screen.gd` (new file)
Two patterns, both proven:

(a) **Direct mount** (content/layout; no shell needed):
```gdscript
extends GutTest

var _host: Control


func before_all() -> void:
	_host = Control.new()
	_host.custom_minimum_size = Vector2(720, 1280)   # phone-sized content area
	_host.size = Vector2(720, 1280)
	add_child(_host)


func after_all() -> void:
	if is_instance_valid(_host):
		_host.queue_free()


func test_my_screen_renders_content() -> void:
	var screen := MyScreen.new()
	_host.add_child(screen)
	await _settle_layout()
	assert_eq(screen._title.text, tr("my_screen_title"), "localized title rendered")
	screen.queue_free()
	await get_tree().process_frame


func _settle_layout(frames: int = 5) -> void:
	for i in frames:
		await get_tree().process_frame
```

(b) **Navigation through ScreenManager** (id/factory/nav wiring): attach once in
`before_all`, emit `EventBus.navigation_requested`, assert the content host's
child is your class and the chrome state matches (see `test_screen_manager.gd`).
If the test file attaches its own host, remember the cross-file singleton
hygiene reset documented in NOTES.md when other files re-attach.

### 8. Gate
`tools/gate.sh` → green. That's it.

## Pitfalls (all hit before, all documented)
| Pitfall | Consequence if violated |
|---|---|
| Root container not pinned before `add_child` | Content renders as a small block in the top-left corner |
| `set_anchors_preset()` after tree entry | Control locked to 0×0 forever (Godot 4.7 back-computed offsets) |
| New class_name without an import pass | "Could not find type X" cascades across the project |
| Missing es.po key | Spanish UI silently shows raw keys |
| Building UI in `_ready()` instead of `_build_ui()` | UI duplicated on every navigation back (screens are cached/reused) |
| `get_node()` in per-frame code | Slowdown + breaks when layout changes; cache refs in `_build_ui()` |

## Checklist
- [ ] `ScreenIds.MYSCREEN` const (+ `is_fullscreen()` if chrome-less)
- [ ] `scripts/screens/my_screen.gd` from the template (pinned root, ThemeFactory, tr())
- [ ] Factory arm in `ScreenManager._create_screen()`
- [ ] `NAV_ORDER` entry (optional; label key `nav_myscreen` auto-derived)
- [ ] en.po + es.po keys
- [ ] `--import` pass clean
- [ ] `tests/test_my_screen.gd` (mount and/or navigation pattern)
- [ ] `tools/gate.sh` green
