# theme_manager.gd (ThemeManager autoload)
#
# Holds the interface palette: the presets of theme/presets/*.json, the one the player
# has chosen, and the tokens the interface is drawn with. The palette is written into
# the PROJECT theme — the single resource the engine hands to every Control — so the
# standard controls (buttons, inputs, bars, tabs, scrollbars, popups) follow the choice
# without a scene being rebuilt. The resource is edited in place and never replaced:
# FontManager writes the fonts into the same instance.
#
# A preset is data, not code: a JSON file dropped into the folder becomes a choice
# without a line of code. The whole palette is replaced at once — a missing token is not
# filled with a default grey, because a half-themed interface cannot be told apart from
# a bug (see validate_preset).
#
# The chosen preset is a player PREFERENCE, not a part of a save: it lives in
# user://settings.cfg next to the language and the font, and is applied at start.
extends Node

const UI_THEME = preload("res://scripts/ui_theme.gd")
const UI_ICONS = preload("res://scripts/ui_icons.gd")

const PRESET_DIR := "res://theme/presets"
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "interface"
const SETTINGS_KEY := "theme"

# The preset taken when nothing is chosen, or when the chosen one is gone. Its colours
# are the colours the interface had before the palette existed, so the default look is
# the familiar one.
const DEFAULT_PRESET := "classic"

# Every token a preset must define. "chrome" is the surface of the interface, "data" is
# the meaning of a value (a price, a quality level, a profitable or a lossy rate): the
# second group changes with the theme too, because the colours of the data are tuned for
# the background they lie on.
const CHROME_TOKENS: Array[String] = [
    "panel_bg", "panel_border",
    "control_bg", "control_hover", "control_pressed", "control_disabled",
    "control_border", "control_border_disabled",
    "text", "text_secondary", "text_muted", "info",
    "accent", "accent_hover", "accent_text",
    "field_bg", "field_border", "focus_border",
    "track", "fill",
    "tab_active_bg", "tab_active_text",
    "tooltip_bg", "tooltip_border",
    "scrollbar", "scrollbar_hover",
    "hairline", "row_hover", "row_selected",
    # "scrim" darkens the world behind a modal window, "row_dim" is a modulate MULTIPLIER
    # for a whole row that is unavailable — the two colours the interface applies to what
    # it does not draw. Their values are tuned per palette because a multiplier over a dark
    # surface crushes it to black, while over a light one only greys it.
    "scrim", "row_dim",
]
const DATA_TOKENS: Array[String] = ["price", "quality", "income", "expense", "warning"]
const METRIC_TOKENS: Array[String] = ["panel_radius", "control_radius"]

# Emitted after the palette is replaced. The signals carries no data: the listeners ask
# the manager for the tokens themselves, so a listener cannot end up with a stale copy.
signal theme_applied

var current_id: String = ""
var _presets: Dictionary = {}
var _palette: Dictionary = {}
var _metrics: Dictionary = {}

func _ready() -> void:
    rescan()
    apply_stored_preset()

# Reads the folder again. A file that does not parse, or lacks a token, is reported and
# skipped as a whole — one broken preset must not leave the rest unloadable.
func rescan() -> void:
    _presets.clear()
    var dir := DirAccess.open(PRESET_DIR)
    if dir == null:
        push_warning("ThemeManager: cannot open %s" % PRESET_DIR)
        return
    var names := dir.get_files()
    names.sort()
    for file_name in names:
        if not file_name.ends_with(".json"):
            continue
        var preset := _read_preset(PRESET_DIR.path_join(file_name))
        if preset.is_empty():
            continue
        var id := str(preset["id"])
        if _presets.has(id):
            push_warning("ThemeManager: the preset id \"%s\" is used twice; %s is ignored"
                % [id, file_name])
            continue
        _presets[id] = preset

func _read_preset(path: String) -> Dictionary:
    var text := FileAccess.get_file_as_string(path)
    if text.is_empty():
        push_warning("ThemeManager: %s is empty or unreadable" % path)
        return {}
    var parsed = JSON.parse_string(text)
    if typeof(parsed) != TYPE_DICTIONARY:
        push_warning("ThemeManager: %s is not a JSON object" % path)
        return {}
    var problems := validate_preset(parsed)
    if not problems.is_empty():
        push_warning("ThemeManager: %s is ignored — %s" % [path, "; ".join(problems)])
        return {}
    return parsed

