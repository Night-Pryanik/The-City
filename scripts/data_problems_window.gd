# data_problems_window.gd
# A window with a list of problems in the game data (res://data/*.json).
#
# It is shown in the main menu BEFORE the start of a game (see main_menu.gd) if
# scripts/data_validator.gd has found broken cross-references. The task of the
# window is to show the data author not "something broke in the log", but a
# specific problematic entity: which identifier is missing and in which field
# it was referenced.
#
# The contents are assembled by code (without a .tscn) — following the example of
# tech_popup.gd: the list of problems can be anything, and the layout is uniform.
#
# The window does not prevent starting a game: the player reads the list and closes
# it with the button or Esc, and then plays as usual. While the window is open, it
# intercepts clicks on the main menu (the root Control with MOUSE_FILTER_STOP
# covers the whole screen) — first read the errors, then press "New game".
# The window does not patch the data — the files in the data folder need to be fixed.
extends Control

# We take the check constants from the validator itself (preload, and not an
# autoload): it does not keep state, and the window only needs the titles and the
# order of the blocks. In this way the check title and its position in the window
# cannot diverge from
# data_validator.gd — they are read from one place.
const DataValidator = preload("res://scripts/data_validator.gd")

# The panel size for four-five problems — a typical amount at which
# the list is fully visible without scrolling. More — a vertical
# scrollbar appears (it was configured before as well), less — unnecessary
# scrolling over exactly half of the screen.
const PANEL_MIN_SIZE := Vector2(840, 680)
const TITLE_COLOR := Color(1.0, 0.55, 0.45)
const GROUP_COLOR := Color(0.6, 1.0, 0.6)
const REF_ID_COLOR := Color(1.0, 0.83, 0.47)
const WHERE_COLOR := Color(0.72, 0.72, 0.72)
# The path to the file with the problem — it has its own colour, so that the eye
# immediately goes to it, and does not look for it in the solid grey text of the
# second line.
const FILE_COLOR := Color(0.55, 0.78, 1.0)

# The window title and the summary — they are rebuilt for the current list of problems.
var summary_label: Label
var problems_box: VBoxContainer

# The nodes whose labels change on a language change. We remember them explicitly:
# the auto-translation of Control covers only what is set in the SCENE, and this window
# is built by code, therefore they will have to be re-labelled manually (see
# _on_locale_changed).
var title_label: Label
var copy_button: Button
var ok_button: Button

# The current list of problems: it is needed by the "Copy the list" button. The drawing itself
# does not store it — the contents live in the problems_box nodes.
var all_problems: Array = []


func _ready():
    process_mode = Node.PROCESS_MODE_ALWAYS

    # The language can be switched right in the main menu, and the problem window is
    # on the screen at that moment. The text in it is assembled from the validator
    # data in the language of the launch, therefore without a rebuild it would stay
    # in the old one. The data itself is not
    # touched: the check is not restarted, only the wordings are rebuilt.
    LocalizationManager.locale_changed.connect(_on_locale_changed)

    # Dimming of the background — the window is read as a separate screen, and not as
    # a popup hint over the menu.
    var dim = ColorRect.new()
    dim.color = Color(0, 0, 0, 0.5)
    dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(dim)

    var center = CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(center)

    var panel = Panel.new()
    panel.custom_minimum_size = PANEL_MIN_SIZE
    panel.add_theme_stylebox_override("panel", _make_panel_style())
    center.add_child(panel)

    var vbox = VBoxContainer.new()
    vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    vbox.offset_left = 24
    vbox.offset_top = 24
    vbox.offset_right = -24
    vbox.offset_bottom = -24
    vbox.add_theme_constant_override("separation", 10)
    panel.add_child(vbox)

    title_label = Label.new()
    title_label.text = tr("Errors in the game data")
    title_label.add_theme_font_size_override("font_size", 22)
    title_label.add_theme_color_override("font_color", TITLE_COLOR)
    vbox.add_child(title_label)

    summary_label = Label.new()
    summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    summary_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
    vbox.add_child(summary_label)

    # There may be many problems (a single typo in an id gives dozens of lines),
    # therefore the list is always in a ScrollContainer, and the buttons are pressed
    # to the bottom.
    var scroll = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    vbox.add_child(scroll)

    problems_box = VBoxContainer.new()
    problems_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    problems_box.add_theme_constant_override("separation", 6)
    scroll.add_child(problems_box)

    var buttons = HBoxContainer.new()
    buttons.alignment = BoxContainer.ALIGNMENT_CENTER
    buttons.add_theme_constant_override("separation", 16)
    vbox.add_child(buttons)

    copy_button = Button.new()
    copy_button.text = tr("Copy the list")
    copy_button.custom_minimum_size = Vector2(200, 36)
    copy_button.pressed.connect(_on_copy_pressed)
    buttons.add_child(copy_button)

    ok_button = Button.new()
    ok_button.text = tr("Close")
    ok_button.custom_minimum_size = Vector2(160, 36)
    ok_button.pressed.connect(_on_ok_pressed)
    buttons.add_child(ok_button)

    # _ready() is called on add_child(), and the list of problems arrives as
    # a separate call — the window is invisible in the time between them.
    hide()


