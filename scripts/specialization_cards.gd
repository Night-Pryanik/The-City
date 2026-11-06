# specialization_cards.gd
#
# One specialization as a plate: the icon, the name, what the branch gives, the non-numeric
# consequences of the data, the predecessors it is waiting for and — when the view offers it — the
# button that takes it.
#
# The choice window and the tab "Specialization" show the same branches, so the plate is built here
# once and used by both: the two views must not drift apart in what they say about a branch.
#
# Everything a plate says about the state of the city is read from CityData by the plate itself, so
# a view cannot pass a state that contradicts the data. What the view decides is the grouping (the
# headings of its list) and whether a pick can be taken here — the callback of the button.
#
# The builder is static and never changes the state: taking a branch is the callback of the caller,
# which decides what happens after the pick (the window closes, the tab is rebuilt).
#
# The text is translated with TranslationServer.translate(): a static function cannot call tr().
#
# The script is preloaded by its consumers (const SpecCards = preload(...)) and is not a class_name:
# a global name would need the class cache of the project, and the plate is only ever built from the
# two views of the specializations.
const UI_THEME = preload("res://scripts/ui_theme.gd")

const ICON_SIZE := 40
const ICON_FALLBACK := "reputation_specialization.svg"

# The plate of a branch the city cannot take yet is faded as a whole: one modulate keeps the icon,
# the texts and the fill in step, and a line added to the plate later is dimmed without a second
# thought. The colours are not replaced line by line — the green of a bonus and the warning of the
# requirements must stay readable, only quieter than on an available plate.
const MUTED_MODULATE := Color(0.82, 0.82, 0.82, 0.55)

# The plate of a branch. on_choose receives the id of the branch; an empty Callable means this view
# offers no way to take it here (the choice window has a button of its own for that).
static func build(spec: Dictionary, on_choose: Callable = Callable()) -> PanelContainer:
    var card := PanelContainer.new()
    var style := UI_THEME.row(UI_THEME.color("panel_bg"))
    UI_THEME.set_content_margins(style, 8.0)
    card.add_theme_stylebox_override("panel", style)

    # A branch that cannot be taken is drawn muted. A TAKEN branch is not: it is not disabled, it is
    # done, and it is listed among the branches of the city with the bonuses it gives.
    var id := str(spec.get("id", ""))
    if not CityData.is_specialization_chosen(id) and not CityData.is_specialization_available(spec):
        card.modulate = MUTED_MODULATE

    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 10)
    card.add_child(row)

    _add_icon(row, str(spec.get("icon", "")))

    var body := VBoxContainer.new()
    body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    body.add_theme_constant_override("separation", 2)
    row.add_child(body)

    _add_name(body, spec)

    var description := str(spec.get("description", ""))
    if description != "":
        body.add_child(_line(description, UI_THEME.color("text_muted")))

    for bonus in spec.get("bonuses", []):
        if bonus is Dictionary:
            body.add_child(_bonus_line(bonus))

    # The non-numeric consequences of the branch: a building, a recipe, a mechanic. Only this view
    # lists them — the tab "Effects" carries the numbers.
    for effect in CityData.get_specialization_effects(spec):
        body.add_child(_line("• " + str(effect), UI_THEME.color("text_secondary")))

    # A branch that is shown but cannot be taken yet: what it waits for. A chosen branch is never
    # "locked", therefore the line is derived from the conditions alone. The wording has a context of
    # its own: a technology "requires" a technology, a branch "is waited for" by it.
    if not CityData.is_specialization_chosen(id):
        var requires := _requires_text(spec)
        if requires != "":
            body.add_child(_line(
                    TranslationServer.translate("Requires: %s", "specialization_requires") % requires,
                    UI_THEME.color("warning")))

    if on_choose.is_valid():
        row.add_child(_make_choose_button(id, on_choose))

    return card

# Everything the branch waits for, in one line: the predecessors among the other branches and the
# conditions of "unlock" outside them (the fame of a good opens a prestige branch). The two are
# joined by a comma because the predecessors carry their own "and"/"or" and a third conjunction
# would read as part of their grouping.
static func _requires_text(spec: Dictionary) -> String:
    var parts: Array = []
    if not CityData.are_specialization_prerequisites_met(spec):
        var predecessors := CityData.get_specialization_prerequisites_text(spec)
        if predecessors != "":
            parts.append(predecessors)
    var unlock := CityData.get_specialization_unlock_text(spec)
    if unlock != "":
        parts.append(unlock)
    return ", ".join(parts)