# The problems that make a preset unusable, as readable lines. An empty result means the
# preset may be loaded.
static func validate_preset(preset: Dictionary) -> Array[String]:
    var problems: Array[String] = []
    var id := str(preset.get("id", ""))
    if id.is_empty():
        problems.append("no id")
    elif not _is_identifier(id):
        problems.append("the id \"%s\" may only hold a-z, 0-9, _ and -" % id)
    if str(preset.get("name_key", "")).is_empty():
        problems.append("no name_key")
    for section in [["chrome", CHROME_TOKENS], ["data", DATA_TOKENS]]:
        var block = preset.get(section[0], null)
        if typeof(block) != TYPE_DICTIONARY:
            problems.append("no \"%s\" object" % section[0])
            continue
        for token in section[1]:
            if not block.has(token):
                problems.append("no \"%s\"" % token)
            elif parse_color(block[token]) == null:
                problems.append("\"%s\" is not a #RRGGBB or #RRGGBBAA colour" % token)
    var metrics = preset.get("metrics", null)
    if typeof(metrics) != TYPE_DICTIONARY:
        problems.append("no \"metrics\" object")
    else:
        for token in METRIC_TOKENS:
            if not metrics.has(token):
                problems.append("no \"%s\"" % token)
            elif typeof(metrics[token]) != TYPE_INT and typeof(metrics[token]) != TYPE_FLOAT:
                problems.append("\"%s\" is not a number" % token)
            elif float(metrics[token]) < 0.0:
                problems.append("\"%s\" is negative" % token)
    return problems

static func _is_identifier(value: String) -> bool:
    for i in value.length():
        var c := value.unicode_at(i)
        var is_lower: bool = c >= 97 and c <= 122
        var is_digit: bool = c >= 48 and c <= 57
        if not (is_lower or is_digit or c == 95 or c == 45):
            return false
    return true

# A colour token: "#RRGGBB" or "#RRGGBBAA". null for anything else — the caller decides
# whether that is a broken preset (validate_preset) or a fallback.
static func parse_color(value) -> Variant:
    if typeof(value) != TYPE_STRING:
        return null
    var text := str(value).strip_edges()
    if not text.begins_with("#"):
        return null
    var digits := text.substr(1)
    if digits.length() != 6 and digits.length() != 8:
        return null
    if not digits.is_valid_hex_number():
        return null
    var alpha := 255
    if digits.length() == 8:
        alpha = digits.substr(6, 2).hex_to_int()
    return Color8(digits.substr(0, 2).hex_to_int(),
        digits.substr(2, 2).hex_to_int(),
        digits.substr(4, 2).hex_to_int(), alpha)

# The presets on disk, in a stable order, as {id, name_key}. name_key is a translation
# key: the label of the choice follows the interface language.
func available_presets() -> Array[Dictionary]:
    var out: Array[Dictionary] = []
    for id in _presets:
        out.append({"id": id, "name_key": str(_presets[id].get("name_key", id))})
    out.sort_custom(func(a, b): return str(a["id"]) < str(b["id"]))
    return out

func has_preset(id: String) -> bool:
    return _presets.has(id)

func get_preset_id() -> String:
    return current_id

func get_stored_preset_id() -> String:
    var config := ConfigFile.new()
    if config.load(SETTINGS_PATH) != OK:
        return ""
    return str(config.get_value(SETTINGS_SECTION, SETTINGS_KEY, ""))

# The colour of a token. The fallback is the caller's own default, so a script that runs
# without the autoloads in the tree (a headless --script run) still draws something
# sensible.
func color(token: String, fallback := Color.WHITE) -> Color:
    return _palette.get(token, fallback)

func metric(token: String, fallback := 0.0) -> float:
    return float(_metrics.get(token, fallback))

func get_palette() -> Dictionary:
    return _palette

# Applies the stored preset, or the default one when the stored id is unknown or the
# file is gone. A fallback is not written back: the setting belongs to the player.
func apply_stored_preset() -> bool:
    var stored := get_stored_preset_id()
    return apply_preset(stored if has_preset(stored) else DEFAULT_PRESET)

# Applies the preset and remembers the choice.
func set_preset(id: String) -> bool:
    if not apply_preset(id):
        return false
    var config := ConfigFile.new()
    config.load(SETTINGS_PATH)
    config.set_value(SETTINGS_SECTION, SETTINGS_KEY, id)
    config.save(SETTINGS_PATH)
    return true