# Shows the list of problems. problems is an array of entries from
# DataValidator.validate() (see the header of scripts/data_validator.gd).
func show_problems(problems: Array):
    all_problems = problems
    _build_content(problems)

    # The overlay stretches to the parent. The parent must be the window
    # root (get_tree().root), and not the main menu Control: its anchors
    # are not set to the screen edges (see scenes/main_menu.tscn), and the overlay
    # would cover only part of the screen.
    #
    # Precisely set_anchors_and_offsets_preset, and not set_anchors_preset:
    # the second changes the anchors but keeps the current rectangle (it fits
    # the offsets), and the overlay would remain the size of its panel. The first
    # zeroes the offsets, and PRESET_FULL_RECT stretches the Control to the
    # parent at any resolution and stretch mode.
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    show()
    move_to_front()


# Rebuilds the window contents in the new language.
#
# Two independent sources of text, and both depend on the language:
#   * the wordings of the problems — they lie in the entries themselves, they are
    #     rebuilt by DataValidator.localize_problems() (the check itself is not
    #     restarted);
#   * the title, the summary and the button labels — our own ones, Godot
#         translates them itself, because they are set via tr() on the nodes.
func _on_locale_changed(_locale: String) -> void:
    DataValidator.localize_problems(all_problems)
    _build_content(all_problems)
    title_label.text = tr("Errors in the game data")
    copy_button.text = tr("Copy the list")
    ok_button.text = tr("Close")


func _build_content(problems: Array):
    for child in problems_box.get_children():
        problems_box.remove_child(child)
        child.queue_free()

    # The summary: how many in total and how many by check kind.
    var counts := _count_by_kind(problems)
    var summary := tr("Found %d problems. Some recipes, resources and technologies may work incorrectly — check the files in the res://data folder.") % problems.size()
    var details: Array = []
    for kind in _kinds_in_display_order(counts.keys()):
        details.append("  • %s — %d" % [_check_title(kind), int(counts[kind])])
    if not details.is_empty():
        summary += "\n" + "\n".join(details)
    summary_label.text = summary

    # The problems go in blocks by check kind: the block header explains
    # WHAT broke, the rows under it — where exactly.
    var current_kind := ""
    for problem in problems:
        var kind := str(problem.get("kind", ""))
        if kind != current_kind:
            current_kind = kind
            var header := Label.new()
            header.text = _check_title(kind)
            header.add_theme_font_size_override("font_size", 16)
            header.add_theme_color_override("font_color", GROUP_COLOR)
            problems_box.add_child(header)
        problems_box.add_child(_make_problem_label(problem))


# The row of one problem: the first line — what is missing (the id is highlighted),
# the second — in which field it was referenced.
#
# RichTextLabel, and not Label: the markup is assembled by BBCode strings (bold,
# colors), and Label has no tags — the player would see "[color=#…]" as ordinary
# text (the same reason why in resources_tab.gd a RichTextLabel is taken for the
# breakdown by quality).
func _make_problem_label(problem: Dictionary) -> RichTextLabel:
    var ref_id := str(problem.get("ref_id", ""))
    var headline := str(problem.get("headline", ""))
    # We highlight the identifier itself, so that it is read at a glance.
    var marked_headline := _highlight_id(headline, ref_id)

    var label := RichTextLabel.new()
    label.bbcode_enabled = true
    label.fit_content = true
    label.scroll_active = false
    # The messages are long and must wrap. The width here is set by
    # the container (the ScrollContainer by the panel width), therefore unlike
    # the row in the HBoxContainer of resources_tab.gd the wrapping can be
    # enabled: the label does not ask the container for "its own" width, but
    # takes the ready one.
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    # RichTextLabel has its own theme: without explicit sizes and colour the text would
    # be smaller and paler than the neighbouring Labels.
    label.add_theme_font_size_override("normal_font_size",
            problems_box.get_theme_font_size("font_size"))
    label.add_theme_color_override("default_color", Color.WHITE)
    # The label must not interfere with dragging the list with the mouse.
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE

    # Three lines: what is missing, where the reference was found and in which file.
    # The file path — that is exactly what the window is for: with it the error
    # is both visible and fixable without opening all the files in data/ one by one.
    var text := "• [b]%s[/b]\n   [color=#%s]%s[/color]" % [
        marked_headline,
        WHERE_COLOR.to_html(false),
        str(problem.get("where", "")),
    ]
    var location := str(problem.get("location", ""))
    if not location.is_empty():
        text += "\n   [color=#%s]%s[/color]" % [FILE_COLOR.to_html(false), location]
    label.text = text
    return label


