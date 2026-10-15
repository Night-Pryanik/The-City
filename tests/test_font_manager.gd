# Headless test for the font manager (FontManager autoload) and the font setting:
#   godot --headless --path . --script res://tests/test_font_manager.gd
#
# Verifies:
#   1. The walk of the folders: the family of a font file is found, service files
#      (*.import, *.tres, the licence) are not fonts, and the family name is freed of the
#      weight word ("Lato Medium" and "Lato" are ONE family, not two).
#   2. The choice inside a family: the body is the face closest to 400, the emphasis is
#      the lightest face at 500 and above, a variable font varies the weight itself, an
#      italic never becomes the body font.
#   3. The settings: the dropdown of the "Interface" tab, the key interface/font, and the
#      choice surviving a reopening of the window.
#   4. Applying: the project theme is rewritten (default_font, Button, TabBar,
#      SectionHeading and the engine fallback font) and a Control that is ALREADY in the
#      tree resolves the new font on the next frame — that is what "on the fly" means.
#   5. The start of the game: the saved family is applied, and a family that is not on
#      disk falls back to the bundled one and rewrites the setting.
#   6. The letter check: a font without the letters of the interface language is refused.
#
# The walk is pinned to the folder the test names: the result must not depend on what the
# player has put into user://fonts. A copy of the bundled font in a folder of the test's
# own covers the other branch of the loader — a raw file, which load_dynamic_font() reads
# (the resource loader knows nothing about files outside res://).
#
# There is no live MainMap here on purpose: the font is applied to the PROJECT THEME by
# the autoload, and every scene reads that theme, so a map would only add six seconds of
# the suite for nothing.
#
# What this test does NOT cover: the theme notification that makes a Control re-resolve
# its font (the first half of FontManager._repaint()). A headless run cannot see it — the
# theme notifies its users by itself often enough for a counter to be worthless as a check
# (measured: deleting the explicit notification fails nothing here). That half is verified
# on a real window instead: without the notification the interface kept the OLD font after
# the second change in a row, with it the rendering followed the theme through five
# changes in a row.
extends SceneTree

# Hang watchdog: without it a break in the _run() coroutine looks like eternal silence
# from the outside. Details — in tests/watchdog.gd.
const WATCHDOG = preload("res://tests/watchdog.gd")

const SETTINGS_PATH := "user://settings.cfg"
# A folder of the test's own: NOT user://fonts, so that nothing is left behind in the
# folder the player keeps their own fonts in.
const TEMP_DIR := "user://font_manager_test"

# A hand-drawn item: the map draws the names of the cities and of the towns itself, with
# the engine fallback font, and knows nothing about the theme — it has to be asked to
# redraw. _draw() is called in a headless run, so the request is observable.
class ThemeProbe2D:
    extends Node2D
    var draws := 0

    func _draw() -> void:
        draws += 1

func _initialize():
    WATCHDOG.arm(self)
    _run()