func apply_preset(id: String) -> bool:
    if not has_preset(id):
        return false
    var preset: Dictionary = _presets[id]
    return apply_palette(_flatten(preset["chrome"], preset["data"]), preset["metrics"], id)

# Puts a palette into the interface. A preset file is the usual source, but the palette may
# also come from a caller — the id only names the choice, and nothing here remembers it:
# only set_preset writes the player's setting.
func apply_palette(palette: Dictionary, metrics: Dictionary, id: String) -> bool:
    _palette = palette
    _metrics = metrics.duplicate()
    current_id = id
    _apply_theme()
    theme_applied.emit()
    _repaint()
    return true

func _flatten(chrome: Dictionary, data: Dictionary) -> Dictionary:
    var out := {}
    for block in [chrome, data]:
        for token in block:
            var parsed = parse_color(block[token])
            if parsed != null:
                out[token] = parsed
    return out

# --- The project theme -----------------------------------------------------------
#
# Every standard control is styled here, not in a screen: a Control that owns no
# override reads the project theme, so one write reaches all of them at once. A screen
# that DOES own an override keeps it (see the palette migration of the tabs and panels),
# which is why the theme is the source of the surface and not a replacement for it.

func _apply_theme() -> void:
    var theme := ThemeDB.get_project_theme()
    if theme == null:
        push_warning("ThemeManager: the project theme is not set (gui/theme/custom in project.godot).")
        return
    _style_buttons(theme)
    _style_text_inputs(theme)
    _style_progress(theme)
    _style_sliders(theme)
    _style_tabs(theme)
    _style_scrollbars(theme)
    _style_popups(theme)
    _style_text(theme)
    _style_surfaces(theme)

func _style_buttons(theme: Theme) -> void:
    for type in ["Button", "OptionButton"]:
        theme.set_stylebox("normal", type, UI_THEME.control_normal())
        theme.set_stylebox("hover", type, UI_THEME.control_hover())
        theme.set_stylebox("pressed", type, UI_THEME.control_pressed())
        theme.set_stylebox("disabled", type, UI_THEME.control_disabled())
        theme.set_stylebox("focus", type, _focus_frame())
        theme.set_color("font_color", type, color("text"))
        theme.set_color("font_hover_color", type, color("text"))
        theme.set_color("font_pressed_color", type, color("text"))
        theme.set_color("font_focus_color", type, color("text"))
        theme.set_color("font_disabled_color", type, color("text_muted"))
    # A checkbox draws its glyph on a transparent background: only the label follows the
    # palette, a frame around the whole row would read as a pressed button.
    for type in ["CheckBox", "CheckButton"]:
        theme.set_color("font_color", type, color("text"))
        theme.set_color("font_hover_color", type, color("text"))
        theme.set_color("font_pressed_color", type, color("text"))
        theme.set_color("font_focus_color", type, color("text"))
        theme.set_color("font_disabled_color", type, color("text_muted"))
    # The glyphs are textures, so the theme cannot derive them from a colour: they are
    # rasterised from the palette here and replaced whenever a palette is applied.
    theme.set_icon("unchecked", "CheckBox", UI_ICONS.checkbox(false))
    theme.set_icon("checked", "CheckBox", UI_ICONS.checkbox(true))
    theme.set_icon("unchecked", "CheckButton", UI_ICONS.switch_button(false))
    theme.set_icon("checked", "CheckButton", UI_ICONS.switch_button(true))

func _style_text_inputs(theme: Theme) -> void:
    theme.set_stylebox("normal", "LineEdit", _field_frame(false))
    theme.set_stylebox("focus", "LineEdit", _field_frame(true))
    theme.set_stylebox("read_only", "LineEdit", _field_frame(false, true))
    theme.set_color("font_color", "LineEdit", color("text"))
    theme.set_color("font_uneditable_color", "LineEdit", color("text_muted"))
    theme.set_color("font_placeholder_color", "LineEdit", color("text_muted"))
    theme.set_color("caret_color", "LineEdit", color("text"))
    # The selection is the accent at a low alpha: it marks a range without hiding the
    # text under it.
    var selection := color("accent")
    selection.a = 0.35
    theme.set_color("selection_color", "LineEdit", selection)

