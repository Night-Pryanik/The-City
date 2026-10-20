# font_manager.gd (FontManager autoload)
#
# It holds the selected interface font and applies it to the project theme.
#
# WHY IT IS LIKE THIS. The font lives in exactly ONE place — the project theme
# (theme/tooltips_theme.tres, gui/theme/custom in project.godot) — and the manager does
# not build a second one. It rewrites the ALREADY LOADED theme resource, the same
# instance the engine hands to every Control, and a Theme notifies its users on every
# edit. Therefore the interface is redrawn in the new font on the next frame: no scene
# is rebuilt and no module knows about the setting. (Checked on a live tree: a Label
# created before the change resolves the new font in the next frame.)
#
# The list of the fonts is built by WALKING the folders (see FONT_DIRS), not by a
# hand-written index: a font file copied into the folder becomes a choice in the
# settings without a line of code and without restarting the game — the settings
# rebuild the list every time the window opens.
#
# A FONT FILE IS NOT A CHOICE, A FAMILY IS. Lato-Regular.ttf, Lato-Medium.ttf and
# Lato-Bold.ttf are three files of one family, and a dropdown of file names would show
# the player "Lato" three times. The family is read from the name table of the file
# (see describe_font()), the faces are grouped by it, and the manager itself decides
# which face is the body text and which one is the emphasis (see choose_faces()).
#
# The order of the autoloads in project.godot matters: LocalizationManager goes first,
# because the letter check (see covers_locale()) needs the language of this launch.
extends Node

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "interface"
const SETTINGS_KEY := "font"

# The folders that are walked for fonts — a list of paths. res://fonts is the bundled
# set, it travels with the game; user://fonts is the player's own — in a build nothing
# can be put next to the game, and a file dropped into the player data folder is picked
# up without rebuilding the project. A family found in several folders is taken WHOLE
# from the first of them.
const FONT_DIRS := ["res://fonts", "user://fonts"]

# What counts as a font file. Next to a font in res://fonts lie *.import and *.uid,
# the generated fonts/inter_medium.tres lies there too, and none of them is a choice.
const FONT_EXTENSIONS: Array[String] = ["ttf", "otf", "woff", "woff2"]

# The family taken when nothing is chosen or the chosen one cannot be used.
const DEFAULT_FAMILY := "Inter"

# The weight of the body text, of the emphasis and of the bold face. The emphasis and
# the bold face are what the theme asks for by name — the types in EMPHASIS_TYPES and
# BOLD_TYPES below.
const BODY_WEIGHT := 400
const EMPHASIS_WEIGHT := 500
const BOLD_WEIGHT := 700

# The strength of the fake bold for a family that has no heavier face at all.
# FontVariation.variation_embolden is measured in pixels of the outline.
const EMBOLDEN_STRENGTH := 0.5
const BOLD_EMBOLDEN_STRENGTH := 1.0

# The theme types drawn in the emphasis weight. Button and TabBar are the ones the
# project theme already had; SectionHeading is the variation the settings scene puts on
# the heading labels of its sections (theme_type_variation, see settings_menu.tscn).
const EMPHASIS_TYPES: Array[String] = ["Button", "TabBar", "SectionHeading"]

# The theme types drawn in the bold weight — the strongest face of the family. The
# journal puts BoldLabel on the unread messages (see journal_ui.gd): the hierarchy
# "unread / read" has to survive a change of the interface font, so it is answered by
# the theme and not by a font override on the label.
const BOLD_TYPES: Array[String] = ["BoldLabel"]

# The words a vendor glues to the family name of a single-weight file: Lato-Medium.ttf
# calls its family "Lato Medium" and not "Lato", and a dropdown of families would show
# Lato twice. LONGEST FIRST: the comparison is by suffix, so "extraBold" has to be
# tried before "bold".
const WEIGHT_WORDS: Array[String] = [
    "extrablack", "extralight", "ultralight", "extrabold", "ultrabold", "semibold",
    "demibold", "regular", "medium", "normal", "light", "black", "heavy", "book",
    "bold", "thin",
]

# TextServer.FontStyle.FONT_STYLE_ITALIC. The enum is not reachable through the class
# name from GDScript (TextServer.FONT_STYLE_ITALIC does not parse), and the flag is a
# plain bit in FontFile.font_style.
const STYLE_ITALIC := 2

