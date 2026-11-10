class_name PortraitCatalog
extends RefCounted
## Mock catalog of portrait customization options (icons, flairs, crowns).
## Entry ids are what gets persisted in the save "profile" domain; colors all
## come from the ThemeFactory palette. Replace with a data-driven resource
## when real content lands.

## Canonical texture paths (ART_MANIFEST.md, G2): generated placeholders live
## here; real art later drops onto the SAME paths at the SAME pixel sizes.
const ICONS_DIR: String = "res://assets/sprites/portraits/icons/"
const FLAIRS_DIR: String = "res://assets/sprites/portraits/flairs/"
const CROWNS_DIR: String = "res://assets/sprites/portraits/crowns/"

const ICONS: Array[Dictionary] = [
	{"id": "default", "color": ThemeFactory.COLOR_BLUE, "label_key": "portrait_classic"},
	{"id": "gold", "color": ThemeFactory.COLOR_GOLD, "label_key": "portrait_gold"},
	{"id": "silver", "color": ThemeFactory.COLOR_SILVER, "label_key": "portrait_silver"},
	{"id": "diamond", "color": ThemeFactory.COLOR_DIAMOND, "label_key": "portrait_diamond"},
	{"id": "ember", "color": ThemeFactory.COLOR_ORANGE, "label_key": "portrait_ember"},
	{"id": "forest", "color": ThemeFactory.COLOR_GREEN, "label_key": "portrait_forest"},
]

const FLAIRS: Array[Dictionary] = [
	{"id": "none", "type": "none", "label_key": "flair_none"},
	{"id": "ring_gold", "type": "ring", "color": ThemeFactory.COLOR_GOLD, "label_key": "flair_ring_gold"},
	{"id": "ring_blue", "type": "ring", "color": ThemeFactory.COLOR_BLUE, "label_key": "flair_ring_blue"},
	{"id": "banner_gold", "type": "banner", "color": ThemeFactory.COLOR_GOLD, "label_key": "flair_banner_gold"},
	{"id": "banner_blue", "type": "banner", "color": ThemeFactory.COLOR_BLUE, "label_key": "flair_banner_blue"},
	{"id": "capsule_gold", "type": "capsule", "color": ThemeFactory.COLOR_GOLD, "label_key": "flair_capsule_gold"},
	{"id": "capsule_blue", "type": "capsule", "color": ThemeFactory.COLOR_BLUE, "label_key": "flair_capsule_blue"},
]

const CROWNS: Array[Dictionary] = [
	{"id": "none", "icon": "", "label_key": "crown_none"},
	{"id": "crown_gold", "icon": "crown", "color": ThemeFactory.COLOR_GOLD, "label_key": "crown_gold"},
	{"id": "crown_silver", "icon": "crown", "color": ThemeFactory.COLOR_SILVER, "label_key": "crown_silver"},
	{"id": "crown_diamond", "icon": "crown", "color": ThemeFactory.COLOR_DIAMOND, "label_key": "crown_diamond"},
]


static func find_icon(id: String) -> Dictionary:
	for entry in ICONS:
		if str(entry.get("id", "")) == id:
			return entry
	return ICONS[0]


static func find_flair(id: String) -> Dictionary:
	for entry in FLAIRS:
		if str(entry.get("id", "")) == id:
			return entry
	return FLAIRS[0]


static func find_crown(id: String) -> Dictionary:
	for entry in CROWNS:
		if str(entry.get("id", "")) == id:
			return entry
	return CROWNS[0]


## Canonical texture paths for the G2 swap ("" = no file expected, e.g. the
## "none" flair). Callers check ResourceLoader.exists() before loading.
static func icon_texture_path(id: String) -> String:
	return ICONS_DIR + id + ".png"


static func flair_texture_path(id: String) -> String:
	return FLAIRS_DIR + id + ".png" if id != "none" else ""


static func crown_texture_path(id: String) -> String:
	return CROWNS_DIR + id + ".png" if id != "none" else ""
