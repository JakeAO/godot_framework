class_name ScreenIds
extends RefCounted
## Central registry of screen ids used by navigation, analytics and saves.

const HOME: StringName = &"home"
const PROFILE: StringName = &"profile"
const SOCIAL: StringName = &"social"
const SPECIAL: StringName = &"special"
const SETTINGS: StringName = &"settings"
const GAME: StringName = &"game"
const RESULTS: StringName = &"results"
## Not in the bottom nav — opened by tapping the Coins widget in the header.
const SHOP: StringName = &"shop"
## Not in the bottom nav — opened from its left-zone widget (Phase F3).
const GIFT_PILE: StringName = &"gift_pile"

## Fullscreen screens hide all shell chrome (header, nav, zones, banner).
static func is_fullscreen(screen_id: StringName) -> bool:
	return screen_id == GAME or screen_id == RESULTS or screen_id == GIFT_PILE