# The weight axis of OpenType, the number TextServer.name_to_tag("wght") returns.
#
# IT IS NOT THE STRING "wght". FontVariation SILENTLY IGNORES a Dictionary with that key:
# the axis stays at its default and the font looks unchanged — which is exactly how the
# Medium weight of the project theme was lost once (fonts/inter_medium.tres carried
# {"wght": 500} and rendered as plain Regular). Two forms do work: this numeric tag and
# the axis name TextServer gives it, "weight" (the .tres file uses that one, it reads
# better). Measured: Inter at 40 px, "Шрифт 1234 Wg" — 308 px at the default weight,
# 312 px with the tag applied.
const WEIGHT_AXIS := 2003265652

# The letters of the interface languages. A font that cannot draw them is unusable: the
# whole interface would turn into empty boxes (Bebas Neue has no Cyrillic at all). The
# alphabet is checked whole and not by a sample: a font either has the block or it does
# not. A language that is not in the table is not checked.
const LOCALE_LETTERS := {
    "en": "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
    "ru": "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя",
}

# The family that is applied right now ("" — the theme was never touched).
var current_family: String = ""

# The family -> the list of its faces (see describe_font()).
var _groups: Dictionary = {}
# Every face that was found, in the order the folders were walked. For the tests.
var _faces: Array = []
# The path -> the loaded font: a file is read once per run.
var _loaded: Dictionary = {}
var _scanned := false


func _ready() -> void:
    LocalizationManager.locale_changed.connect(_on_locale_changed)
    apply_stored_font()


# --- The list of the fonts ------------------------------------------------------

# Rebuilds the list of the families. The settings call it every time the window opens,
# therefore a font copied into the folder is picked up without a restart.
#
# dirs is a parameter for the tests: they pin the walk to one folder and do not depend
# on what the player has put into the player data folder.
func rescan(dirs: Array = FONT_DIRS) -> void:
    _groups.clear()
    _faces.clear()
    for dir_path in dirs:
        var found: Array = []
        _scan_dir(dir_path, found)
        _faces.append_array(found)
        var local := group_by_family(found)
        for family in local.keys():
            # A family found in several folders is taken whole from the first folder:
            # mixing the files of one family from two folders would let the player's copy
            # of "Inter Regular" argue with the bundled "Inter Medium".
            if not _groups.has(family):
                _groups[family] = local[family]
    _scanned = true


func _ensure_scanned() -> void:
    if not _scanned:
        rescan()


func _scan_dir(dir_path: String, faces: Array) -> void:
    var dir := DirAccess.open(dir_path)
    if dir == null:
        return
    for file_name in dir.get_files():
        if not _is_font_file(file_name):
            continue
        var path := dir_path.path_join(file_name)
        var font := _load_font(path)
        if font == null:
            push_warning("FontManager: \"%s\" is not readable as a font, skipped." % path)
            continue
        faces.append(describe_font(path, font))
    # A family is often unpacked into a subfolder, so the walk is recursive.
    for sub in dir.get_directories():
        _scan_dir(dir_path.path_join(sub), faces)


# The families for the dropdown, alphabetically.
func available_fonts() -> Array[String]:
    _ensure_scanned()
    var families: Array[String] = []
    for family in _groups.keys():
        families.append(str(family))
    families.sort_custom(func(a: String, b: String) -> bool: return a.nocasecmp_to(b) < 0)
    return families


# What the manager knows about one font FILE. A face is not a family: a family is what
# the dropdown shows, and one family may be many files (Lato has eighteen).
static func describe_font(path: String, font: FontFile) -> Dictionary:
    var family := font.get_font_name().strip_edges()
    if family.is_empty():
        # A file without a usable name table entry: the file name is all that is left.
        family = path.get_file().get_basename().replace("_", " ").strip_edges()
    var style := font.get_font_style_name().strip_edges()
    var weight := font.font_weight
    if weight <= 0:
        weight = BODY_WEIGHT
    return {
        "path": path,
        "family": normalize_family(family, style),
        "style": style,
        "weight": weight,
        "italic": (font.font_style & STYLE_ITALIC) != 0,
        # The range of the weight axis of a variable font, Vector2.ZERO for a static
        # one. The weight of the FILE is the weight of its DEFAULT instance, and for
        # Montserrat[wght].ttf that instance is Thin (100), not Regular — so a variable
        # font is always instantiated at the needed weight, see _font_at().
        "wght": _weight_axis(font),
    }


