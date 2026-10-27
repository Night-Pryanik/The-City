# Headless test for the theme manager (ThemeManager autoload) and the style factories:
#   godot --headless --path . --script res://tests/test_theme_manager.gd
#
# Verifies:
#   1. The walk of the preset folder: every *.json on disk loads, a preset with a
#      missing token, a bad colour or a negative radius is refused as a whole, and two
#      files cannot share one id.
#   2. The palette: a colour token is parsed from #RRGGBB and #RRGGBBAA, the metrics are
#      numbers, and the loaded palette holds exactly the tokens of the preset.
#   3. The choice: an unknown stored id falls back to the default WITHOUT rewriting the
#      player's setting; a chosen preset is written back.
#   4. The signal: theme_applied fires on every apply.
#   5. The contrast: the tokens a preset must keep readable are checked on the default
#      preset (the same ratios are what a new preset is reviewed against).
#   6. The factories of UiTheme: the built styleboxes take the palette values, and the
#      fallback palette of the module repeats the default preset token by token — a
#      divergence would make a headless run draw a different interface than the game.
#   7. The project theme: every standard control reads the palette from it, and a second
#      apply edits the same resource instead of replacing it.
#   8. The live switch: a palette applied at run time reaches both the project theme and
#      the per-node overrides of a window that re-styles itself on the signal.
#
# The settings belong to the player: the theme key is put back at the end, as in
# test_font_manager.
extends SceneTree

const WATCHDOG = preload("res://tests/watchdog.gd")
const THEME_SCRIPT = preload("res://scripts/theme_manager.gd")
const UI_THEME = preload("res://scripts/ui_theme.gd")

const SETTINGS_PATH := "user://settings.cfg"
const PRESET_DIR := "res://theme/presets"
const DEFAULT_PRESET := "classic"