func _style_progress(theme: Theme) -> void:
    theme.set_stylebox("background", "ProgressBar", UI_THEME.bar_background())
    theme.set_stylebox("fill", "ProgressBar", UI_THEME.bar_fill())
    theme.set_color("font_color", "ProgressBar", color("text"))

func _style_sliders(theme: Theme) -> void:
    var track := StyleBoxFlat.new()
    track.bg_color = color("track")
    track.set_corner_radius_all(3)
    UI_THEME.set_content_margins(track, 4.0)
    var fill := StyleBoxFlat.new()
    fill.bg_color = color("fill")
    fill.set_corner_radius_all(3)
    UI_THEME.set_content_margins(fill, 4.0)
    var fill_highlight := fill.duplicate() as StyleBoxFlat
    fill_highlight.bg_color = color("fill").lightened(0.25)
    for type in ["HSlider", "VSlider"]:
        theme.set_stylebox("slider", type, track)
        theme.set_stylebox("grabber_area", type, fill)
        theme.set_stylebox("grabber_area_highlight", type, fill_highlight)
        theme.set_icon("grabber", type, UI_ICONS.knob(color("control_border")))
        theme.set_icon("grabber_highlight", type, UI_ICONS.knob(color("control_border").lightened(0.18)))
        theme.set_icon("grabber_pressed", type, UI_ICONS.knob(color("accent")))

func _style_tabs(theme: Theme) -> void:
    var selected := _tab_frame(color("tab_active_bg"))
    var hovered := _tab_frame(color("control_bg"))
    var plain := _tab_frame(Color(0, 0, 0, 0))
    for type in ["TabContainer", "TabBar"]:
        theme.set_stylebox("tab_selected", type, selected)
        theme.set_stylebox("tab_hovered", type, hovered)
        theme.set_stylebox("tab_unselected", type, plain)
        theme.set_stylebox("tab_disabled", type, plain)
        theme.set_color("font_selected_color", type, color("tab_active_text"))
        theme.set_color("font_hovered_color", type, color("text"))
        theme.set_color("font_unselected_color", type, color("text_muted"))
        theme.set_color("font_disabled_color", type, color("text_muted"))
    theme.set_stylebox("panel", "TabContainer", UI_THEME.panel())

func _style_scrollbars(theme: Theme) -> void:
    # The track paints nothing, but it is what sets the width of the bar: a ScrollBar
    # takes its size from the styleboxes, and a track without margins collapses the bar
    # to zero.
    var no_track := StyleBoxFlat.new()
    no_track.bg_color = Color(0, 0, 0, 0)
    no_track.content_margin_left = 4.0
    no_track.content_margin_right = 4.0
    for type in ["VScrollBar", "HScrollBar"]:
        theme.set_stylebox("scroll", type, no_track)
        theme.set_stylebox("grabber", type, _scroll_grabber(color("scrollbar")))
        theme.set_stylebox("grabber_highlight", type, _scroll_grabber(color("scrollbar_hover")))
        theme.set_stylebox("grabber_pressed", type, _scroll_grabber(color("scrollbar_hover")))

func _style_popups(theme: Theme) -> void:
    theme.set_stylebox("panel", "PopupMenu", UI_THEME.panel())
    theme.set_stylebox("hover", "PopupMenu", _flat(color("row_hover"), 3))
    theme.set_color("font_color", "PopupMenu", color("text"))
    theme.set_color("font_hover_color", "PopupMenu", color("text"))
    theme.set_color("font_disabled_color", "PopupMenu", color("text_muted"))
    theme.set_color("font_accelerator_color", "PopupMenu", color("text_muted"))
    theme.set_color("font_separator_color", "PopupMenu", color("text_muted"))
    theme.set_stylebox("panel", "PopupPanel", UI_THEME.panel())

func _style_text(theme: Theme) -> void:
    theme.set_color("font_color", "Label", color("text"))
    theme.set_color("default_color", "RichTextLabel", color("text"))
    theme.set_color("font_color", "TooltipLabel", color("text"))
    theme.set_stylebox("panel", "TooltipPanel", UI_THEME.tooltip())
    for type in ["HSeparator", "VSeparator"]:
        theme.set_stylebox("separator", type, _separator())