func _run() -> void:
    var state = {"failed": false}
    var fm = get_root().get_node("FontManager")
    check(fm != null, "the FontManager autoload is there", state)
    if fm == null:
        _finish(state)
        return
    var theme: Theme = ThemeDB.get_project_theme()
    # The settings belong to the player: the value of the key is put back at the end.
    var saved_font: String = fm.get_stored_font()

    # --- 1. The walk of the folders ---
    fm.rescan(["res://fonts"])
    var families: Array = fm.available_fonts()
    check(families.has("Inter"), "res://fonts gives the family \"Inter\" (got %s)"
        % str(families), state)
    check(not fm._is_font_file("InterVariable.ttf.import"), "*.import is not a font file", state)
    check(not fm._is_font_file("inter_medium.tres"), "*.tres is not a font file", state)
    check(not fm._is_font_file("OFL.txt"), "the licence next to a font is not a font", state)
    check(fm._is_font_file("Something.TTF"), "the extension is not case sensitive", state)

    var inter: FontFile = load("res://fonts/InterVariable.ttf")
    var face: Dictionary = fm.describe_font("res://fonts/InterVariable.ttf", inter)
    check(face["family"] == "Inter", "the family of InterVariable.ttf is \"Inter\"", state)
    check(not face["italic"], "InterVariable.ttf is not an italic", state)
    check(face["weight"] == 400, "the default instance of Inter is Regular (400)", state)
    check(face["wght"] != Vector2.ZERO,
        "InterVariable.ttf is a variable font: the weight axis is found", state)

    # --- 2. The family name and the choice inside a family ---
    check(fm.normalize_family("Lato Medium", "Medium") == "Lato",
        "\"Lato Medium\" is the family \"Lato\"", state)
    check(fm.normalize_family("Lato Black", "Regular") == "Lato",
        "the weight word is cut off even when the style says \"Regular\"", state)
    check(fm.normalize_family("PT Sans", "Bold") == "PT Sans",
        "\"PT Sans\" keeps its name", state)
    check(fm.normalize_family("Inter", "Regular") == "Inter", "\"Inter\" keeps its name", state)

    var pick: Dictionary = fm.choose_faces([
        _face("Regular", 400), _face("Medium", 500), _face("Bold", 700)])
    check(pick["body"]["style"] == "Regular", "the body is the face closest to 400", state)
    check(pick["emphasis"]["style"] == "Medium", "the emphasis is the lightest face at 500", state)
    check(not pick["from_axis"], "a static family does not use the weight axis", state)

    pick = fm.choose_faces([_face("Regular", 400), _face("Bold", 700)])
    check(pick["emphasis"]["style"] == "Bold", "without a Medium the emphasis is the Bold", state)

    pick = fm.choose_faces([_face("Regular", 400)])
    check(pick["emphasis"].is_empty(), "a single-face family has no emphasis face", state)

    pick = fm.choose_faces([_face("Italic", 400, true), _face("Regular", 400)])
    check(not pick["body"]["italic"], "an italic never becomes the body font", state)

    pick = fm.choose_faces([_face("Thin", 100, false, Vector2(100, 900))])
    check(pick["from_axis"], "a variable font varies the weight itself", state)

    # --- 3. The settings: the dropdown and the key ---
    _write_font_setting("Inter")
    fm.rescan(["res://fonts"])
    fm.apply_stored_font()
    check(fm.current_family == "Inter", "the saved family is applied at start", state)
    check(theme.default_font == inter, "the theme got the font of the saved family", state)

    var settings = load("res://scenes/settings_menu.tscn").instantiate()
    get_root().add_child(settings)
    await process_frame
    var option: OptionButton = settings.find_child("FontOptionButton", true, false)
    check(option != null, "the FontOptionButton is in the settings scene", state)
    if option != null and option.item_count > 0:
        check(option.item_count == fm.available_fonts().size(),
            "the dropdown lists every family found (%d items, %d families)"
                % [option.item_count, fm.available_fonts().size()], state)
        check(option.get_item_text(option.selected) == fm.current_family,
            "the dropdown shows the applied family (got \"%s\", expected \"%s\")"
                % [option.get_item_text(option.selected), fm.current_family], state)

    # --- 4. Applying on the fly ---
    # The copy makes the SECOND family of the test: the same name, but a different file
    # and therefore a different Font object — a change that is visible in the theme.
    var copy_err := _make_copy()
    check(copy_err == OK, "a copy of the bundled font is put into %s (error %d)"
        % [TEMP_DIR, copy_err], state)
    var label := Label.new()
    label.theme_type_variation = &"SectionHeading"
    get_root().add_child(label)
    var probe_2d := ThemeProbe2D.new()
    get_root().add_child(probe_2d)
    await process_frame
    await process_frame
    var before: Font = label.get_theme_font("font")
    check(before == inter, "before the change the label uses the bundled font", state)
    var drawn_before := probe_2d.draws

    fm.rescan([TEMP_DIR])
    check(fm.set_font("Inter"), "the family of the copy is applied", state)
    await process_frame
    check(probe_2d.draws > drawn_before,
        "a hand-drawn item is asked to redraw (the map takes the font from the fallback)", state)
    var body: Font = theme.default_font
    check(body != inter, "the theme took the font of the copy, not the bundled one", state)
    await process_frame
    check(label.get_theme_font("font") == body,
        "a Control already in the tree followed the change on the next frame", state)
    for type in ["Button", "TabBar", "SectionHeading"]:
        var emphasis: Font = theme.get_font("font", type)
        check(emphasis != null and emphasis != body, "the theme has an emphasis font for %s" % type, state)
    var button_font: Font = theme.get_font("font", "Button")
    check(button_font is FontVariation, "the emphasis of a variable font is an instance of it", state)
    # The emphasis has to be HEAVIER, and that is exactly what a wrong axis key breaks:
    # a Dictionary with the string "wght" is silently ignored and the instance renders as
    # the body font (measured once on fonts/inter_medium.tres).
    var sample := "Шрифт 1234 Wg"
    check(button_font.get_string_size(sample, HORIZONTAL_ALIGNMENT_LEFT, -1, 40).x
            != body.get_string_size(sample, HORIZONTAL_ALIGNMENT_LEFT, -1, 40).x,
        "the emphasis really is a heavier instance, not a copy of the body", state)
    check(ThemeDB.fallback_font == body,
        "the engine fallback font followed too (the map draws its labels with it)", state)

    # --- 5. The start of the game ---
    _write_font_setting("No Such Font")
    fm.apply_stored_font()
    check(fm.current_family == "Inter", "an unknown family falls back to the bundled one", state)
    check(fm.get_stored_font() == "Inter", "the unknown family is rewritten in the settings", state)

    # --- 6. The letter check ---
    check(fm.covers_locale(inter, "ru"), "Inter has the letters of Russian", state)
    check(not fm.covers_locale(FontFile.new(), "ru"),
        "a font without the letters of the language is refused", state)
    check(fm.covers_locale(FontFile.new(), "xx"),
        "a language the game does not know is not checked", state)

    # --- Clean up ---
    settings.queue_free()
    _remove_copy()
    _write_font_setting(saved_font)
    _finish(state)