func _initialize() -> void:
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var manager = get_root().get_node_or_null("ThemeManager")
    check(manager != null, "the ThemeManager autoload is there", state)
    if manager == null:
        _finish(state)
        return

    var saved_setting := _read_setting()
    var had_setting := _settings_has_key()

    # --- 1. The walk of the folder ---
    manager.rescan()
    var on_disk := _count_presets()
    var available: Array = manager.available_presets()
    check(on_disk > 0, "there are presets in %s" % PRESET_DIR, state)
    check(available.size() == on_disk, "every preset on disk loaded (%d of %d)"
        % [available.size(), on_disk], state)
    check(manager.has_preset(DEFAULT_PRESET), "the default preset is on disk", state)
    var names: Array = []
    for entry in available:
        names.append(str(entry["id"]))
    check(names.has(DEFAULT_PRESET), "the default preset is listed for the choice", state)

    var preset: Dictionary = JSON.parse_string(
        FileAccess.get_file_as_string(PRESET_DIR.path_join(DEFAULT_PRESET + ".json")))
    check(not preset.is_empty(), "the default preset parses as JSON", state)
    check(THEME_SCRIPT.validate_preset(preset).is_empty(), "the default preset is complete", state)

    var broken := preset.duplicate(true)
    broken["chrome"].erase("accent")
    check(not THEME_SCRIPT.validate_preset(broken).is_empty(),
        "a missing colour token is a broken preset", state)

    broken = preset.duplicate(true)
    broken["data"]["price"] = "orange"
    check(not THEME_SCRIPT.validate_preset(broken).is_empty(),
        "a colour that is not #RRGGBB(A) is a broken preset", state)

    broken = preset.duplicate(true)
    broken["metrics"]["panel_radius"] = -1
    check(not THEME_SCRIPT.validate_preset(broken).is_empty(),
        "a negative radius is a broken preset", state)

    broken = preset.duplicate(true)
    broken["id"] = "Not An Id"
    check(not THEME_SCRIPT.validate_preset(broken).is_empty(),
        "an id with spaces and capitals is a broken preset", state)

    # --- 2. The palette ---
    check(manager.apply_preset(DEFAULT_PRESET), "the default preset applies", state)

    var panel_bg = THEME_SCRIPT.parse_color("#1C1C1CF5")
    check(typeof(panel_bg) == TYPE_COLOR and panel_bg == Color8(28, 28, 28, 245),
        "an 8-digit colour carries the alpha", state)
    check(THEME_SCRIPT.parse_color("#FF8100") == Color8(255, 129, 0),
        "a 6-digit colour is opaque", state)
    check(THEME_SCRIPT.parse_color("FF8100") == null, "a colour needs the leading #", state)
    check(THEME_SCRIPT.parse_color("#FF81") == null, "a colour needs 6 or 8 digits", state)
    check(THEME_SCRIPT.parse_color("#GGGGGG") == null, "non-hex digits are not a colour", state)
    check(THEME_SCRIPT.parse_color(123) == null, "a number is not a colour", state)

    check(manager.color("price") == Color8(255, 129, 0), "the data token is loaded", state)
    check(manager.metric("panel_radius") == 4.0, "the panel radius is loaded", state)
    check(manager.metric("control_radius") == 3.0, "the control radius is loaded", state)
    check(manager.metric("no_such_metric", 7.5) == 7.5, "an unknown metric takes the fallback", state)

    var palette: Dictionary = manager.get_palette()
    var expected := THEME_SCRIPT.CHROME_TOKENS.size() + THEME_SCRIPT.DATA_TOKENS.size()
    check(palette.size() == expected, "the palette holds every token and nothing else (%d of %d)"
        % [palette.size(), expected], state)

    # --- 3. The choice ---
    _write_setting("no_such_theme")
    check(manager.apply_stored_preset(), "an unknown stored id still applies a preset", state)
    check(manager.get_preset_id() == DEFAULT_PRESET, "an unknown stored id falls back to the default",
        state)
    check(manager.get_stored_preset_id() == "no_such_theme",
        "the fallback does not rewrite the player's setting", state)

    check(manager.set_preset(DEFAULT_PRESET), "a known preset is chosen", state)
    check(manager.get_stored_preset_id() == DEFAULT_PRESET, "the choice is saved", state)
    check(not manager.set_preset("no_such_theme"), "an unknown preset is refused", state)

    # --- 4. The signal ---
    var fired := {"count": 0}
    manager.theme_applied.connect(func(): fired["count"] += 1)
    manager.apply_preset(DEFAULT_PRESET)
    check(fired["count"] == 1, "theme_applied fires on an apply", state)

    # --- 5. The contrast of the default preset ---
    var ratio := THEME_SCRIPT.contrast_ratio(
        manager.color("text"), manager.color("panel_bg"))
    check(ratio >= 4.5, "body text on a panel is readable (%.1f:1)" % ratio, state)
    ratio = THEME_SCRIPT.contrast_ratio(manager.color("text_muted"), manager.color("panel_bg"))
    check(ratio >= 3.0, "muted text on a panel is readable (%.1f:1)" % ratio, state)
    ratio = THEME_SCRIPT.contrast_ratio(manager.color("text"), manager.color("tooltip_bg"))
    check(ratio >= 4.5, "tooltip text is readable (%.1f:1)" % ratio, state)
    ratio = THEME_SCRIPT.contrast_ratio(manager.color("accent_text"), manager.color("accent"))
    check(ratio >= 4.5, "the label of an accent control is readable (%.1f:1)" % ratio, state)

    # --- 6. The factories and the fallback palette ---
    var panel := UI_THEME.panel()
    check(panel.bg_color.is_equal_approx(manager.color("panel_bg")),
        "UiTheme.panel takes the panel colour from the palette", state)
    check(panel.border_color.is_equal_approx(manager.color("panel_border")),
        "UiTheme.panel takes the border from the palette", state)
    check(panel.border_width_left == 1, "UiTheme.panel has a 1 px frame", state)
    check(panel.corner_radius_top_left == 4, "UiTheme.panel takes the radius from the metrics", state)
    check(panel.content_margin_left == 8.0 and panel.content_margin_top == 6.0,
        "UiTheme.panel keeps the content off the frame", state)

    var button := UI_THEME.control_normal()
    check(button.bg_color.is_equal_approx(manager.color("control_bg")),
        "UiTheme.control_normal takes the fill from the palette", state)
    check(button.corner_radius_top_left == 3, "UiTheme.control_normal takes the radius", state)

    var fill := UI_THEME.bar_fill()
    check(fill.bg_color.is_equal_approx(manager.color("fill")),
        "UiTheme.bar_fill takes the fill colour", state)

    var tip := UI_THEME.tooltip()
    check(tip.bg_color.is_equal_approx(manager.color("tooltip_bg")),
        "UiTheme.tooltip takes the surface colour", state)
    check(tip.border_width_right == 1, "UiTheme.tooltip has a 1 px frame", state)

    check(UI_THEME.FALLBACK.size() == palette.size(),
        "the fallback palette has every token (%d of %d)"
        % [UI_THEME.FALLBACK.size(), palette.size()], state)
    for token in palette:
        var expected_color := Color.html(str(UI_THEME.FALLBACK.get(token, "#000000")))
        check(expected_color.is_equal_approx(palette[token]),
            "the fallback matches the default preset for \"%s\"" % token, state)

    # --- 7. The project theme ---
    # The theme is EDITED, not replaced: FontManager holds the fonts in the same resource,
    # and a new instance would leave every control without them.
    var theme: Theme = ThemeDB.get_project_theme()
    check(theme != null, "the project theme is loaded", state)
    var body_font: Font = theme.default_font
    var button_font: Font = theme.get_font("font", "Button")

    var button_normal := theme.get_stylebox("normal", "Button") as StyleBoxFlat
    check(button_normal != null, "Button/normal is styled by the palette", state)
    if button_normal != null:
        check(button_normal.bg_color.is_equal_approx(manager.color("control_bg")),
            "the button fill is the control colour", state)
        check(button_normal.border_color.is_equal_approx(manager.color("control_border")),
            "the button frame is the control border", state)
        check(button_normal.corner_radius_top_left == 3,
            "the button takes the control radius", state)
    var button_focus := theme.get_stylebox("focus", "Button") as StyleBoxFlat
    check(button_focus != null and button_focus.bg_color.a == 0.0,
        "the focus frame does not fill over the button", state)
    if button_focus != null:
        check(button_focus.border_color.is_equal_approx(manager.color("focus_border")),
            "the focus frame takes the focus colour", state)
    check(theme.get_color("font_color", "Button").is_equal_approx(manager.color("text")),
        "the button label takes the text colour", state)

    var field := theme.get_stylebox("normal", "LineEdit") as StyleBoxFlat
    check(field != null, "LineEdit/normal is styled by the palette", state)
    if field != null:
        check(field.bg_color.is_equal_approx(manager.color("field_bg")),
            "the input fill is the field colour", state)
        check(field.border_color.is_equal_approx(manager.color("field_border")),
            "the input frame is the field border", state)
    var field_focus := theme.get_stylebox("focus", "LineEdit") as StyleBoxFlat
    check(field_focus != null
        and field_focus.border_color.is_equal_approx(manager.color("focus_border")),
        "a focused input takes the focus colour", state)

    var bar_fill := theme.get_stylebox("fill", "ProgressBar") as StyleBoxFlat
    check(bar_fill != null and bar_fill.bg_color.is_equal_approx(manager.color("fill")),
        "the progress fill takes the fill colour", state)
    var bar_track := theme.get_stylebox("background", "ProgressBar") as StyleBoxFlat
    check(bar_track != null and bar_track.bg_color.is_equal_approx(manager.color("track")),
        "the progress track takes the track colour", state)

    var slider_fill := theme.get_stylebox("grabber_area", "HSlider") as StyleBoxFlat
    check(slider_fill != null and slider_fill.bg_color.is_equal_approx(manager.color("fill")),
        "the slider fill follows the palette", state)

    # A ScrollBar takes its width from its styleboxes: a track with no margins collapses the
    # bar to zero and the scroll areas of the whole game stop showing a handle.
    var scroll_track := theme.get_stylebox("scroll", "VScrollBar")
    check(scroll_track != null and scroll_track.get_minimum_size().x > 0.0,
        "the scrollbar keeps a width", state)

    var tab := theme.get_stylebox("tab_selected", "TabContainer") as StyleBoxFlat
    check(tab != null and tab.bg_color.is_equal_approx(manager.color("tab_active_bg")),
        "the selected tab takes the tab colour", state)
    var tab_font := theme.get_color("font_selected_color", "TabContainer")
    check(tab_font.is_equal_approx(manager.color("tab_active_text")),
        "the selected tab label takes the tab text colour", state)

    var popup := theme.get_stylebox("panel", "PopupMenu") as StyleBoxFlat
    check(popup != null and popup.bg_color.is_equal_approx(manager.color("panel_bg")),
        "the popup surface is the panel colour", state)
    var tooltip_style := theme.get_stylebox("panel", "TooltipPanel") as StyleBoxFlat
    check(tooltip_style != null
        and tooltip_style.bg_color.is_equal_approx(manager.color("tooltip_bg")),
        "the tooltip surface takes the tooltip colour", state)
    if tooltip_style != null:
        check(tooltip_style.border_color.is_equal_approx(manager.color("tooltip_border")),
            "the tooltip frame takes the tooltip border", state)
    var panel_style := theme.get_stylebox("panel", "PopupPanel") as StyleBoxFlat
    check(panel_style != null and panel_style.bg_color.is_equal_approx(manager.color("panel_bg")),
        "a popup surface takes the panel colour", state)
    # A Panel is often only a grouping node (the technology panel sits inside the content
    # panel), so the theme leaves it alone: a surface here would paint a plate inside a plate.
    check(not theme.has_stylebox("panel", "Panel"),
        "a plain Panel is left to the screen that builds it", state)

    # The screens mark their plates with a variation instead of owning a stylebox.
    var raised := theme.get_stylebox("panel", "SurfaceRaised") as StyleBoxFlat
    check(raised != null and raised.bg_color.is_equal_approx(manager.color("control_bg")),
        "SurfaceRaised draws the raised plate", state)
    var window := theme.get_stylebox("panel", "SurfaceWindow") as StyleBoxFlat
    check(window != null and window.border_width_top == 2,
        "SurfaceWindow carries the heavier window frame", state)
    var problem_style := theme.get_stylebox("panel", "SurfaceProblem") as StyleBoxFlat
    check(problem_style != null
        and not problem_style.bg_color.is_equal_approx(manager.color("panel_bg")),
        "SurfaceProblem tints the surface", state)

    # A variation is looked up by name, so the same name serves a PanelContainer card.
    var inset := theme.get_stylebox("panel", "SurfaceInset") as StyleBoxFlat
    check(inset != null and inset.bg_color.is_equal_approx(manager.color("track")),
        "SurfaceInset draws the well", state)
    check(theme.get_color("font_color", "MutedLabel").is_equal_approx(manager.color("text_muted")),
        "MutedLabel takes the muted text colour", state)
    check(theme.get_color("font_color", "Label").is_equal_approx(manager.color("text")),
        "a plain label takes the text colour", state)

    # The controls keep the size the engine gave them: a theme changes the surface, not the
    # layout of every screen that was laid out against the default metrics.
    var default_theme := ThemeDB.get_default_theme()
    for pair in [["Button", "normal"], ["LineEdit", "normal"],
            ["ProgressBar", "background"], ["HSlider", "slider"]]:
        var ours: StyleBox = theme.get_stylebox(pair[1], pair[0])
        var engine: StyleBox = default_theme.get_stylebox(pair[1], pair[0])
        check(ours != null and engine != null
            and ours.get_minimum_size().is_equal_approx(engine.get_minimum_size()),
            "%s keeps the engine minimum size" % pair[0], state)

    check(theme.default_font == body_font, "the styles do not touch the body font", state)
    check(theme.get_font("font", "Button") == button_font,
        "the styles do not touch the button font", state)
    manager.apply_preset(DEFAULT_PRESET)
    check(ThemeDB.get_project_theme() == theme, "the theme resource is edited, not replaced", state)

    # --- 8. A palette applied at run time ---
    # A window that styles its own nodes keeps per-node overrides, and an override wins over the
    # project theme, so a new palette reaches such a window only through the window's own
    # re-apply on the signal.
    var alt: Dictionary = preset.duplicate(true)
    alt["chrome"]["panel_bg"] = "#001020FF"
    alt["chrome"]["control_bg"] = "#203040"
    alt["data"]["income"] = "#00FF80"
    check(THEME_SCRIPT.validate_preset(alt).is_empty(), "the alternate palette is complete", state)

    var tech_window: Control = load("res://scripts/tech_popup.gd").new()
    get_root().add_child(tech_window)
    # _ready() runs on the next step of the tree, and the window builds its nodes there.
    await process_frame

    var title_before: Color = tech_window.title_label.get_theme_color("font_color")
    check(title_before.is_equal_approx(manager.color("income").lightened(0.35)),
        "a window builds its overrides from the palette that is current", state)

    var applied := {"count": 0}
    manager.theme_applied.connect(func(): applied["count"] += 1)
    check(manager.apply_palette(manager._flatten(alt["chrome"], alt["data"]),
            alt["metrics"].duplicate(), "test_alt"), "a palette from memory applies", state)
    check(applied["count"] == 1, "an apply from memory emits the signal", state)
    check(manager.get_preset_id() == "test_alt", "the id only names the choice", state)
    check(manager.get_stored_preset_id() != "test_alt",
        "a palette from memory does not touch the player's setting", state)

    check(tech_window.title_label.get_theme_color("font_color")
            .is_equal_approx(manager.color("income").lightened(0.35)),
        "the window re-styles its overrides on the signal", state)
    check(not tech_window.title_label.get_theme_color("font_color").is_equal_approx(title_before),
        "the re-styled label really changed colour", state)
    var plate_after := tech_window.panel.get_theme_stylebox("panel") as StyleBoxFlat
    check(plate_after != null and plate_after.bg_color.is_equal_approx(manager.color("panel_bg")),
        "the window plate follows the new surface colour", state)

    var alt_button_normal := theme.get_stylebox("normal", "Button") as StyleBoxFlat
    check(alt_button_normal != null
            and alt_button_normal.bg_color.is_equal_approx(manager.color("control_bg")),
        "the project theme follows the new palette", state)

    manager.apply_preset(DEFAULT_PRESET)
    check(tech_window.title_label.get_theme_color("font_color").is_equal_approx(title_before),
        "the default preset restores the window", state)
    tech_window.free()

    # The player's own setting is put back.
    _restore_setting(saved_setting, had_setting)
    manager.apply_stored_preset()
    _finish(state)