static func _add_name(body: VBoxContainer, spec: Dictionary) -> void:
    var name_label := Label.new()
    # The full name: the plate describes the bonuses of the branch, and "Raw Materials" alone over a
    # list of percentages reads as a heading without a subject.
    name_label.text = CityData.get_specialization_full_name(spec)
    name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    body.add_child(name_label)

static func _make_choose_button(id: String, on_choose: Callable) -> Button:
    var button := Button.new()
    button.text = TranslationServer.translate("Choose")
    button.custom_minimum_size = Vector2(96, 32)
    button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    button.pressed.connect(func(): on_choose.call(id))
    return button

# A line of the plate: it wraps as a whole, so a long list of improvements never runs off the edge.
static func _line(text: String, color: Color) -> Label:
    var label := Label.new()
    label.text = text
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.add_theme_color_override("font_color", color)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return label

# The line of one bonus. A bonus that leads with a group of data/product_groups/ carries the
# standard mark of a group reference — the dashed line and the tooltip of the composition — so the
# player sees that the words stand for a list of goods and not for one good. The mark is drawn from
# x = 0 of its own label (see underlined_label.gd), therefore the bullet goes into a label of its own
# and the text of the marked label begins with the name of the group.
static func _bonus_line(bonus: Dictionary) -> Control:
    var color := UI_THEME.color("income")
    var text := CityData.format_specialization_bonus_record(bonus)
    var goods: Array = CityData.get_specialization_bonus_goods(bonus)
    var group := str(goods[0].get("group", "")) if not goods.is_empty() else ""
    var group_name := str(goods[0].get("text", "")) if not goods.is_empty() else ""
    if group == "" or not text.begins_with(group_name):
        return _line("• " + text, color)

    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 4)
    row.add_child(_bullet(color))
    # The script is taken by path: the global class cache may not be there yet in a headless
    # --script run (the same note as in ui_helpers.make_resource_entry).
    var link = load("res://scripts/underlined_label.gd").new()
    link.text = text
    link.underline_text = group_name
    link.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    link.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    link.add_theme_color_override("font_color", color)
    # PASS and not STOP: the label needs the cursor for the tooltip, and the window under it keeps
    # the events the plate itself answers to.
    link.mouse_filter = Control.MOUSE_FILTER_PASS
    link.mouse_entered.connect(_on_group_hover.bind(link, group))
    link.mouse_exited.connect(_on_group_exit.bind(link))
    row.add_child(link)
    return row

static func _bullet(color: Color) -> Label:
    var label := Label.new()
    label.text = "•"
    label.add_theme_color_override("font_color", color)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return label

# The composition of the group opens in the standard tooltip of the map, the same panel the recipes
# and the costs of a building use. The plates are drawn both in the tab of the city window and in the
# choice window, and both hang under the map, so the instance is taken from there rather than copied
# per window.
static func _on_group_hover(label: Control, group: String) -> void:
    var helpers := _ui_helpers(label)
    if helpers == null:
        return
    helpers.show_group_tooltip(label.get_viewport().get_mouse_position(), group,
            GameData.products, CityData.city_storage, CityData.city_quality_detail)

static func _on_group_exit(label: Control) -> void:
    var helpers := _ui_helpers(label)
    if helpers != null:
        helpers.hide_group_tooltip()

# A plate built outside the map (a test that assembles one on its own) has no tooltip instance, and
# the underline still says that the word is a group.
static func _ui_helpers(from: Node) -> Node:
    var parent := from.get_parent()
    while parent != null:
        if parent.has_method("get_ui_helpers"):
            var shared = parent.get_ui_helpers()
            if shared != null and is_instance_valid(shared):
                return shared
        parent = parent.get_parent()
    return null

# The icon of a branch. A branch without a picture of its own (a mod that ships none) keeps the
# height of the plate and shows the common mark instead of collapsing the row.
static func _add_icon(row: HBoxContainer, icon_name: String) -> void:
    var texture: Texture2D = null
    if icon_name != "":
        texture = IconRegistry.get_texture(icon_name)
    if texture == null:
        texture = IconRegistry.get_texture(ICON_FALLBACK)
    if texture == null:
        return
    var icon_rect := TextureRect.new()
    icon_rect.texture = texture
    icon_rect.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
    icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
    icon_rect.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    row.add_child(icon_rect)
