# challenges_tab.gd
#
# The tab "Challenges": the fame a good of the city can earn and the tasks the era sets the city.
#
# The tab is the list the player is promised before he has earned anything — what each rung of the
# ladder gives and how far the city has already walked. Nothing is withheld: every task of the era
# and every ladder of every good stands in the list, done and not yet reached alike. Each of them is
# a fold, so the tab reads as a table of contents and the name of a fold says what stands under it:
# the tasks of an era group fold under the group, and the three tiers of a good fold under the name
# of the challenge they lead to.
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

# The mark of a fold: its contents stand under its name, hidden until the player asks.
const FOLD_CLOSED := "▸"
const FOLD_OPEN := "▾"
const FOLD_ICON_SIZE := 24
const FOLD_INDENT := 14

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
# Which folds the player has opened. The list is rebuilt whenever a rung is paid or the city
# changes, and a rebuild must not close what the player just opened.
var _expanded: Dictionary = {}

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
        if _bound_manager.challenge_failed.is_connected(_on_challenge_failed):
            _bound_manager.challenge_failed.disconnect(_on_challenge_failed)
    _bound_manager = manager
    if manager == null:
        return
    manager.fame_tier_completed.connect(_on_fame_tier_completed)
    manager.challenge_completed.connect(_on_challenge_completed)
    manager.challenge_failed.connect(_on_challenge_failed)

func _on_fame_tier_completed(_tier_id: String, _tier: String, _reward: Dictionary) -> void:
    _redraw_if_open()

func _on_challenge_completed(_challenge: Dictionary) -> void:
    _redraw_if_open()

func _on_challenge_failed(_challenge: Dictionary) -> void:
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
# the tasks of another era, the ones the city has done and the ones it has lost. A task of another
# era is not dropped — the player sees what the world will ask, only not yet. Each group is a fold of
# its own, so the tasks of the era take a few lines while the player is not reading them.
func _add_era_challenges(manager) -> void:
    var live: Array = []
    var later: Array = []
    var done: Array = []
    var lost: Array = []
    for record in GameData.challenges:
        if not (record is Dictionary):
            continue
        var id := str(record.get("id", ""))
        if manager.is_challenge_completed(id):
            done.append(record)
        elif manager.is_challenge_failed(id):
            lost.append(record)
        elif manager.offers_in_current_era(record):
            live.append(record)
        else:
            later.append(record)
    _add_era_fold("era_live", tr("Challenges of this era"), live, manager, true, "")
    _add_era_fold("era_later", tr("Challenges of another era"), later, manager, false, "")
    _add_era_fold("era_done", tr("Completed"), done, manager, false, tr("Done"),
            UI_THEME.color("income"))
    _add_era_fold("era_lost", tr("Failed"), lost, manager, true, tr("Failed"),
            UI_THEME.color("expense"))

# One group of the tasks of the era. A task of an era that is not live is faded as a whole; a task
# the city has finished is not, because the list already says so in words. The counter of a lost task
# stays under its name: the player reads not only that the era is gone, but what took it.
func _add_era_fold(key: String, title: String, records: Array, manager, is_live: bool,
        done_text: String, done_tint: Color = Color.WHITE) -> void:
    if records.is_empty():
        return
    _add_gap_if_not_top()
    var expanded := _is_expanded(key)
    list.add_child(_fold_toggle(key, title, str(records[0].get("icon", "")), expanded))
    if not expanded:
        return
    var body := _fold_body()
    for record in records:
        var plate := _era_plate(record, manager, is_live, done_text, done_tint)
        if not is_live and done_text == "":
            plate.modulate = MUTED_MODULATE
        body.add_child(plate)

func _era_plate(record: Dictionary, manager, is_live: bool, done_text: String = "",
        done_tint: Color = Color.WHITE) -> Control:
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
        body.add_child(_line(done_text, done_tint))
    return plate

# --- The ladder of a good ---

# Every fame block of every good, grouped into one fold per good. The tiers of a good share one
# counter, so they are one ladder and not three unrelated tasks — and the ladder of a good the city
# has not touched yet is a promise, not a task: it stands closed until the player asks for it.
func _add_fame(manager) -> void:
    var groups := {}
    var order: Array = []
    for record in manager.fame_records():
        var pid := str(record.get("product", ""))
        if not groups.has(pid):
            groups[pid] = []
            order.append(pid)
        groups[pid].append(record)
    if order.is_empty():
        return
    _add_gap_if_not_top()
    _add_header(tr("Reputation and specialization"))
    for pid in order:
        var rungs: Array = groups[pid]
        # The records come in the order of the identifiers; the ladder goes in the order of the tiers.
        rungs.sort_custom(func(a, b):
                return _tier_rank(manager, a) < _tier_rank(manager, b))
        _add_ladder(pid, rungs, manager)

func _tier_rank(manager, record: Dictionary) -> int:
    return (manager.TIERS as Array).find(str(record.get("tier", "")))

