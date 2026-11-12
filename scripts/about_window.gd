# about_window.gd
#
# The "About" window of the main menu: the author of the game, the licenses the project
# is published under and the third-party components it ships with.
#
# The contents are assembled by code (without a .tscn) — following the example of
# data_problems_window.gd: the contents are a list of paragraphs, and the layout is
# uniform.
#
# The licenses are given in the short form: what they allow and what they demand. The
# full texts lie in the LICENSE and LICENSE-ASSETS.md files of the repository, and the
# links lead to the pages of Creative Commons.
#
# The window lives in the scene tree root, and not in the main menu: the anchors of the
# menu Control are not set to the screen edges (scenes/main_menu.tscn), and the plate
# would cover only part of the screen.
extends Control

const UI_THEME = preload("res://scripts/ui_theme.gd")

# The author of the game. The name is not a translatable string: it is a name.
const AUTHOR_NAME := "Anton Burmistrov"

const REPOSITORY_URL := "https://github.com/Night-Pryanik/The-City"
const CODE_LICENSE_URL := "https://creativecommons.org/licenses/by-nc-sa/4.0/"
const ASSETS_LICENSE_URL := "https://creativecommons.org/licenses/by/4.0/"

# The plate of the window: the text is a list of paragraphs, and the panel takes the
# room it needs — the list itself scrolls.
const PANEL_MIN_SIZE := Vector2(700, 680)

# The nodes whose wording changes with the language. They are rebuilt by hand: the
# auto-translation of Control covers only what is set in a scene, and this window is
# built by code (see _on_locale_changed).
var _title_label: Label
var _close_button: Button
var _content_box: VBoxContainer


func _ready() -> void:
    LocalizationManager.locale_changed.connect(_on_locale_changed)
    _build_ui()
    # The window shows itself: it is created only when the player asks for it, and
    # there is no state in which it exists and stays hidden.
    show_about()


# Shows the window. The overlay stretches to the parent, and the parent must be the
# window root (get_tree().root) — the anchors of the main menu Control are not set to
# the screen edges, and the plate would cover only part of the screen.
func show_about() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    show()
    move_to_front()


func _build_ui() -> void:
    var dim := Scrim.new()
    dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(dim)
    # The plate of the scrim is stretched by hand: the anchors alone keep the rect of
    # the node, and a plate of no size dims nothing.
    dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(center)

    var panel := Panel.new()
    panel.custom_minimum_size = PANEL_MIN_SIZE
    # The plate of the window is opaque: the menu of the main menu stands right behind
    # it, and a translucent plate would let its buttons shine through the text.
    var plate := UI_THEME.window_plate()
    plate.bg_color.a = 1.0
    panel.add_theme_stylebox_override("panel", plate)
    center.add_child(panel)

    var column := VBoxContainer.new()
    column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    column.offset_left = 24
    column.offset_top = 20
    column.offset_right = -24
    column.offset_bottom = -20
    column.add_theme_constant_override("separation", 8)
    panel.add_child(column)

    _title_label = Label.new()
    _title_label.text = tr("About the game")
    _title_label.add_theme_font_size_override("font_size", 22)
    column.add_child(_title_label)

    var game_name := Label.new()
    game_name.text = "The City"
    game_name.add_theme_font_size_override("font_size", 18)
    game_name.add_theme_color_override("font_color", UI_THEME.color("accent"))
    column.add_child(game_name)

    var tagline := Label.new()
    tagline.text = tr("An economic simulator of a single city's development through historical eras.")
    tagline.theme_type_variation = &"MutedLabel"
    tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    column.add_child(tagline)

    # The paragraphs scroll: the list of the licenses and the third-party components
    # takes more room than a small screen has.
    var scroll := ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    column.add_child(scroll)

    _content_box = VBoxContainer.new()
    _content_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    _content_box.add_theme_constant_override("separation", 6)
    scroll.add_child(_content_box)

    var buttons := HBoxContainer.new()
    buttons.alignment = BoxContainer.ALIGNMENT_CENTER
    column.add_child(buttons)

    _close_button = Button.new()
    _close_button.name = "CloseButton"
    _close_button.text = tr("Close")
    _close_button.custom_minimum_size = Vector2(160, 36)
    _close_button.pressed.connect(_on_close_pressed)
    buttons.add_child(_close_button)

    _fill_content()