# "Lato Medium" (the family of Lato-Medium.ttf) and "Lato" are one family: the trailing
# weight word is cut off. The style name is tried first, it is exact; the word list is
# the second attempt, for the vendors that put the weight into the family name and call
# the style "Regular" (Lato-Black.ttf does exactly that).
static func normalize_family(family: String, style: String) -> String:
    var family_name := family.strip_edges()
    var cut := _strip_suffix(family_name, style)
    if cut != family_name:
        return cut
    for word in WEIGHT_WORDS:
        cut = _strip_suffix(family_name, word)
        if cut != family_name:
            return cut
    return family_name


# Cuts the word off the END of the name, if it is there and if something is left before
# it. Case is ignored, spelling is not: the style name and the family suffix of one file
# come from the same name table.
static func _strip_suffix(full_name: String, word: String) -> String:
    var suffix := word.strip_edges()
    if suffix.is_empty() or full_name.length() <= suffix.length():
        return full_name
    if not full_name.to_lower().ends_with(suffix.to_lower()):
        return full_name
    return full_name.substr(0, full_name.length() - suffix.length()).strip_edges()


# The range of the weight axis of a variable font, Vector2.ZERO if the font has no such
# axis (that is, it is a static file). The axes are stored under their numeric tags,
# therefore the tag is compared directly (see WEIGHT_AXIS).
static func _weight_axis(font: FontFile) -> Vector2:
    var axes := font.get_supported_variation_list()
    if not axes.has(WEIGHT_AXIS):
        return Vector2.ZERO
    var span: Vector3 = axes[WEIGHT_AXIS]
    return Vector2(span.x, span.y)


# The faces of one family under its name. The order inside a group is the order the
# files were found, and it is what breaks the ties in choose_faces().
static func group_by_family(faces: Array) -> Dictionary:
    var groups := {}
    for face in faces:
        var family := str(face["family"])
        if not groups.has(family):
            groups[family] = []
        groups[family].append(face)
    return groups


# The two faces of one family: the body one and the emphasis one. Returns
# {"body": face, "emphasis": face, "from_axis": bool}, where
#   from_axis = true — the emphasis is the BODY face at another weight (the font varies
#     its weight itself, and an exact 500 beats a separate Bold file);
#   emphasis = {} — the family has no heavier face at all, so the body is emboldened.
static func choose_faces(faces: Array) -> Dictionary:
    var upright: Array = []
    for face in faces:
        if not face["italic"]:
            upright.append(face)
    # An italic is not a body font, but a family that has nothing else is still a family.
    var pool: Array = upright if not upright.is_empty() else faces
    if pool.is_empty():
        return {}
    var body: Dictionary = pool[0]
    for face in pool:
        if absi(int(face["weight"]) - BODY_WEIGHT) < absi(int(body["weight"]) - BODY_WEIGHT):
            body = face
    if body["wght"] != Vector2.ZERO:
        return {"body": body, "emphasis": {}, "from_axis": true}
    var emphasis: Dictionary = {}
    for face in pool:
        if int(face["weight"]) < EMPHASIS_WEIGHT:
            continue
        if emphasis.is_empty() or int(face["weight"]) < int(emphasis["weight"]):
            emphasis = face
    if emphasis.is_empty():
        for face in pool:
            if int(face["weight"]) > int(body["weight"]):
                if emphasis.is_empty() or int(face["weight"]) < int(emphasis["weight"]):
                    emphasis = face
    return {"body": body, "emphasis": emphasis, "from_axis": false}


static func _is_font_file(file_name: String) -> bool:
    return FONT_EXTENSIONS.has(file_name.get_extension().to_lower())


# The FontFile of a path, read once per run. An imported font (res://fonts in a running
# project) comes from the resource cache together with its import settings; a raw file
# (user://fonts, or a build where the font was packed as a plain file) is read directly —
# the resource loader knows nothing about files outside res:// and would only print an
# error about them.
func _load_font(path: String) -> FontFile:
    if _loaded.has(path):
        return _loaded[path]
    var font: FontFile = null
    if ResourceLoader.exists(path):
        var resource: Variant = ResourceLoader.load(path)
        if resource is FontFile:
            font = resource
    if font == null:
        var raw := FontFile.new()
        if raw.load_dynamic_font(path) == OK:
            font = raw
    if font != null:
        _loaded[path] = font
    return font


