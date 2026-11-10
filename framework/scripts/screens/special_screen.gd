class_name SpecialScreen
extends BaseSpecialScreen
## Default Special screen content: a placeholder title + body. Prototypes
## branch the repo and replace this file (GDD §7 / TDD §4).

var _title: Label = null
var _body: Label = null


func _build_special_content(host: Control) -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_top", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_right", ThemeFactory.CONTENT_MARGIN)
	margin.add_theme_constant_override("margin_bottom", ThemeFactory.CONTENT_MARGIN)
	# Pin to full rect: an unanchored container shrinks to minimum size at top-left.
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	_title = Label.new()
	_title.text = tr("special_title")
	_title.theme_type_variation = &"LabelTitle"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_title)

	_body = Label.new()
	_body.text = tr("special_body")
	_body.theme_type_variation = &"LabelDim"
	_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_body)


func _refresh_special_content() -> void:
	if _title != null:
		_title.text = tr("special_title")
	if _body != null:
		_body.text = tr("special_body")
