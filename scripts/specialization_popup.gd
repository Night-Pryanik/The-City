# specialization_popup.gd
#
# The window that offers a specialization when the city reaches the next milestone of the
# population (data/specializations.json, "thresholds").
#
# The simulation is stopped while the window is open (get_tree().paused) and the window keeps
# running (PROCESS_MODE_ALWAYS): the world waits for the decision, and the player keeps looking at
# the map behind the scrim while deciding.
#
# The decision may be postponed: "Postpone" only closes the window and the pick stays unspent, so
# the choice can be made later in the tab "Specialization" of the city window. A window opened on a
# milestone the player does not want to spend yet must not force a branch.
#
# A city that has earned more than one pick sees the same window again after the first choice: the
# picks are spent one at a time, so a milestone that arrives while another one is still unspent (a
# loaded save, a debug jump of the population) cannot swallow a choice.
extends Control

const UI_THEME = preload("res://scripts/ui_theme.gd")
const SpecCards = preload("res://scripts/specialization_cards.gd")

var panel: Panel = null
var title_label: Label = null
var subtitle_label: Label = null
var cards_box: VBoxContainer = null
var hint_label: Label = null
var confirm_button: Button = null
var postpone_button: Button = null
var scroll: ScrollContainer = null

# The branch the player has clicked but not confirmed yet.
var _selected_id: String = ""
# The branch under the mouse: the hover is a fill of its own, because a row of a list is a plate
# and not a button with a pressed state.
var _hovered_id: String = ""
# The plates, by the id of the branch: { id: PanelContainer }.
var _cards: Dictionary = {}

func _ready():
    # The window lives through the pause of the tree — it is the one node that has to.
    process_mode = Node.PROCESS_MODE_ALWAYS

    var dim := Scrim.new()
    dim.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(dim)

    var center := CenterContainer.new()
    center.set_anchors_preset(Control.PRESET_FULL_RECT)
    center.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(center)

    panel = Panel.new()
    panel.custom_minimum_size = Vector2(620, 520)
    center.add_child(panel)

    var vbox := VBoxContainer.new()
    vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
    vbox.offset_left = 20
    vbox.offset_top = 18
    vbox.offset_right = -20
    vbox.offset_bottom = -18
    vbox.add_theme_constant_override("separation", 8)
    panel.add_child(vbox)

    title_label = Label.new()
    title_label.add_theme_font_size_override("font_size", 20)
    title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    vbox.add_child(title_label)

    subtitle_label = Label.new()
    subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    subtitle_label.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
    vbox.add_child(subtitle_label)

    # The plates scroll: the window must stay inside the screen whatever the number of the branches
    # in the data.
    scroll = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
    vbox.add_child(scroll)

    cards_box = VBoxContainer.new()
    cards_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    cards_box.add_theme_constant_override("separation", 6)
    scroll.add_child(cards_box)

    var buttons := HBoxContainer.new()
    buttons.add_theme_constant_override("separation", 12)
    vbox.add_child(buttons)

    hint_label = Label.new()
    hint_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    hint_label.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
    buttons.add_child(hint_label)

    postpone_button = Button.new()
    postpone_button.custom_minimum_size = Vector2(160, 36)
    postpone_button.pressed.connect(_on_postpone_pressed)
    buttons.add_child(postpone_button)

    confirm_button = Button.new()
    confirm_button.custom_minimum_size = Vector2(160, 36)
    confirm_button.disabled = true
    confirm_button.pressed.connect(_on_confirm_pressed)
    buttons.add_child(confirm_button)

    _apply_theme_colors()
    _apply_static_text()
    # The colours of the window are per-node overrides, which win over the project theme: a new
    # palette has to be written into the same nodes by hand.
    ThemeManager.theme_applied.connect(_apply_theme_colors)

# The surface and the text colours of the window, one place for the build and for every later
# palette.
func _apply_theme_colors() -> void:
    panel.add_theme_stylebox_override("panel", UI_THEME.window_plate())
    title_label.add_theme_color_override("font_color", UI_THEME.color("income").lightened(0.35))
    subtitle_label.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
    hint_label.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
    _paint_cards()

# The labels that do not depend on the state of the city: set once on creation and once more on a
# language change — the nodes built in code are not translated by Godot itself.
func _apply_static_text() -> void:
    if title_label:
        title_label.text = tr("Your city has reached a significant milestone!")
    if confirm_button:
        # A context of its own: "Confirm" is the title of a dialog elsewhere, while here it is the
        # button of the decision, and the two want different Russian words.
        confirm_button.text = tr("Confirm", "specialization_popup_confirm")
    if postpone_button:
        postpone_button.text = tr("Postpone")

# Rebuilds the window on the new language. Called from LocalizationManager (see
# main_map._on_locale_changed); it does nothing on a hidden window.
func refresh() -> void:
    _apply_static_text()
    if visible:
        _render()

# --- The window ---