# --- Applying -------------------------------------------------------------------

# The Font for a face at the given weight. A static file is taken as it is, there is
# nothing to vary in it; a variable one is instantiated through a FontVariation, because
# the weight of the file itself says nothing about what it can draw.
func _font_at(face: Dictionary, weight: int) -> Font:
    var base := _load_font(str(face["path"]))
    if base == null:
        return null
    var axis: Vector2 = face["wght"]
    if axis == Vector2.ZERO or int(face["weight"]) == weight:
        return base
    var instance := FontVariation.new()
    instance.base_font = base
    # The value has to be an int: a float one is ignored as silently as the wrong key.
    instance.variation_opentype = {WEIGHT_AXIS: int(clampf(float(weight), axis.x, axis.y))}
    return instance


func _build_emphasis(pick: Dictionary) -> Font:
    if pick["from_axis"]:
        return _font_at(pick["body"], EMPHASIS_WEIGHT)
    # The emphasis has to be a DIFFERENT file from the body, or the two render exactly
    # alike. A single-weight family whose only face calls itself Medium or Bold answers
    # choose_faces() with that same file as the emphasis, and _font_at() cannot vary a
    # static font — it hands the file back as it is (measured on Terminus, the bundled
    # monospaced family: every section heading was drawn in the body face).
    if not pick["emphasis"].is_empty() \
            and str(pick["emphasis"]["path"]) != str(pick["body"]["path"]):
        return _font_at(pick["emphasis"], EMPHASIS_WEIGHT)
    var body := _font_at(pick["body"], BODY_WEIGHT)
    if body == null:
        return null
    # The family has no heavier face at all. The hierarchy is kept by emboldening the
    # body: it is a fake weight, but a section heading that cannot be told from the text
    # under it is worse.
    var emboldened := FontVariation.new()
    emboldened.base_font = body
    emboldened.variation_embolden = EMBOLDEN_STRENGTH
    return emboldened


# The strongest face of the family — the bold one. It is built like the emphasis, one
# step further up: the weight axis of a variable font, the heaviest static face it has,
# and the emboldened body for a family that has nothing heavier at all.
func _build_bold(pick: Dictionary) -> Font:
    if pick["from_axis"]:
        return _font_at(pick["body"], BOLD_WEIGHT)
    # The emphasis face is the heaviest one the family has. When it IS the body file
    # (a single-weight font that calls itself Medium or Bold), there is nothing heavier
    # to take, and the bold has to be faked — otherwise "bold" would render exactly like
    # the body text and the hierarchy of the journal would disappear.
    if not pick["emphasis"].is_empty() \
            and str(pick["emphasis"]["path"]) != str(pick["body"]["path"]):
        # A static face cannot be varied: the emphasis file (Bold, Black, ...) IS the
        # bold face of such a family.
        return _font_at(pick["emphasis"], BOLD_WEIGHT)
    var body := _font_at(pick["body"], BODY_WEIGHT)
    if body == null:
        return null
    var emboldened := FontVariation.new()
    emboldened.base_font = body
    emboldened.variation_embolden = BOLD_EMBOLDEN_STRENGTH
    return emboldened


# Rewrites the project theme and remembers the family as the current one.
func _apply_family(family: String) -> bool:
    _ensure_scanned()
    if not _groups.has(family):
        return false
    var pick := choose_faces(_groups[family])
    if pick.is_empty():
        return false
    var body := _font_at(pick["body"], BODY_WEIGHT)
    var emphasis := _build_emphasis(pick)
    var bold := _build_bold(pick)
    if body == null or emphasis == null or bold == null:
        return false
    var theme := ThemeDB.get_project_theme()
    if theme == null:
        push_warning("FontManager: the project theme is not set (gui/theme/custom in project.godot).")
        return false
    theme.default_font = body
    for type in EMPHASIS_TYPES:
        theme.set_font("font", type, emphasis)
    for type in BOLD_TYPES:
        theme.set_font("font", type, bold)
    # The map draws the names of the cities and of the towns itself, with draw_string and
    # the engine fallback font, which knows nothing about the project theme
    # (map_renderer.gd). Without this line the map would stay in the built-in font while
    # the whole interface changes.
    ThemeDB.fallback_font = body
    _repaint()
    current_family = family
    return true


