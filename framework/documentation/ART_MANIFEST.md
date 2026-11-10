# ART_MANIFEST — asset inventory & 1:1 swap doctrine (Phase G)

Created 2026-11-08 (G1). This is the canonical inventory of every visual asset
category in the prototype, with per-asset **canonical path / size / 9-slice
notes / usage sites / swap rules**. It exists so a real art pass can drop files
in with **zero code changes**.

## Doctrine

1. **Canonical paths are the swap points.** Every consumer resolves assets by
   a fixed `res://` path (or a static catalog helper that returns one). Real
   art replaces a placeholder at the **same path** and the **same pixel size**;
   nothing in code changes.
2. **Texture-first, code-drawn fallback.** `ProtoIcon` and `PortraitView` load
   the canonical texture when it exists and fall back to the original
   geometric drawing (ThemeFactory palette) when the file is missing — a
   deleted asset degrades gracefully instead of bricking a screen.
3. **The generator owns placeholder files only.** `tools/gen_placeholders.py`
   writes exclusively inside its five placeholder directories. It never
   touches real art (`ui_generic/`, `team_banners/`, offer frame dirs).
   **Once real art replaces a placeholder, do NOT re-run the generator for
   that category** — it would overwrite the real file.
4. **Sizes are pinned by tests.** `tests/test_art_placeholders.gd` asserts the
   exact pixel size of every generated placeholder and the registry routing;
   swap art must keep the stated sizes (or update the test deliberately).

## Palette (ThemeFactory, scripts/ui/theme_factory.gd)

| Name | Hex | Use |
|---|---|---|
| COLOR_BG / COLOR_INK | `#10141f` | app background; text on gold/blue fills |
| COLOR_PANEL | `#1b2233` | panel/button fills |
| COLOR_GOLD | `#f5c542` | primary action, trophy/coin/crown/bell/info/warning |
| COLOR_BLUE | `#4f8cff` | secondary action, xp/booster/shield/music/chat/team |
| COLOR_TEXT | `#eef2fb` | body text, search/sfx speaker |
| COLOR_TEXT_DIM | `#9aa7c7` | dimmed text, bank jar body |
| COLOR_SILVER | `#c7cfdd` | silver tier |
| COLOR_DIAMOND | `#6fd3f2` | gem / diamond tier |
| COLOR_GREEN | `#58c470` | success/check, forest tier |
| COLOR_ORANGE | `#e8973a` | ember tier, orange dialog band |

Placeholder PNGs are drawn from exactly these colors (see the palette block in
`tools/gen_placeholders.py`, kept in sync manually).

## Generator

```
python3 tools/gen_placeholders.py [icons|portraits|backgrounds ...]   # no args = all
```

Same tooling style as `tools/split_banner_sheets.py` (PIL, stdlib-only beyond
PIL). Geometry mirrors `scripts/ui/proto_icon.gd` unit-for-unit, drawn at 2x
and LANCZOS-downsampled for antialiased edges. Refuses to run over an existing
empty file; prints every path it writes.

## A. Currency / nav / event icons — GENERATED (20 × 128×128)

`assets/sprites/icons/<key>.png`, transparent-background silhouettes. Resolved
by `ProtoIcon` (`scripts/ui/proto_icon.gd`) as `<key>.png`; missing file →
code-drawn fallback shape of the same geometry. Tint: while a texture is
active the tint rides on `modulate`; on the fallback path it tints per-shape.
**"No tint" is detected by equality with `Color()`** — Godot 4.7's `Color()`
defaults to opaque black (alpha 1.0), never transparent.

| Key | Color(s) | Config usage (`resources/config/remote_config.json` `icon` fields) |
|---|---|---|
| trophy | gold | event: weekend tournament |
| xp | blue | streak / XP rewards |
| coin | gold (+dark inner) | currency, shop prices, streak recovery |
| gem | diamond (+white facet line) | premium currency |
| gift | gold + ink ribbon | daily gift event/offer |
| bank | dim + ink slot | piggy bank offer/event |
| booster | blue + white cross | shop booster items |
| crown | gold | tier/cosmetic rewards, portrait crowns (code fallback) |
| shield | blue | shield/protect items |
| pile | gold boxes | gift-pile event icon |