func _count_presets() -> int:
    var dir := DirAccess.open(PRESET_DIR)
    if dir == null:
        return 0
    var count := 0
    for file_name in dir.get_files():
        if file_name.ends_with(".json"):
            count += 1
    return count

func _settings_has_key() -> bool:
    var config := ConfigFile.new()
    if config.load(SETTINGS_PATH) != OK:
        return false
    return config.has_section_key("interface", "theme")

func _read_setting() -> String:
    return str(_read_config().get_value("interface", "theme", ""))

func _write_setting(id: String) -> void:
    var config := _read_config()
    config.set_value("interface", "theme", id)
    config.save(SETTINGS_PATH)

func _restore_setting(value: String, had_key: bool) -> void:
    var config := _read_config()
    if had_key:
        config.set_value("interface", "theme", value)
    else:
        config.erase_section_key("interface", "theme")
    config.save(SETTINGS_PATH)

# Re-read every time: the settings menu writes the same file.
func _read_config() -> ConfigFile:
    var config := ConfigFile.new()
    config.load(SETTINGS_PATH)
    return config

func _finish(state: Dictionary) -> void:
    if state["failed"]:
        print("THEME MANAGER TEST FAILED")
        quit(1)
    else:
        print("THEME MANAGER TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary) -> void:
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
