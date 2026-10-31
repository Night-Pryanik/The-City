# effects_tab.gd
#
# The tab "Effects" of the city: what acts on the city right now. Two sections, switched by a
# row of small icon buttons — the same idiom as the sections of the "Resources" tab:
#   · "effects"   — the active effects: the numbers and the availability the city really has;
#   · "diversity" — the domesticated subgroups and the bonuses for the variety.
#
# The list is a view of CityData.get_city_effects(): the tab does not decide what acts on the
# city, it only draws it. The effects change on structural events (a research completed, a
# building built), never on a tick, therefore the list is rebuilt on a full refresh only.
extends Node

# The "single source of truth" script for the styling constants shared with the other tabs.
const UiHelpers = preload("res://scripts/ui_helpers.gd")
const UI_THEME = preload("res://scripts/ui_theme.gd")

# The sections of the tab.
const SECTION_EFFECTS := "effects"
const SECTION_DIVERSITY := "diversity"

# The icons of the section buttons. They are taken from the common registry
# IconRegistry (autoload), the same way the buttons of the other tabs take theirs.
const ICON_SECTION_EFFECTS := "additional_info.png"
const ICON_SECTION_DIVERSITY := "production_bonus.png"

var title_label: Label = null
var effects_section: Control = null
var diversity_section: Control = null
var effects_list: Node = null
var diversity_list: Node = null
# The buttons of the section bar: [{ "button": Button, "id": section }].
var section_buttons: Array = []
var active_section: String = SECTION_EFFECTS

func setup(panel: Control):
    if panel == null or not is_instance_valid(panel):
        return
    title_label = panel.get_node_or_null("TitleLabel")
    effects_section = panel.get_node_or_null("EffectsSection")
    diversity_section = panel.get_node_or_null("DiversitySection")
    effects_list = panel.get_node_or_null("EffectsSection/ScrollContainer/EffectsList")
    diversity_list = panel.get_node_or_null("DiversitySection/ScrollContainer/DiversityList")
    section_buttons = [
        {"button": panel.get_node_or_null("SectionsBar/EffectsButton"), "id": SECTION_EFFECTS},
        {"button": panel.get_node_or_null("SectionsBar/DiversityButton"), "id": SECTION_DIVERSITY},
    ]
    _setup_section_icons()
    _connect_section_buttons()
    _switch_section(active_section)

# The icons of the section buttons — the same size as the icons of the section
# buttons of the other tabs.
func _setup_section_icons() -> void:
    _set_button_icon(_button_of(SECTION_EFFECTS), ICON_SECTION_EFFECTS, 30)
    _set_button_icon(_button_of(SECTION_DIVERSITY), ICON_SECTION_DIVERSITY, 30)

func _set_button_icon(button: Button, icon_name: String, max_size: int) -> void:
    if button == null or not is_instance_valid(button):
        return
    var tex := IconRegistry.get_texture(icon_name)
    if tex == null:
        return
    button.icon = tex
    button.expand_icon = true
    button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
    button.add_theme_constant_override("icon_max_width", max_size)
    button.add_theme_constant_override("icon_max_height", max_size)

func _connect_section_buttons() -> void:
    for entry in section_buttons:
        var button: Button = entry["button"]
        if button != null and not button.pressed.is_connected(_on_section_pressed):
            button.pressed.connect(_on_section_pressed.bind(str(entry["id"])))

func _button_of(section_id: String) -> Button:
    for entry in section_buttons:
        if str(entry["id"]) == section_id:
            return entry["button"]
    return null

# The switch of the sections: ordinary panels with a manual visibility — the same approach as
# with the tabs of the city (city_ui._switch_tab). The title repeats the name of the section:
# the section buttons are icons without a caption, and the row of them says nothing about what
# is open right now.
func _switch_section(section_id: String) -> void:
    active_section = section_id
    if effects_section != null and is_instance_valid(effects_section):
        effects_section.visible = section_id == SECTION_EFFECTS
    if diversity_section != null and is_instance_valid(diversity_section):
        diversity_section.visible = section_id == SECTION_DIVERSITY
    if title_label != null and is_instance_valid(title_label):
        title_label.text = tr("Diversity") if section_id == SECTION_DIVERSITY else tr("City effects")
    _update_section_buttons()

func _on_section_pressed(section_id: String) -> void:
    _switch_section(section_id)

# The active section is highlighted with the same accent as the tab bar of the city.
func _update_section_buttons() -> void:
    for entry in section_buttons:
        var button: Button = entry["button"]
        if button == null or not is_instance_valid(button):
            continue
        UiHelpers.highlight_toggle_button(button, str(entry["id"]) == active_section)

func refresh() -> void:
    _clear_list(effects_list)
    _clear_list(diversity_list)
    _fill_effects_section()
    _fill_diversity_section()
    # The highlight of the buttons of the sections is a per-node override, so a rebuild of the
    # column re-asserts it together with the rows; on a change of the palette it is the only
    # thing that has to change there.
    _update_section_buttons()

# Empties the list of a section. The rows are recreated from scratch on every full refresh.
func _clear_list(list: Node) -> void:
    if list == null or not is_instance_valid(list):
        return
    for child in list.get_children():
        child.queue_free()