# Makes the change visible at once, without waiting for the next redraw of anything.
#
# A Control does not always re-resolve its font after the theme is rewritten: the theme
# notifies its users, but measured on a live tree the interface stayed in the old font
# after the second change in a row. The notification is therefore sent by hand — the same
# thing the editor does when the theme of a project is edited.
func _repaint() -> void:
    if not is_inside_tree():
        return
    get_tree().root.propagate_notification(Control.NOTIFICATION_THEME_CHANGED)
    _redraw_hand_drawn(get_tree().root)


# The Controls are covered by the notification above. A CanvasItem that is not a Control
# draws itself and re-reads ThemeDB.fallback_font in _draw(), so it only has to be asked
# to redraw — otherwise the map would keep the names of the towns in the old font until
# something else made it redraw.
func _redraw_hand_drawn(node: Node) -> void:
    if node is CanvasItem and not node is Control:
        (node as CanvasItem).queue_redraw()
    for child in node.get_children():
        _redraw_hand_drawn(child)


# Whether the font can draw the letters of the language. An unknown language — true:
# there is nothing to check it against.
static func covers_locale(font: Font, locale: String) -> bool:
    var letters: String = LOCALE_LETTERS.get(locale, "")
    if letters.is_empty() or font == null:
        return true
    for i in letters.length():
        if not font.has_char(letters.unicode_at(i)):
            return false
    return true


# The same check for a family name, on the face that would become the body font.
func _covers(family: String) -> bool:
    if not _groups.has(family):
        return false
    var pick := choose_faces(_groups[family])
    if pick.is_empty():
        return false
    return covers_locale(_load_font(str(pick["body"]["path"])), LocalizationManager.get_locale())


# The font at the start of the game: the saved family, and when it cannot be used — the
# bundled one. The rules repeat LocalizationManager: an unknown value does not crash the
# game, it falls back and rewrites the setting, so that the next launch is predictable.
func apply_stored_font() -> void:
    _ensure_scanned()
    var wanted := get_stored_font()
    if wanted.is_empty():
        # The very first launch.
        if _apply_family(DEFAULT_FAMILY):
            _save_font(DEFAULT_FAMILY)
        return
    if not _groups.has(wanted):
        push_warning("FontManager: the font \"%s\" from the settings is not found — taking \"%s\"."
            % [wanted, DEFAULT_FAMILY])
        if _apply_family(DEFAULT_FAMILY):
            _save_font(DEFAULT_FAMILY)
        return
    if not _covers(wanted):
        # The family is there, but it cannot draw the language of the interface. The saved
        # value is NOT rewritten: the same font may be usable in another language, and the
        # choice has to survive a switch back.
        push_warning("FontManager: \"%s\" has no letters of \"%s\" — taking \"%s\" for this launch."
            % [wanted, LocalizationManager.get_locale(), DEFAULT_FAMILY])
        _apply_family(DEFAULT_FAMILY)
        return
    _apply_family(wanted)


# The language has changed: a font that does not cover the new one has to give way, or
# the interface turns into empty boxes.
func _on_locale_changed(_locale: String) -> void:
    if current_family.is_empty() or _covers(current_family):
        return
    push_warning("FontManager: \"%s\" has no letters of the new language — taking \"%s\"."
        % [current_family, DEFAULT_FAMILY])
    _apply_family(DEFAULT_FAMILY)


# The entry point from the settings. Returns false if there is no such font. The choice
# is applied AS IT IS: the player sees the result at once and can undo it in the same
# window. The letter check is not applied here — it guards the START of the game, so
# that a font which cannot draw the language never greets the player with empty boxes.
func set_font(family: String) -> bool:
    _ensure_scanned()
    if not _apply_family(family):
        return false
    _save_font(family)
    return true


# The saved family, without applying it. It is needed by the settings in order to show
# the current choice when the window opens.
func get_stored_font() -> String:
    var config := ConfigFile.new()
    if config.load(SETTINGS_PATH) != OK:
        return ""
    return str(config.get_value(SETTINGS_SECTION, SETTINGS_KEY, ""))


func _save_font(family: String) -> void:
    var config := ConfigFile.new()
    # The file is re-read: settings_menu.gd and LocalizationManager write the settings
    # too, and their in-memory copies do not know about the key written here.
    config.load(SETTINGS_PATH)
    config.set_value(SETTINGS_SECTION, SETTINGS_KEY, family)
    config.save(SETTINGS_PATH)
