# challenges_tab.gd
#
# The tab "Challenges": the fame a good of the city can earn and the tasks the era sets the city.
#
# The tab is the list the player is promised before he has earned anything — what each rung of the
# ladder gives and how far the city has already walked. Nothing is withheld: the tiers of a good all
# stand there, done and not yet reached alike, and so do the tasks of the eras that are not live.
#
# The counters themselves are not computed here. ChallengeManager (scripts/challenge_manager.gd)
# owns them and hands the tab ready-made records; the tab only says what a record means and how far
# the city stands from its threshold.
#
# The state of the city changes the list while the window is open — a town takes goods every tick,
# an era ends, a chunk is bought — so the tab listens to the signals of the manager instead of
# guessing when to redraw.
extends Node

const UI_THEME = preload("res://scripts/ui_theme.gd")

const ICON_SIZE := 40
const ICON_FALLBACK := "reputation_specialization.svg"

# A task of an era that is not live is faded as a whole: the player reads what it asks and sees that
# the world is not asking it now.
const MUTED_MODULATE := Color(0.82, 0.82, 0.82, 0.55)

var title_label: Label = null
var list: Node = null
var panel: Control = null

var _main_map = null
# The manager is found once and its signals are connected once: a refresh of the tab must not stack
# the same handler again and again.
var _bound_manager = null

func setup(p: Control):
    if p == null or not is_instance_valid(p):
        return
    panel = p
    title_label = p.get_node_or_null("TitleLabel")
    list = p.get_node_or_null("Body/ScrollContainer/ChallengeList")
    if title_label != null and is_instance_valid(title_label):
        # The caption carries the era as well, so it has to reach the right edge of the panel.
        title_label.anchor_right = 1.0
        title_label.offset_right = -8.0
        title_label.autowrap_mode = TextServer.AUTOWRAP_OFF

func set_map(main_map) -> void:
    _main_map = main_map
    _bind_manager()

# The manager is a child of the map and is created with it, so an absent manager only means a tab
# with nothing to count. It is read through get(): a window built by hand for a test may carry a map
# without the member at all.
func _manager():
    if _main_map == null or not is_instance_valid(_main_map):
        return null
    return _main_map.get("challenge_manager")

func _bind_manager() -> void:
    var manager = _manager()
    if manager == _bound_manager:
        return
    if _bound_manager != null and is_instance_valid(_bound_manager):
        if _bound_manager.fame_tier_completed.is_connected(_on_fame_tier_completed):
            _bound_manager.fame_tier_completed.disconnect(_on_fame_tier_completed)
        if _bound_manager.challenge_completed.is_connected(_on_challenge_completed):
            _bound_manager.challenge_completed.disconnect(_on_challenge_completed)
    _bound_manager = manager
    if manager == null:
        return
    manager.fame_tier_completed.connect(_on_fame_tier_completed)
    manager.challenge_completed.connect(_on_challenge_completed)

func _on_fame_tier_completed(_tier_id: String, _tier: String, _reward: Dictionary) -> void:
    _redraw_if_open()

func _on_challenge_completed(_challenge: Dictionary) -> void:
    _redraw_if_open()

# A tier is paid for in the middle of a tick, so the redraw happens only while the player looks at
# the list; otherwise the next opening of the tab builds it fresh.
func _redraw_if_open() -> void:
    if panel != null and is_instance_valid(panel) and panel.visible:
        refresh()

func refresh() -> void:
    if list == null or not is_instance_valid(list):
        return
    _bind_manager()
    _clear_list()
    _update_title()
    var manager = _manager()
    if manager == null:
        _add_muted(tr("The city is not on the map yet."))
        return
    _add_era_challenges(manager)
    _add_fame(manager)

func _clear_list() -> void:
    for child in list.get_children():
        list.remove_child(child)
        child.queue_free()

# --- The caption ---

# The era stands in the caption because two of its tasks are judged when the era closes: the number
# says which window is running.
func _update_title() -> void:
    if title_label == null or not is_instance_valid(title_label):
        return
    var parts: Array = [tr("Challenges")]
    if _main_map != null and is_instance_valid(_main_map):
        parts.append(_era_name(int(_main_map.current_era)))
    title_label.text = " | ".join(parts)

func _era_name(index: int) -> String:
    var eras: Array = GameData.eras
    if index >= 0 and index < eras.size():
        return str(eras[index].get("name", ""))
    return tr("Era %d") % (index + 1)

# --- The tasks of the era ---

# The one-off tasks of data/challenges.json, in the order of the data: the live window first, then
# the tasks of another era and the ones the city has done. A task of another era is not hidden — the
# player sees what the world will ask, only not yet.
func _add_era_challenges(manager) -> void:
    var live: Array = []
    var later: Array = []
    var done: Array = []
    for record in GameData.challenges:
        if not (record is Dictionary):
            continue
        if manager.is_challenge_completed(str(record.get("id", ""))):
            done.append(record)
        elif manager.offers_in_current_era(record):
            live.append(record)
        else:
            later.append(record)
    if live.is_empty() and later.is_empty() and done.is_empty():
        return

    if not live.is_empty():
        _add_header(tr("Challenges of this era"))
        for record in live:
            list.add_child(_era_plate(record, manager, true))
    if not later.is_empty():
        _add_gap()
        _add_header(tr("Challenges of another era"))
        for record in later:
            var plate := _era_plate(record, manager, false)
            plate.modulate = MUTED_MODULATE
            list.add_child(plate)
    if not done.is_empty():
        _add_gap()
        _add_header(tr("Completed"))
        for record in done:
            list.add_child(_era_plate(record, manager, false, tr("Done")))

