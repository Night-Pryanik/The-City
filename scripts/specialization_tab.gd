# specialization_tab.gd
#
# The tab "Specialization" of the city: the branches the city may take, the branches it has taken,
# the branches it cannot take yet and the milestone it is working towards.
#
# The tab is the same view as the choice window — the plates are built by specialization_cards.gd —
# with one difference: here the choice can be made at any moment, without waiting for a milestone to
# offer the window again. A pick the player postponed is spent here.
#
# The whole list of the specializations of the game is always reachable: the branches that cannot be
# taken yet stand under a disclosure (the toggle and the container of the plates), the same idiom as
# the unavailable goods of the tab "Trade". Nothing is withheld from the player — a branch the city
# cannot reach yet still says what it will give and what it waits for.
#
# The tab is a view of CityData (the section "THE SPECIALIZATIONS OF THE CITY"): it decides nothing,
# it draws the state and hands a pick to CityData. The list is rebuilt on every opening, on a pick
# (CityData.specialization_changed, see city_ui._on_specialization_changed) and on a change of the
# population.
extends Node

# The "single source of truth" script for the styling constants shared with the other tabs.
const UI_THEME = preload("res://scripts/ui_theme.gd")
const SpecCards = preload("res://scripts/specialization_cards.gd")

var title_label: Label = null
var list: Node = null

# The disclosure of the branches that cannot be taken yet. It is built anew on every refresh, so the
# state of the toggle is kept here, not in the nodes: a pick rebuilds the list, and a click on the
# toggle must not be undone by it.
var locked_header: Button = null
var locked_list: VBoxContainer = null
var locked_open: bool = false

func setup(panel: Control):
    if panel == null or not is_instance_valid(panel):
        return
    title_label = panel.get_node_or_null("TitleLabel")
    list = panel.get_node_or_null("Body/ScrollContainer/SpecializationList")
    if title_label != null and is_instance_valid(title_label):
        # The caption carries the numbers of the tab as well (the unspent picks and the next
        # milestone), so it has to reach the right edge of the panel: the scene gives it the 183 px
        # of the bare word, and a long line would run out of its box.
        title_label.anchor_right = 1.0
        title_label.offset_right = -8.0
        title_label.autowrap_mode = TextServer.AUTOWRAP_OFF

func refresh() -> void:
    if list == null or not is_instance_valid(list):
        return
    _clear_list()
    var pending: int = CityData.get_pending_specialization_picks()
    _update_title(pending)
    _add_available(pending)
    _add_chosen()
    _add_locked()

# Empties the list. The rows are detached before they are freed: a rebuild in the same frame (a pick
# signals the city window and the tab refreshes itself as well) must not walk the rows that are
# already on their way out.
func _clear_list() -> void:
    for child in list.get_children():
        list.remove_child(child)
        child.queue_free()
    locked_header = null
    locked_list = null

# --- The branches ---

# What the city may take right now. The button is offered only when a pick is unspent: a plate with
# a button that cannot do anything is a lie about the state of the city.
func _add_available(pending: int) -> void:
    var available: Array = CityData.get_available_specializations()
    if available.is_empty():
        if pending > 0:
            _add_muted(tr("No specialization can be taken right now."))
        return
    _add_header(tr("Available"))
    var on_choose := Callable()
    if pending > 0:
        on_choose = _on_choose
    for spec in available:
        list.add_child(SpecCards.build(spec, on_choose))

func _add_chosen() -> void:
    var chosen: Array = CityData.get_chosen_specializations()
    if chosen.is_empty():
        _add_gap()
        _add_muted(tr("No specialization chosen yet."))
        return
    _add_gap()
    _add_header(tr("Chosen"))
    for spec in chosen:
        list.add_child(SpecCards.build(spec))

# The branches the city cannot take yet, under a disclosure: the toggle carries the arrow and the
# number of the branches behind it, so the player sees that there is something to open without
# opening it. The plates are built at once and the toggle only flips their visibility — a rebuild on
# every click would lose the node identity (and the plate under the cursor).
func _add_locked() -> void:
    var locked: Array = CityData.get_locked_specializations()
    if locked.is_empty():
        return
    _add_gap()

    locked_header = Button.new()
    locked_header.toggle_mode = true
    locked_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
    locked_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    locked_header.button_pressed = locked_open
    locked_header.toggled.connect(_on_locked_toggled)
    list.add_child(locked_header)

    locked_list = VBoxContainer.new()
    locked_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    locked_list.add_theme_constant_override("separation", 6)
    # The collapsed state is also the initial one: the container is hidden from the start, so the
    # list is never drawn with the closed branches visible for one frame.
    locked_list.visible = locked_open
    list.add_child(locked_list)

    for spec in locked:
        locked_list.add_child(SpecCards.build(spec))
    _update_locked_header(locked.size())

func _on_locked_toggled(pressed: bool) -> void:
    locked_open = pressed
    if locked_list != null and is_instance_valid(locked_list):
        locked_list.visible = pressed
    if locked_header != null and is_instance_valid(locked_header) \
            and locked_list != null and is_instance_valid(locked_list):
        _update_locked_header(locked_list.get_child_count())

# The caption of the toggle: the arrow shows the state of the disclosure, the number — how many
# branches are behind it.
func _update_locked_header(count: int) -> void:
    if locked_header == null or not is_instance_valid(locked_header):
        return
    var arrow := "▾" if locked_open else "▸"
    locked_header.text = "%s %s (%d)" % [arrow, tr("Unavailable specializations"), count]

func _on_choose(id: String) -> void:
    # The pick itself is CityData's business; the rebuild comes with specialization_changed.
    CityData.choose_specialization(id)

# --- The caption and the next milestone ---

# The caption of the tab: its name and the two numbers the player needs at a glance — the picks
# earned and not spent yet, and the milestone the city is working towards. One line, the parts
# separated by a bar, the way the top row of the city window reads. The list below belongs to the
# branches; a line about the state of the city would only add a row between them.
func _update_title(pending: int) -> void:
    if title_label == null or not is_instance_valid(title_label):
        return
    var parts: Array = [tr("Specialization")]
    if pending > 0:
        parts.append(tr("Unspent choices: %d") % pending)
    var next_threshold: int = CityData.get_next_specialization_threshold()
    if next_threshold > 0:
        parts.append(tr("Next choice at %d citizens (population: %d)") \
                % [next_threshold, CityData.total_population])
    else:
        # A progression that is over says so instead of naming a threshold that will never come.
        parts.append(tr("Every milestone has been reached."))
    title_label.text = " | ".join(parts)

# --- The pieces of the list ---

func _add_header(text: String) -> void:
    var header := Label.new()
    header.text = text
    header.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
    list.add_child(header)

func _add_muted(text: String) -> void:
    var label := Label.new()
    label.text = text
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.add_theme_color_override("font_color", UI_THEME.color("text_muted"))
    list.add_child(label)

func _add_gap() -> void:
    var gap := Control.new()
    gap.custom_minimum_size = Vector2(0, 6)
    list.add_child(gap)