func _add_ladder(product: String, records: Array, manager) -> void:
    var reached := 0
    var working := 0
    for record in records:
        if record.get("done", false):
            reached += 1
        elif int(record.get("progress", 0)) > 0:
            working += 1
    # The head of the fold says how far the ladder has come, so that a closed one is not a riddle.
    var progress := ""
    if reached == records.size():
        progress = "— " + tr("Done")
    elif reached > 0 or working > 0:
        progress = "(%d / %d)" % [reached, records.size()]

    _add_gap_if_not_top()
    var expanded := _is_expanded(product)
    list.add_child(_fold_toggle(product, _ladder_name(manager, records, product),
            str(records[0].get("icon", "")), expanded, progress))
    if not expanded:
        return
    var rungs := _fold_body()
    for record in records:
        rungs.add_child(_fame_plate(record, manager))

# A ladder is named by its challenge: the task of the last rung is the name of the whole way. A
# ladder whose challenge carries no name is titled by its good.
func _ladder_name(manager, records: Array, product: String) -> String:
    for record in records:
        if str(record.get("tier", "")) == str(manager.TIER_CHALLENGE):
            var name := str(record.get("name", ""))
            if name != "":
                return name
    return GameData.get_product_name(product)

# The head of a fold: the mark of what stands under it, its name, and how far the city has come
# along it. Collapsed, it still answers the question the closed list would otherwise hide — whether
# the way is untouched, in progress, or walked to the end.
func _fold_toggle(key: String, title: String, icon_name: String, expanded: bool,
        progress: String = "") -> Button:
    var button := Button.new()
    button.name = "FoldToggle"
    button.flat = true
    button.focus_mode = Control.FOCUS_NONE
    button.alignment = HORIZONTAL_ALIGNMENT_LEFT
    button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    button.text = "%s %s" % [FOLD_OPEN if expanded else FOLD_CLOSED, title]
    if progress != "":
        button.text += " " + progress
    var texture := _icon_texture(icon_name)
    if texture != null:
        button.icon = texture
        button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
        button.add_theme_constant_override("icon_max_width", FOLD_ICON_SIZE)
    button.add_theme_color_override("font_color", UI_THEME.color("text_secondary"))
    button.add_theme_color_override("font_hover_color", UI_THEME.color("text"))
    button.add_theme_color_override("font_pressed_color", UI_THEME.color("text"))
    button.pressed.connect(_on_fold_toggled.bind(key))
    return button

# The contents of a fold, indented under its head. A MarginContainer stacks its children in one rect,
# so they stand in a container of their own inside the indent.
func _fold_body() -> VBoxContainer:
    var edge := MarginContainer.new()
    edge.name = "FoldEdge"
    edge.add_theme_constant_override("margin_left", FOLD_INDENT)
    edge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list.add_child(edge)
    var body := VBoxContainer.new()
    body.name = "FoldBody"
    body.add_theme_constant_override("separation", 4)
    edge.add_child(body)
    return body

func _on_fold_toggled(key: String) -> void:
    _expanded[key] = not _is_expanded(key)
    refresh()

func _is_expanded(key: String) -> bool:
    return bool(_expanded.get(key, false))

func _fame_plate(record: Dictionary, manager) -> Control:
    # The rung is named by its tier alone; the good it works and the market it works on stand in the
    # condition line under the name, together with how far the city has come.
    var name_text := _tier_caption(str(record.get("tier", "")))
    var plate := _plate(str(record.get("icon", "")), name_text, str(record.get("description", "")))
    var body: VBoxContainer = plate.get_node("Row/Body")

    var line := _condition_line(record)
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

# The head of a rung says which of the three tiers it is. The name of the fold above it is the name
# of the task the last rung gives, not the name of the good.
func _tier_caption(tier: String) -> String:
    match tier:
        "reputation":
            return tr("Reputation")
        "brand":
            return tr("Brand")
    return tr("Specialization")

# The condition of a rung names the good and the market, because neither is obvious from the tier:
# the head of the fold is named by the task of the last rung, and a counter of "sold" would read as
# any sale while the fame of a good counts only what a town takes from the storage of the city.
# The name of the good comes from its record, so a ladder added by a mod is titled by its own data.
func _condition_line(record: Dictionary) -> String:
    var product := str(record.get("product_name", ""))
    var progress := int(record.get("progress", 0))
    var threshold := int(record.get("threshold", 0))
    if str(record.get("trigger", "sell")) == "produce":
        return tr("%s: %d/%d produced") % [product, progress, threshold]
    return tr("%s: %d/%d sold to the towns") % [product, progress, threshold]

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
    var texture: Texture2D = _icon_texture(icon_name)
    if texture != null:
        icon_rect.texture = texture
    icon_rect.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
    icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
    icon_rect.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
    icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return icon_rect

func _icon_texture(icon_name: String) -> Texture2D:
    var texture: Texture2D = null
    if icon_name != "":
        texture = IconRegistry.get_texture(icon_name)
    if texture == null:
        texture = IconRegistry.get_texture(ICON_FALLBACK)
    return texture

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

# The first thing in the list needs no air above it; every fold or header that follows another does.
func _add_gap_if_not_top() -> void:
    if list.get_child_count() > 0:
        _add_gap()