func _era_plate(record: Dictionary, manager, is_live: bool, done_text: String = "") -> Control:
    var name_text := str(record.get("name", ""))
    if name_text == "":
        name_text = str(record.get("id", ""))
    var plate := _plate(str(record.get("icon", "")), name_text,
            str(record.get("description", "")))
    var body: VBoxContainer = plate.get_node("Row/Body")

    if is_live:
        var text := str(manager.era_challenge_progress(record).get("text", ""))
        if text != "":
            body.add_child(_line(text, UI_THEME.color("warning")))
    if record.has("era"):
        body.add_child(_line(tr("The window: %s") % _era_name(int(record.get("era", 0))),
                UI_THEME.color("text_secondary")))
    _add_rewards(body, manager.rewards_of(record), "", manager)
    if done_text != "":
        body.add_child(_line(done_text, UI_THEME.color("income")))
    return plate

# --- The ladder of a good ---

# Every fame block of every good, grouped by the good and in the order of the rungs. The rungs of a
# good share one counter, so the list reads as one ladder rather than as three unrelated tasks.
func _add_fame(manager) -> void:
    var records: Array = manager.fame_records()
    if records.is_empty():
        return
    _add_gap()
    _add_header(tr("The fame of a good"))
    var current_product := ""
    for record in records:
        var pid := str(record.get("product", ""))
        if pid != current_product:
            current_product = pid
            _add_gap()
            _add_header(GameData.get_good_display_name(pid))
        list.add_child(_fame_plate(record, manager))

func _fame_plate(record: Dictionary, manager) -> Control:
    var name_text := str(record.get("name", ""))
    if name_text == "":
        name_text = _tier_caption(str(record.get("tier", "")), str(record.get("product_name", "")))
    var plate := _plate(str(record.get("icon", "")), name_text, str(record.get("description", "")))
    var body: VBoxContainer = plate.get_node("Row/Body")

    var line := "%s: %d / %d" % [_trigger_label(str(record.get("trigger", "sell"))),
            int(record.get("progress", 0)), int(record.get("threshold", 0))]
    var quality := str(record.get("min_quality", ""))
    if quality != "":
        line += " (%s)" % (tr("%s or better") % GameData.get_quality_name(quality))
    var reached: bool = record.get("done", false)
    body.add_child(_line(line, UI_THEME.color("income") if reached
            else UI_THEME.color("text_secondary")))

    _add_rewards(body, _rewards_of(record.get("reward", null)),
            str(record.get("product", "")), manager)
    if reached:
        body.add_child(_line(tr("Reached"), UI_THEME.color("income")))
    return plate

# A reward record or a list of them — the shape the data may use for either.
func _rewards_of(reward) -> Array:
    if reward is Dictionary:
        return [reward]
    if reward is Array:
        return reward
    return []

func _add_rewards(body: VBoxContainer, rewards: Array, product_id: String, manager) -> void:
    for reward in rewards:
        if not (reward is Dictionary):
            continue
        var text: String = manager.reward_text(reward, product_id)
        if text != "":
            body.add_child(_line("• " + text, UI_THEME.color("income")))

# The rung of the ladder, named by the good it is about. The author may give the block a name of its
# own — the prestige task usually has one — and then the data wins.
func _tier_caption(tier: String, product_name: String) -> String:
    match tier:
        "reputation":
            return tr("Known for %s") % product_name
        "brand":
            return tr("The brand of %s") % product_name
    return tr("The challenge of %s") % product_name

func _trigger_label(trigger: String) -> String:
    if trigger == "produce":
        return tr("Produced")
    return tr("Sold")

# --- The pieces of the list ---

# A plate: the mark of the good, its name and the lines of what it asks and gives. The same shape as
# the plate of a specialization, so the two lists of the city read alike.
func _plate(icon_name: String, name_text: String, description: String) -> PanelContainer:
    var card := PanelContainer.new()
    var style := UI_THEME.row(UI_THEME.color("panel_bg"))
    UI_THEME.set_content_margins(style, 8.0)
    card.add_theme_stylebox_override("panel", style)

    var row := HBoxContainer.new()
    row.name = "Row"
    row.add_theme_constant_override("separation", 10)
    card.add_child(row)
    row.add_child(_icon(icon_name))

    var body := VBoxContainer.new()
    body.name = "Body"
    body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    body.add_theme_constant_override("separation", 2)
    row.add_child(body)

    var name_label := Label.new()
    name_label.text = name_text
    name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    body.add_child(name_label)

    if description != "":
        body.add_child(_line(description, UI_THEME.color("text_muted")))
    return card

# A plate without a picture of its own (a mod that ships none) keeps its height and shows the common
# mark of the city instead of collapsing the row.
func _icon(icon_name: String) -> TextureRect:
    var icon_rect := TextureRect.new()
    var texture: Texture2D = null
    if icon_name != "":
        texture = IconRegistry.get_texture(icon_name)
    if texture == null:
        texture = IconRegistry.get_texture(ICON_FALLBACK)
    if texture != null:
        icon_rect.texture = texture
    icon_rect.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
    icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
    icon_rect.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return icon_rect

func _line(text: String, color: Color) -> Label:
    var label := Label.new()
    label.text = text
    label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.add_theme_color_override("font_color", color)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return label

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