# Highlights the identifier in the problem text.
#
# It searches for it as a separate WORD, and not by the guillemets around it.
# Previously the substitution searched for "%s" together with the guillemets,
# and that worked only while the text
# was Russian: the quotes belong to the translation, and in another language
# (or if a translator removes them) the highlighting would simply disappear silently.
#
# The boundary check — so that "wood" is not highlighted inside "wood_field": the neighbouring
# characters must not be part of the identifier. The boundaries are computed by
# Unicode codes, and not by string comparison, otherwise a Cyrillic "s" would slip past
# the check.
func _highlight_id(text: String, id: String) -> String:
    if id.is_empty():
        return text
    var at := text.find(id)
    while at >= 0:
        var before := "" if at == 0 else text.substr(at - 1, 1)
        var after_at := at + id.length()
        var after := "" if after_at >= text.length() else text.substr(after_at, 1)
        if not _is_ident_char(before) and not _is_ident_char(after):
            return text.substr(0, at) + "[color=#%s]%s[/color]" % [
                REF_ID_COLOR.to_html(false), id] + text.substr(after_at)
        at = text.find(id, at + 1)
    return text


# A character that could be part of an identifier: a letter (Latin or
    # Cyrillic), a digit or an underscore. It mirrors IDENT_CHARS/IDENT_UPPER
    # from data_validator.gd — the same set that the validator considers valid.
func _is_ident_char(ch: String) -> bool:
    if ch.length() != 1:
        return false
    var code := ch.unicode_at(0)
    return (code >= 0x30 and code <= 0x39) \
        or (code >= 0x41 and code <= 0x5A) \
        or (code >= 0x61 and code <= 0x7A) \
        or (code >= 0x410 and code <= 0x44F) \
        or ch == "_"


func _on_copy_pressed():
    # The list is copied as a whole — it is convenient to attach to a task or to go
    # fix the JSON right away.
    var lines: Array = []
    for problem in all_problems:
        lines.append(str(problem.get("message", "")))
    DisplayServer.clipboard_set("\n".join(lines))


func _on_ok_pressed():
    # The window lives in the scene tree root, and not in the main menu, therefore it does
    # not remove itself — closing it is queue_free(). Otherwise after going
    # into a game and returning to the menu, a hidden overlay would accumulate
    # on every visit.
    queue_free()


func _input(event):
    # Esc closes the window, but only while it is visible: a hidden overlay would
    # otherwise intercept Esc from the main menu.
    if not is_visible_in_tree():
        return
    if event.is_action_pressed("ui_cancel"):
        _on_ok_pressed()
        get_viewport().set_input_as_handled()


# The order of the blocks matches the order of the checks in data_validator.gd,
    # therefore the window is read from top to bottom in the same order as the data goes.
func _kinds_in_display_order(kinds) -> Array:
    var order: Array = []
    for kind in DataValidator.CHECK_ORDER:
        if kinds.has(kind):
            order.append(kind)
    # The kinds that are not in the order list (if a check is added and does not
    # end up there), we show at the end, and not lose.
    for kind in kinds:
        if not order.has(kind):
            order.append(kind)
    return order


func _check_title(kind: String) -> String:
    return DataValidator.check_title(kind)


func _count_by_kind(problems: Array) -> Dictionary:
    var counts := {}
    for problem in problems:
        var kind := str(problem.get("kind", ""))
        counts[kind] = int(counts.get(kind, 0)) + 1
    return counts


func _make_panel_style() -> StyleBoxFlat:
    var style = StyleBoxFlat.new()
    style.bg_color = Color(0.13, 0.13, 0.13, 1.0)
    style.set_border_width_all(2)
    style.border_color = Color(0.4, 0.4, 0.4, 1.0)
    style.set_corner_radius_all(4)
    return style