Also defined (UI chrome, not currently in config): `chat`, `team`, `search`,
`info`, `warning`, `check`, `bell`, `music`, `sfx`, `support`.

**Usage sites & render sizes:**

| Site | Size | Notes |
|---|---|---|
| Home zone widgets (screen_shell.gd) | 56px (`ICON_SIZE`) | left/right event/offer columns |
| Shop rows (shop_screen.gd) | 40px (`ROW_ICON_SIZE`) | product icon per `shop_items[].icon` |
| Shop price icons (shop_screen.gd) | 16px (`PRICE_ICON_SIZE`) | coin/gem next to price |
| Toasts (toast_host.gd) | 20px | notification kind icons |
| Long-press tooltips (tooltip_host.gd) | 18px | widget info tooltips |
| Portrait crowns (portrait_view.gd) | `host_size × 0.42` | only while the crown *texture* is absent; tinted with the catalog color |

**Swap rules:** replace `<key>.png` at 128×128 (any aspect works — it's drawn
into a square rect, but keep 1:1 to avoid stretching). Keep transparency.
Add a new key = add a match arm in `proto_icon.gd` + an entry in the test's
`_ICON_KEYS` list + the placeholder file.

## B. Portraits / flairs / crowns — GENERATED (15 files)

Resolved by `PortraitCatalog` static helpers (`scripts/ui/portrait_catalog.gd`):
`icon_texture_path(id)` / `flair_texture_path(id)` / `crown_texture_path(id)`;
id `"none"` → `""` (no file, code-drawn/absent path).

| Set | Path | Size | Files |
|---|---|---|---|
| Avatar icons | `assets/sprites/portraits/icons/<id>.png` | 128×128 | default, gold, silver, diamond, ember, forest |
| Flairs | `assets/sprites/portraits/flairs/<id>.png` | 128×128 | ring_gold, ring_blue, banner_gold, banner_blue, capsule_gold, capsule_blue |
| Crowns | `assets/sprites/portraits/crowns/<id>.png` | 96×96 | crown_gold, crown_silver, crown_diamond |

**Composite geometry (portrait_view.gd):** the portrait is a square avatar of
`host_size` plus a crown row of `host_size × 0.32` below it (`CROWN_ROW_RATIO`).
Texture layers are anchored inside the **avatar square**: icon fills the whole
square; banner flairs sit at y-anchors 0.42–0.58 (the placeholder band is drawn
at 10–26% of the canvas to match); crowns render centered in the crown row at
`host_size × 0.42`.

**Swap rules:** keep sizes (tests pin them). Flair files are transparent
overlays — only the decorative element should be opaque. The code-drawn
fallbacks (initials disc / colored flair panel / geometric crown) stay in place
for missing files and for id `"none"`.

## C. Backgrounds — GENERATED (1 file)

| File | Size | Notes |
|---|---|---|
| `assets/sprites/backgrounds/bg_default.png` | 720×1560 | device reference size; vertical gradient `#171e2e → #0d1119` |

**Swap rules:** replace at the same 720×1560 (or any size — it's stretched to
fill; keep aspect close to portrait phones).

## D. UI chrome — REAL art, registered in theme (`assets/sprites/ui_generic/`, 18 files)

9-sliced `StyleBoxTexture` type variations built by
`ThemeFactory._theme_art_styles()`. Slice cuts (natural px) live as constants
in theme_factory.gd:

| Variation(s) | File(s) | Slice L/T/R/B | Wired? |
|---|---|---|---|
| ButtonBlue/Green/Grey/Orange/Red | `Btn_<Color>.png` + `Btn_<Color>_Pressed.png` (10 files) | 140 / 26 (pressed 30) all sides | **No** — registered only |
| PanelDialogBlue / PanelDialogGreen | `Dialog_Blue_TwoTone.png`, `Dialog_Green_TwoTone.png` | 160 / 240 / 160 / 60 | **Yes** (Blue, via `UISkins.DIALOG_PANEL`) |
| PanelDialogOrange | `Dialog_Orange.png` | 200 / 150 / 200 / 100 | No — registered only |
| PanelDialogOrangeTwoTone | `Dialog_Orange_TwoTone.png` | 160 / 240 / 160 / 60 | No — registered only |
| TabContainerBlue/Green/Orange/Red | `TabContainer_<Color>.png` (4 files) | 60 / 90 / 60 / 30 | **No** — registered only |