# Opens the window for the next unspent pick. Nothing happens when the city has nothing to spend:
# the window is a consequence of the state, not a place to look the state up.
func open() -> void:
    if CityData.get_pending_specialization_picks() <= 0:
        return
    _selected_id = ""
    _hovered_id = ""
    _render()
    size = get_viewport_rect().size
    position = Vector2.ZERO
    show()
    # The choice is a decision of the player and the world waits for it.
    get_tree().paused = true

# Whether the window holds the simulation stopped. The owner of the pause flag asks this before it
# resumes the world (see main_map.apply_pause_state).
func is_open() -> bool:
    return visible

func _render() -> void:
    if cards_box == null:
        return
    for child in cards_box.get_children():
        cards_box.remove_child(child)
        child.queue_free()
    _cards.clear()

    var pending: int = CityData.get_pending_specialization_picks()
    subtitle_label.text = tr("Population: %d. Choose a specialization — the choice is permanent.") \
            % CityData.total_population
    if pending > 1:
        subtitle_label.text += " " + tr("Unspent choices: %d.") % pending

    var available: Array = CityData.get_available_specializations()
    for spec in available:
        var id := str(spec.get("id", ""))
        var card := SpecCards.build(spec)
        card.gui_input.connect(_on_card_input.bind(id))
        card.mouse_entered.connect(_on_card_hover.bind(id, true))
        card.mouse_exited.connect(_on_card_hover.bind(id, false))
        cards_box.add_child(card)
        _cards[id] = card

    if available.is_empty():
        # Every branch is either taken or still closed: the pick is earned, but there is nothing to
        # spend it on. The window says so instead of showing an empty list.
        var empty := Label.new()
        empty.text = tr("No specialization can be taken right now.")
        empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        empty.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
        cards_box.add_child(empty)
        _selected_id = ""

    if not _cards.has(_selected_id):
        _selected_id = ""
    _update_confirm()

# The fill of a plate carries its state: plain, hovered, selected. It is repainted as a whole,
# because the states do not nest — a selected plate that is hovered stays selected.
func _paint_cards() -> void:
    for id in _cards:
        var card: PanelContainer = _cards[id]
        if card == null or not is_instance_valid(card):
            continue
        var style := UI_THEME.row(_card_color(str(id)))
        UI_THEME.set_content_margins(style, 8.0)
        card.add_theme_stylebox_override("panel", style)

func _card_color(id: String) -> Color:
    if id == _selected_id:
        return UI_THEME.color("row_selected")
    if id == _hovered_id:
        return UI_THEME.color("row_hover")
    return UI_THEME.color("panel_bg")

func _on_card_hover(id: String, entered: bool) -> void:
    _hovered_id = id if entered else ("" if _hovered_id == id else _hovered_id)
    _paint_cards()

func _on_card_input(event: InputEvent, id: String) -> void:
    if not (event is InputEventMouseButton):
        return
    var mouse_event := event as InputEventMouseButton
    if not mouse_event.pressed or mouse_event.button_index != MOUSE_BUTTON_LEFT:
        return
    _selected_id = id
    _paint_cards()
    _update_confirm()

func _update_confirm() -> void:
    if confirm_button == null:
        return
    confirm_button.disabled = _selected_id.is_empty()
    if _cards.is_empty():
        # There is nothing to pick: the list already says so, and a hint to pick a branch would
        # contradict it.
        hint_label.text = ""
        return
    hint_label.text = "" if not _selected_id.is_empty() \
            else tr("Pick a specialization to continue.")

func _on_confirm_pressed() -> void:
    if _selected_id.is_empty():
        return
    if not CityData.choose_specialization(_selected_id):
        return
    if CityData.get_pending_specialization_picks() > 0 \
            and not CityData.get_available_specializations().is_empty():
        # Another milestone is still unspent and there is something to spend it on: the same window
        # offers the next pick.
        _selected_id = ""
        _hovered_id = ""
        _render()
        return
    close()

# The decision is postponed: the window closes and the pick stays unspent. It is not lost — the tab
# "Specialization" of the city window takes it whenever the player wants, and the next milestone
# offers the window again.
func _on_postpone_pressed() -> void:
    close()

func close() -> void:
    hide()
    _selected_id = ""
    _hovered_id = ""
    # The pause flag belongs to the map: it also answers for the active pause, the pause menu and
    # the journal, and resuming on our own would start a world the player had stopped.
    var main_map = get_tree().root.find_child("MainMap", true, false)
    if main_map != null and main_map.has_method("apply_pause_state"):
        main_map.apply_pause_state()
    else:
        get_tree().paused = false

func _input(event: InputEvent) -> void:
    # ESC postpones the choice, exactly as the button does, and must not reach the pause menu: the
    # key belongs to the window while it is open.
    if not is_visible_in_tree():
        return
    if event.is_action_pressed("ui_cancel"):
        get_viewport().set_input_as_handled()
        _on_postpone_pressed()