# The surfaces of the screens are named variations of the project theme rather than
# per-node styleboxes: a scene marks a Panel with a variation, and the panel follows the
# palette without a line of runtime code. The variations are registered for Panel and
# PanelContainer alike, because a card is a PanelContainer but a screen plate is a Panel.
func _style_surfaces(theme: Theme) -> void:
    _add_surface(theme, "SurfacePanel", UI_THEME.panel())
    _add_surface(theme, "SurfaceRaised", UI_THEME.panel_raised())
    _add_surface(theme, "SurfaceInset", UI_THEME.panel_inset())
    _add_surface(theme, "SurfaceVeil", UI_THEME.panel_veil())
    _add_surface(theme, "SurfaceWindow", UI_THEME.window_plate())
    _add_surface(theme, "SurfaceProblem", UI_THEME.problem())
    _add_surface(theme, "SurfaceTooltip", UI_THEME.tooltip())
    theme.set_type_variation("MutedLabel", "Label")
    theme.set_color("font_color", "MutedLabel", color("text_muted"))

func _add_surface(theme: Theme, name: String, style: StyleBox) -> void:
    theme.set_type_variation(name, "Panel")
    theme.set_stylebox("panel", name, style)

# The focus frame is drawn OVER the normal box, so it has no fill of its own: an opaque
# box would repaint the control in a second colour as soon as it takes the focus.
func _focus_frame() -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0, 0, 0, 0)
    style.border_color = color("focus_border")
    style.set_border_width_all(1)
    style.set_corner_radius_all(int(metric("control_radius")))
    return style

func _field_frame(focused: bool, read_only := false) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = color("control_disabled") if read_only else color("field_bg")
    if read_only:
        style.border_color = color("control_border_disabled")
    else:
        style.border_color = color("focus_border") if focused else color("field_border")
    style.set_border_width_all(1)
    style.set_corner_radius_all(int(metric("control_radius")))
    style.content_margin_left = 4.0
    style.content_margin_right = 4.0
    style.content_margin_top = 4.0
    style.content_margin_bottom = 4.0
    return style

func _tab_frame(bg: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    style.content_margin_left = 12.0
    style.content_margin_right = 12.0
    style.content_margin_top = 6.0
    style.content_margin_bottom = 6.0
    style.corner_radius_top_left = 6
    style.corner_radius_top_right = 6
    return style

func _flat(bg: Color, radius: int) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    style.set_corner_radius_all(radius)
    return style

func _scroll_grabber(bg: Color) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = bg
    style.set_corner_radius_all(3)
    style.content_margin_left = 2.0
    style.content_margin_right = 2.0
    style.content_margin_top = 2.0
    style.content_margin_bottom = 2.0
    return style

func _separator() -> StyleBoxLine:
    var style := StyleBoxLine.new()
    style.color = color("hairline")
    style.thickness = 1
    return style

# Makes the new surface visible at once. A Control does not always re-read the theme
# after the resource is edited (the same measurement as in FontManager): the notification
# is sent by hand, and every node that draws itself is asked to redraw — a Control included,
# because the badges, the dots and the frames of the tree are drawn in `_draw()` of a
# Control and read the palette there.
func _repaint() -> void:
    if not is_inside_tree():
        return
    get_tree().root.propagate_notification(Control.NOTIFICATION_THEME_CHANGED)
    _redraw_hand_drawn(get_tree().root)

func _redraw_hand_drawn(node: Node) -> void:
    if node is CanvasItem:
        (node as CanvasItem).queue_redraw()
    for child in node.get_children():
        _redraw_hand_drawn(child)

# The WCAG contrast ratio of two colours, (L1 + 0.05) / (L2 + 0.05). The alpha is
# ignored: the panels are near-opaque, and a translucent texture behind them is not
# something the ratio can account for. The presets are checked against it by the test;
# the loader itself does not refuse a low ratio, because dim text is deliberate in
# places (a disabled control, a footnote).
static func contrast_ratio(a: Color, b: Color) -> float:
    var la := _linear_luminance(a)
    var lb := _linear_luminance(b)
    if la < lb:
        var swap := la
        la = lb
        lb = swap
    return (la + 0.05) / (lb + 0.05)

static func _linear_luminance(c: Color) -> float:
    return 0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b)

static func _channel(value: float) -> float:
    if value <= 0.04045:
        return value / 12.92
    return pow((value + 0.055) / 1.055, 2.4)