Content margins are deliberately left unset on the dialog styleboxes: they fall
back to the slice cuts, which ARE the art's insets (glass walls / header band).

**Wiring status (2026-11-06 art review):** only `UISkins.DIALOG_PANEL =
&"PanelDialogBlue"` is consumed (by DialogHost). The button and tab-container
artworks are blob silhouettes that 9-slice badly onto our wide-short buttons
and full-screen portrait tab containers, so those controls use the **flat
theme** (StyleBoxFlat from the palette above). The variations stay registered
(pinned by `tests/test_ui_art_styles.gd`) for future use at sizes that fit.

**Swap rules:** real button/tab art must be redrawn as proper 9-slice frames
before wiring; then flip the role in `UISkins` (one line per role) — screens
never reference raw variation names. Dialog swaps just replace the PNG at the
same path/size and re-measure the slice constants if the frame changes.

## E. Team banners — REAL art + runtime LUTs (`assets/sprites/team_banners/`)

- `bases/base_01…90.png` (90 × 256×512) and `icons/icon_01…90.png` (90, native
  sizes) — grayscale sheet-split artwork from `tools/split_banner_sheets.py`.
- Palettes: **no PNGs on disk** — 48 LUTs (12 hue families × 4 styles) are
  generated as data in `TeamBannerCatalog._lut_colors()` and turned into a
  16×1 `ImageTexture` at runtime (`get_lut_texture`, cached by id).
- Pipeline: grayscale sprite → `banner_lut.gdshader` palette LUT.

**Swap rules:** replace files at the same paths with the same sizes — catalog
and shader unchanged (same doctrine as ProtoIcon). Unknown ids warn and fall
back to the first entry; they never brick rendering.
⚠️ `tools/generate_team_banners.gd` is **OBSOLETE — DO NOT RUN** (it predates
the real sheet-split art and would overwrite it).

## F. Offer sprites — REAL frame art (`assets/sprites/`)

| Set | Frames | Resource |
|---|---|---|
| Gift | `gift_sprite_individual_frames/idle_01…06.png` + `opening_01…07.png` @ 5fps | `gift.tres` (SpriteFrames) |
| Piggy bank | `piggybank_individual_frames/idle_01…06.png` + `opening_01…07.png` @ 5fps | `piggybank.tres` (SpriteFrames) |

**Routing:** `OfferSpriteWidget.frames_path_for_icon(icon_key)`
(scripts/ui/offer_sprite_widget.gd) is the **single source of truth** —
`"gift"` → gift.tres, `"bank"` → piggybank.tres, anything else → `""` (caller
falls back to a ProtoIcon). Home zone widgets and in-dialog opening clips both
route through it.

**Swap rules:** new offer art = new frame dir + a `.tres` SpriteFrames resource
+ one registry line in `frames_path_for_icon`. ⚠️ `piggybank.tres` was created
by hand in the editor — do not regenerate or "fix" it from a script.

## G. Categories with no art files yet (planned swap points)

| Category | Current rendering | Future swap point |
|---|---|---|
| Ad creatives (banner slot) | `BannerAdSlot` fills a flat rect from the creative's `color_hex` (remote config) | add a TextureRect + canonical creative path per ad id; keep the color fill as fallback |
| Panels / cards / zone frames | flat `StyleBoxFlat` from palette (Panel, PanelZone, PanelAvatar, PanelTooltip) | 9-slice PNGs + theme variations, wired through `UISkins` roles like DIALOG_PANEL |
| Toggles / sliders / progress | flat styleboxes (ProgressBar track `#0d1119`, fill gold) | same pattern: art files + slice constants in ThemeFactory |
| Empty states | text-only Label ("Nothing here yet"-style) | optional illustration PNGs per empty state; text stays as fallback |

## Quick swap checklist (real art arrives)

1. Drop file at the canonical path, **same pixel size**.
2. If 9-sliced: verify/update slice constants in theme_factory.gd.
3. If a new key/id: add the catalog entry + match arm + test list entry.
4. Run `bash tools/gate.sh` — `test_art_placeholders.gd` pins sizes/paths.
5. **Never** re-run `gen_placeholders.py` for a category that now has real art.