func _face(style: String, weight: int, italic := false, axis := Vector2.ZERO) -> Dictionary:
    return {"path": "", "family": "Test", "style": style, "weight": weight,
        "italic": italic, "wght": axis}

func _make_copy() -> Error:
    var made := DirAccess.make_dir_absolute(TEMP_DIR)
    if made != OK and made != ERR_ALREADY_EXISTS:
        return made
    var dir := DirAccess.open(TEMP_DIR)
    if dir == null:
        return ERR_CANT_OPEN
    return dir.copy("res://fonts/InterVariable.ttf", TEMP_DIR.path_join("InterVariable.ttf"))

func _remove_copy() -> void:
    DirAccess.remove_absolute(TEMP_DIR.path_join("InterVariable.ttf"))
    DirAccess.remove_absolute(TEMP_DIR)

func _write_font_setting(family: String) -> void:
    var config := ConfigFile.new()
    # Re-read: the settings menu and LocalizationManager write the same file.
    config.load(SETTINGS_PATH)
    config.set_value("interface", "font", family)
    config.save(SETTINGS_PATH)

func _finish(state: Dictionary) -> void:
    if state["failed"]:
        print("FONT MANAGER TEST FAILED")
        quit(1)
    else:
        print("FONT MANAGER TEST OK")
        quit(0)

func check(cond: bool, msg: String, state: Dictionary):
    if not cond:
        push_error("ASSERT: " + msg)
        print("ASSERT FAILED: ", msg)
        state["failed"] = true
