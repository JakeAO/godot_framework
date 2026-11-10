class_name AdMobBackend
extends RefCounted
## Thin adapter over the vendored poingstudios/godot-admob-plugin (v5.1.0,
## MIT) in addons/admob/. Exposes only what AdManager needs: a banner load
## bridge and a fire-and-forget rewarded watch.
##
## Platform behavior of the plugin (see gdscript/src/core/MobileSingletonPlugin):
## - Android/iOS exports: native GMA SDK singletons (Engine.has_singleton).
## - Editor runs: built-in mock plugins (fake creatives, no network).
## - Desktop/headless runtime: null -> every call is a silent no-op.
## AdManager only routes here on mobile with the remote flag set, so the
## hermetic gate never touches this file's live paths.


class _BannerBridge extends RefCounted:
	## One-shot signal bridge so AdManager can await the plugin's callbacks.
	signal completed(ok: bool)
	var view: Object = null
	var _fired := false


	static func create(view_: Object) -> _BannerBridge:
		var bridge := _BannerBridge.new()
		bridge.view = view_
		return bridge


	func _fire(ok: bool) -> void:
		if _fired:
			return
		_fired = true
		completed.emit(ok)


class _RewardState extends RefCounted:
	## Object box so every lambda shares one settled flag (GDScript lambdas
	## capture plain variables by value, which would break a shared bool).
	var settled := false


	static func finish(state: _RewardState, on_result: Callable, ok: bool) -> void:
		if state.settled:
			return
		state.settled = true
		if on_result.is_valid():
			on_result.call(ok)


## True only on the mobile platforms where a native GMA SDK can exist.
## (OS.get_name() in [...] instead of OS.has_name(): the latter does not parse
## inside static functions on Godot 4.7.)
static func is_supported_platform() -> bool:
	return OS.get_name() in ["android", "ios"]


## True when the exported build actually carries the native AdMob singletons.
static func has_native_sdk() -> bool:
	return Engine.has_singleton("PoingGodotAdMob")


static func ensure_initialized() -> void:
	if not has_native_sdk():
		return
	MobileAds.initialize()


## Creates and loads a bottom banner ad. Returns a bridge; await its
## `completed` signal (or race it against a timeout) for the ok bool. The
## caller must keep the bridge referenced until it fires.
static func load_banner(unit_id: String) -> _BannerBridge:
	ensure_initialized()
	var view := AdView.new(unit_id, AdSize.BANNER, AdPosition.BOTTOM)
	var bridge := _BannerBridge.create(view)
	view.ad_listener.on_ad_loaded = func() -> void: bridge._fire(true)
	view.ad_listener.on_ad_failed_to_load = func(_error: LoadAdError) -> void:
		bridge._fire(false)
	view.load_ad(AdRequest.new())
	return bridge


## Loads, shows and settles a rewarded video. `on_result` is called exactly
## once with true (reward earned) or false (load failed / dismissed early).
static func watch_rewarded(unit_id: String, on_result: Callable) -> void:
	ensure_initialized()
	var state := _RewardState.new()
	var loader := RewardedAdLoader.new()
	var load_callback := RewardedAdLoadCallback.new()
	load_callback.on_ad_loaded = func(ad: RewardedAd) -> void:
		var earned := OnUserEarnedRewardListener.new()
		earned.on_user_earned_reward = func(_item: RewardedItem) -> void:
			_RewardState.finish(state, on_result, true)
			ad.destroy()
		ad.full_screen_content_callback.on_ad_dismissed_full_screen_content = \
			func() -> void:
				_RewardState.finish(state, on_result, false)
				ad.destroy()
		ad.show(earned)
	load_callback.on_ad_failed_to_load = func(_error: LoadAdError) -> void:
		_RewardState.finish(state, on_result, false)
	loader.load(unit_id, AdRequest.new(), load_callback)