# Fills the window with the paragraphs. They are rebuilt from scratch on every call:
# the contents are a list of labels, and the rebuild keeps the order and the wording
# of the sections in one place.
func _fill_content() -> void:
    for child in _content_box.get_children():
        _content_box.remove_child(child)
        child.queue_free()

    _add_heading(tr("Author"))
    _add_line(AUTHOR_NAME)

    _add_heading(tr("Licenses"))
    _add_license(tr("Game code"), "CC BY-NC-SA 4.0",
        tr("Anyone may read, change and share the code. It may not be used to make money, and a changed version must stay under the same license."),
        CODE_LICENSE_URL, tr("Open the license text"))
    _add_license(tr("Artwork and game data"), "CC BY 4.0",
        tr("Anyone may reuse the artwork and the data, including commercially, as long as The City is credited."),
        ASSETS_LICENSE_URL, tr("Open the license text"))

    _add_heading(tr("Third-party components"))
    _add_line(tr("Inter font — SIL Open Font License 1.1"))
    _add_line(tr("Godot Engine — MIT License"))
    _add_line(tr("The artwork was made with the help of an image-generation model."))

    _add_heading(tr("Project"))
    _add_link(REPOSITORY_URL, tr("Open the repository"))
    _add_line(tr("The full texts of the licenses are in the LICENSE and LICENSE-ASSETS.md files of the repository."))


# The heading of a section.
func _add_heading(text: String) -> void:
    var label := Label.new()
    label.text = text
    label.add_theme_font_size_override("font_size", 16)
    label.add_theme_color_override("font_color", UI_THEME.color("accent"))
    _content_box.add_child(label)


# A paragraph of the section.
func _add_line(text: String) -> void:
    var label := Label.new()
    label.text = text
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
    _content_box.add_child(label)


# One license: what it covers, what it allows and the link to its text.
func _add_license(title: String, license_name: String, summary: String, url: String,
        link_tooltip: String) -> void:
    var heading := Label.new()
    heading.text = title
    heading.add_theme_font_size_override("font_size", 14)
    _content_box.add_child(heading)

    var name_label := Label.new()
    name_label.text = license_name
    name_label.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
    _content_box.add_child(name_label)

    _add_line(summary)
    _add_link(url, link_tooltip)


# A link. The visible text is the address itself: it says where the link leads even
# when it is not clicked.
func _add_link(url: String, tooltip: String) -> void:
    var label := RichTextLabel.new()
    label.bbcode_enabled = true
    label.fit_content = true
    label.scroll_active = false
    label.text = "[url=%s]%s[/url]" % [url, url]
    label.tooltip_text = tooltip
    # RichTextLabel has its own theme: without an explicit size the text would be
    # smaller than the neighbouring Labels.
    label.add_theme_font_size_override("normal_font_size",
            _content_box.get_theme_font_size("font_size"))
    label.meta_clicked.connect(_on_meta_clicked)
    _content_box.add_child(label)


# Rebuilds the window in the new language.
#
# Two independent sources of text, and both depend on the language: the wordings of
# the sections and the label of the button. They are set from the code, and not from
# a scene, therefore Godot does not re-translate them by itself.
func _on_locale_changed(_locale: String) -> void:
    _title_label.text = tr("About the game")
    _close_button.text = tr("Close")
    _fill_content()


# A clicked link. The meta of a link is its address, and only an http(s) one is
# opened — the label knows no other schemes.
func _on_meta_clicked(meta: Variant) -> void:
    var url := str(meta)
    if url.begins_with("http://") or url.begins_with("https://"):
        OS.shell_open(url)


func _on_close_pressed() -> void:
    # The window lives in the scene tree root, and not in the main menu, therefore it
    # does not remove itself — closing it is queue_free(). Otherwise a hidden overlay
    # would accumulate on every visit.
    queue_free()


func _input(event):
    # Esc closes the window, but only while it is visible: a hidden overlay would
    # otherwise intercept Esc from the main menu.
    if not is_visible_in_tree():
        return
    if event.is_action_pressed("ui_cancel"):
        _on_close_pressed()
        get_viewport().set_input_as_handled()