# --- The section "City effects" ---

# The active effects grouped by their source. The order of the groups and of the rows inside them
# is the order CityData returns (the city hex first, then the technologies in the order of
# data/modifiers.json), so an effect keeps its place between two rebuilds.
func _fill_effects_section() -> void:
    if effects_list == null or not is_instance_valid(effects_list):
        return
    var by_group := {}
    var group_order: Array = []
    for effect in CityData.get_city_effects():
        var group := String(effect.get("group", ""))
        if not by_group.has(group):
            by_group[group] = []
            group_order.append(group)
        by_group[group].append(effect)

    for i in group_order.size():
        var group: String = group_order[i]
        var rows: Array = by_group[group]
        if rows.is_empty():
            continue
        # A gap before every group but the first: the header of a group must read as a new
        # block, not as another row of the previous one.
        if i > 0:
            var gap := Control.new()
            gap.custom_minimum_size = Vector2(0, 6)
            effects_list.add_child(gap)
        var header := Label.new()
        header.text = _group_title(group)
        header.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
        effects_list.add_child(header)
        for effect in rows:
            effects_list.add_child(_build_effect_row(effect))

    if group_order.is_empty():
        effects_list.add_child(_build_empty_label(tr("No effects act on the city")))

# The caption of a group of the effects. CityData names a group by a stable id, the tab says it
# in the language of the player. The ids are spelled out one by one, and not looked up in a
# dictionary: a caption has to be a literal `tr("...")` for the catalogue, otherwise the group
# header stays untranslated. An unknown id is shown as it is, so a new group never disappears
# from the list.
func _group_title(group: String) -> String:
    match group:
        "environment":
            return tr("City hex")
        "technologies":
            return tr("Technologies")
    return group

# A row: the icon and one flowing line — the effect and, right behind it in brackets, what the
# effect belongs to or the state the city has. The line wraps as a whole, so the qualifier never
# drifts away from the effect it explains.
func _build_effect_row(effect: Dictionary) -> Control:
    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 6)

    var icon_name := String(effect.get("icon", ""))
    if icon_name != "":
        var tex := IconRegistry.get_texture(icon_name)
        if tex != null:
            var icon_rect := TextureRect.new()
            icon_rect.texture = tex
            icon_rect.custom_minimum_size = Vector2(32, 32)
            icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
            icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
            # The icon does not stretch along the height of a wrapped row: it stays 32×32 and is
            # centred.
            icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
            row.add_child(icon_rect)

    # One label, not two: a wrapping name label always takes the whole free width, so a second
    # label placed after it is pushed to the far edge of the row. The qualifier is added to the
    # same flow instead, in a muted colour of its own.
    var text := RichTextLabel.new()
    text.bbcode_enabled = false
    text.fit_content = true
    text.scroll_active = false
    text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
    text.mouse_filter = Control.MOUSE_FILTER_PASS
    text.add_text(String(effect.get("name", "")))
    var detail := _detail_text(effect)
    if detail != "":
        text.push_color(UI_THEME.color("text_muted"))
        text.add_text(" (%s)" % detail)
        text.pop()
    row.add_child(text)

    return row

# The bracketed qualifier of an effect: the state the city has ("direct access") or the
# technology the effect comes from ("Wheel"). A record that carries both is joined into one pair
# of brackets.
func _detail_text(effect: Dictionary) -> String:
    var parts: Array = []
    var value := String(effect.get("value", ""))
    if value != "":
        parts.append(value)
    var source := String(effect.get("source", ""))
    if source != "":
        parts.append(source)
    return ", ".join(parts)

# A muted line for a section that has nothing to show. An empty list without it reads as a
# broken tab, not as "there is nothing yet".
func _build_empty_label(text: String) -> Label:
    var label := Label.new()
    label.text = text
    label.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
    return label

# --- The section "Diversity" ---

# The number of the subgroups of the domesticated resources and the bonuses of the
# diversity (a stub).
func _fill_diversity_section() -> void:
    if diversity_list == null or not is_instance_valid(diversity_list):
        return
    var subgroup_map := {}
    for resource_id in CityData.domesticated_resources:
        var data = GameData.raw_resources.get(resource_id, {})
        for subgroup in _get_subgroups(data):
            subgroup_map[subgroup] = true

    var total_subgroups: int = subgroup_map.size()
    if total_subgroups > 0:
        var div_label := Label.new()
        div_label.text = tr("Diversity: %d subgroups") % total_subgroups
        div_label.add_theme_color_override("font_color", UI_THEME.color("warning"))
        diversity_list.add_child(div_label)

        var bonus_label = Label.new()
        bonus_label.text = tr("Active bonuses: (coming later)")
        bonus_label.add_theme_color_override("font_color", UI_THEME.color("warning").darkened(0.3))
        diversity_list.add_child(bonus_label)
    else:
        diversity_list.add_child(_build_empty_label(tr("No domesticated resources yet")))

# Returns the array of the subgroups of the resource. It supports both a string and an array.
func _get_subgroups(data: Dictionary) -> Array:
    var subgroup = data.get("subgroup", "other")
    if subgroup is Array:
        return subgroup
    return [subgroup]
