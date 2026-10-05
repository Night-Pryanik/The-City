# trade_tab.gd
# The tab "Trade". On the left — the INTERNAL trade, on the right — the EXTERNAL
# (a stub column, the external trade itself is not implemented yet).
#
#
# The left column: one card per resource or group of resources, which
# the city is currently consuming. The source of the data is
# worker_manager.get_population_consumption_map(): the professions of the workers and
# the citizens + the pseudo-profession "All citizens", the key of the row is display_key.
#
#
# The LAYOUT of the card lives in the scene res://scenes/TradeResourceCard.tscn, and not
# in the code: the script instantiates it and substitutes only the values. In this way any
# element of the card can be moved with the mouse in the scene editor.
#
#
# The UPDATE is subordinated to the resource display interval from the settings
# (CityData.resource_display_epoch, see city_ui._refresh_light), as the tab
# "Resources". Previously the cards were recalculated every tick, which is why the
# numbers flickered and the tooltips, which the player moves the mouse over, fell off.
#
#
# The TOOLTIPS are filled right here, on the update of the card, and NOT on hover.
# The reason is a feature of the engine: a Label has mouse_filter = IGNORE by default,
# therefore the signal mouse_entered never comes to such a node at all, and the approach
# "hovered — assembled the text — assigned tooltip_text" never worked
# (checked on Godot 4.7). The nodes with the tooltips in the scene have
# mouse_filter = 0 (STOP), and the text is put in advance — in this way the tooltip also
# coincides with the numbers on the card: it is assembled from the same data of the same window.
# The only exception is the breakdown by quality: it is its own panel
# of ui_helpers, and it is still hung on hover.
#
#
# The INCOME in the row "Income" is the FACT over the display window (so many coins per second
# the market has really brought to the treasury), and not the plan "the whole demand × the price". The plan is not
# limited by the storage and for a half-empty storage gave fantastic 2730 coins/sec, which
# never happened in the treasury; the fact, on the contrary, coincides with the number in the row "Treasury" of the HUD.
# The plan has remained in the tooltip of the row — that is where it belongs.
extends Node

# The scene of the card of one resource (see the file of the scene — there is also a list of the nodes
# to which this script refers).
const CARD_SCENE = preload("res://scenes/TradeResourceCard.tscn")
# The scene of the card of one resource (see the file of the scene — there is also a list of the nodes
# to which this script refers).
const UiHelpers = preload("res://scripts/ui_helpers.gd")

var internal_list: Node
var ui_helpers: Node
# The source of the constants of the styling (QUALITY_MARKER_COLOR) — the same accent
# of the interface as on the tab "Resources".
var worker_manager: Node = null

# WorkerManager is passed from main_map through city_ui.set_worker_manager.
var cards: Dictionary = {}
# The cache of the current data of the cards: display_key -> { the nodes of the card, the row of the data }.
var _signature: String = ""
# The set of the displayed keys: the label for the comparison "the composition of the list has not changed".
var _quality_key: String = ""
# The active tooltip of the breakdown of the quality — for the update in real time.
var _hovered_tip: Control = null

# The node with a tooltip the cursor is currently over: we do not touch its text
# (see _apply_tooltip). A separate field, and not a check of the node: a Control in
# Godot 4 has no is_hovered() method, and the hover is most honestly tracked
# by the signals mouse_entered/mouse_exited.
const COLOR_TITLE := Color(1, 1, 1, 1)
const COLOR_CAPTION := Color(0.75, 0.75, 0.75, 1)
const COLOR_PRICE := Color(1.0, 0.507, 0.0, 1)
const COLOR_CONSUMPTION := Color(0.9, 0.3, 0.3, 1)
# The states of the colour/text of the card.
# the player sees "the price × the expense = these exact money" in one colour.
const COLOR_INCOME := Color(1.0, 0.807, 0.2, 1)
const COLOR_DISABLED := Color(0.62, 0.62, 0.62, 1)

func setup(list: Node, helpers: Node) -> void:
    internal_list = list
    ui_helpers = helpers

func set_worker_manager(wm: Node) -> void:
    worker_manager = wm

# A full rebuild of the list of the cards: the composition of the resources is determined by the current
# professions and the population, therefore it changes structurally (a worker
# has been assigned, a building has been built). It is called on opening the tab and on
# a divergence of the label of the composition (see update_values).
func refresh() -> void:
    if internal_list == null or not is_instance_valid(internal_list):
        return
    for child in internal_list.get_children():
        internal_list.remove_child(child)
        child.queue_free()
    cards.clear()
    _quality_key = ""
    _hovered_tip = null
    _signature = ""

    var data: Dictionary = _collect_data()
    # A full rebuild of the list of the cards: the composition of the resources is determined by the current
    # professions and the population, therefore it changes structurally (a worker
    # has been assigned, a building has been built). It is called on opening the tab and on
    # a divergence of the label of the composition (see update_values).
    var keys: Array = data.keys()
    keys.sort_custom(func(a, b): return str(data[a].get("name", a)) < str(data[b].get("name", b)))
    for key in keys:
        _create_card(str(key), data[key])
    # The label is set AFTER the assembly and by the same function as the check in
    # update_values. Previously refresh() glued the label from the sorted
    # keys, and update_values() compared it with the label in the order of the insertion
    # of the dictionary — the labels never matched, and EVERY TICK the list of the cards
    # was recreated entirely. Together with the cards the open tooltip died
    # and all the numbers flickered.
    _signature = _signature_of(data)
    if internal_list.get_child_count() == 0:
        var empty := Label.new()
        empty.text = tr("Nobody consumes anything yet")
        empty.add_theme_color_override("font_color", COLOR_CAPTION)
        internal_list.add_child(empty)

# The sorting by the name — the list is readable and predictable between the ticks.
func update_values() -> void:
    if internal_list == null or not is_instance_valid(internal_list):
        return
    var data: Dictionary = _collect_data()
    if _signature_of(data) != _signature:
        # The composition of the list has changed — a full rebuild is needed.
        refresh()
        return
    for key in cards:
        if data.has(key):
            _update_card(cards[key], data[key])

    # The label is set AFTER the assembly and by the same function as the check in
    # update_values. Previously refresh() glued the label from the sorted
    # keys, and update_values() compared it with the label in the order of the insertion
    # of the dictionary — the labels never matched, and EVERY TICK the list of the cards
    # was recreated entirely. Together with the cards the open tooltip died
    # and all the numbers flickered.
    # update_values() would count the different labels of one and the same composition.
func _signature_of(data: Dictionary) -> String:
    var keys: Array = data.keys()
    keys.sort()
    return ";".join(PackedStringArray(keys))

# Assigns the text to the Label, only if it CHANGES. The side effect
# of assigning the same text every time is an extra redrawing,
# and for a RichTextLabel (the quality label) also a reset of the position of the text.
func _set_text(node: Label, text: String) -> void:
    if node != null and is_instance_valid(node) and node.text != text:
        node.text = text

# Assigns the tooltip, only if it CHANGES. This is the key rule for
# the tooltips: Godot resets the showing of the tooltip on ANY assignment
# of tooltip_text, even if the string has not changed. Without the check the tooltip
# opened by the hover would close on every update of the screen.
func _set_tooltip(node: Control, text: String) -> void:
    if node != null and is_instance_valid(node) and node.tooltip_text != text:
        node.tooltip_text = text

# Puts the tooltip into the node, but does NOT touch the node under the cursor. The assignment
# of tooltip_text removes the already shown window (Control.set_tooltip removes
# the active tooltip), therefore we skip the hovered node: the player holds the cursor,
# waits for the update and must not see how the window blinks. Having moved the cursor away, the node
# will get the fresh text on the next update.
func _apply_tooltip(node: Control, text: String) -> void:
    if node == null or not is_instance_valid(node) or node == _hovered_tip:
        return
    _set_tooltip(node, text)

# The cursor is over a node with a tooltip. The signals come only when
# mouse_filter != IGNORE, that is, exactly at those nodes for which we want
# to show the tooltip.
func _on_tip_enter(node: Control) -> void:
    _hovered_tip = node

func _on_tip_exit(node: Control) -> void:
    if _hovered_tip == node:
        _hovered_tip = null

# The data of all the cards from worker_manager + the storage. It is formed anew on
# each update: it is cheap (a walk through the professions) and always actual.
func _collect_data() -> Dictionary:
    var result: Dictionary = {}
    if worker_manager == null or not is_instance_valid(worker_manager) \
            or not worker_manager.has_method("get_population_consumption_map"):
        return result
    result = worker_manager.get_population_consumption_map()
    # The plan of the income by the cards — it goes into the tooltip of the row "Income" ("how much
    # it would have brought, if the storage had not run out"). Both sources are counted ONCE
    # for everything: the methods inside walk the plan of the consumption, and calling them in
    # a loop over the cards is extra work.
    var income_map: Dictionary = {}
    if worker_manager.has_method("get_population_income_map"):
        income_map = worker_manager.get_population_income_map()
    # The plan of the income by the cards — it goes into the tooltip of the row "Income" ("how much
    # it would have brought, if the storage had not run out"). Both sources are counted ONCE
    # for everything: the methods inside walk the plan of the consumption, and calling them in
    # a loop over the cards is extra work.
    var actual_income_map: Dictionary = {}
    if worker_manager.has_method("get_actual_market_income_map"):
        actual_income_map = worker_manager.get_actual_market_income_map()
    # The fact over the display window (CityData.get_market_consumption_per_sec) —
    # a stable value instead of the tick counter, which goes out in
    # reset_counters() and on an interval of 2–5 sec was almost always empty.
    var fact_map: Dictionary = CityData.get_market_consumption_per_sec()
    for key in result:
        result[key]["stock"] = _collect_stock(result[key].get("members", []))
        result[key]["price_text"] = _format_price(result[key])
        result[key]["planned_income"] = income_map.get(str(key), {})
        result[key]["actual_income"] = actual_income_map.get(str(key), {})
        result[key]["actual"] = _collect_actual(result[key].get("members", []), fact_map)
    return result

    # The fact of the income — what the market has really brought over the window. Exactly this number
    # stands in the row "Income" and in the row "Treasury" of the top bar.
func _collect_stock(members: Array) -> Dictionary:
    var total := 0
    var quality: Dictionary = {}
    for pid in members:
        total += CityData.get_storage_amount(str(pid))
        var detail: Dictionary = CityData.get_quality_breakdown(str(pid))
        for qid in detail:
            quality[str(qid)] = int(quality.get(str(qid), 0)) + int(detail[qid])
    return {"total": total, "quality": quality}

# The actual consumption on the internal market over the display window, units/sec:
# the sum over the members of the group. fact_map is the common snapshot
# (CityData.get_market_consumption_per_sec), counted once for all
# the cards. The tick CityData.market_consumption_rates is not read here any more:
# it lives exactly one tick and on a display interval > 1 sec
# it manages to be zeroed out.
func _collect_actual(members: Array, fact_map: Dictionary) -> float:
    var total := 0.0
    for pid in members:
        total += float(fact_map.get(str(pid), 0.0))
    return total

    # The fact over the display window (CityData.get_market_consumption_per_sec) —
    # a stable value instead of the tick counter, which goes out in
    # reset_counters() and on an interval of 2–5 sec was almost always empty.
func _format_price(row: Dictionary) -> String:
    var members: Array = row.get("members", [])
    if not bool(row.get("is_group", false)):
        return str(CityData.get_internal_market_price(str(members[0]) if members.size() > 0 else ""))
    var min_price := -1
    var max_price := -1
    for pid in members:
        var price: int = CityData.get_internal_market_price(str(pid))
        if price <= 0:
            continue
        if min_price < 0 or price < min_price:
            min_price = price
        if price > max_price:
            max_price = price
    if min_price < 0:
        return "—"
    if min_price == max_price:
        return str(min_price)
    return "%d–%d" % [min_price, max_price]

# The stock of the resource in the storage: { "total": int, "quality": {qid: count} }.
# For a group it is summed over all the members — they are interchangeable, therefore
# the breakdown by quality is summed too (the levels of all the members are common).
func _format_quality(stock: Dictionary) -> String:
    var text := GameData.format_quality_share_text(stock.get("quality", {}))
    if text == "":
        return ""
    return "[color=#%s]★[/color] %s" % [
        UiHelpers.QUALITY_MARKER_COLOR.to_html(false), text]

# The actual consumption on the internal market over the display window, units/sec:
# the sum over the members of the group. fact_map is the common snapshot
# (CityData.get_market_consumption_per_sec), counted once for all
# the cards. The tick CityData.market_consumption_rates is not read here any more:
# it lives exactly one tick and on a display interval > 1 sec
# it manages to be zeroed out.
func _format_unit_rate(amount: int, interval: float) -> String:
    if amount <= 0:
        return tr("0/sec")
    if interval <= 0.0:
        return tr("%d units/sec") % amount
    if is_equal_approx(interval, round(interval)):
        return tr("%d units/%d sec") % [amount, int(round(interval))]
    return tr("%d units/%.1f sec") % [amount, interval]

# The text of the price of the product. A single resource — the price of the internal market for
# the ordinary quality (CityData.get_internal_market_price). A group — a range
# "min–max" over the members with a price: the members of a group have different prices, and one
# averaged number would be misleading. The details are in the tooltip.
func _format_rate(value: float) -> String:
    if is_equal_approx(value, roundf(value)):
        return str(int(roundf(value)))
    return "%.1f" % value

# The breakdown of the storage by quality on one line with the percentages in the colours of the levels —
# the same format as the quality label on the tab "Resources"
# (GameData.format_quality_share_text). The star-marker is painted with the same
# accent colour (ui_helpers.QUALITY_MARKER_COLOR): the white marker was read
# as "a quality level", although it is only the sign "there is a breakdown".
func _create_card(display_key: String, row: Dictionary) -> void:
    var card: PanelContainer = CARD_SCENE.instantiate()
    internal_list.add_child(card)
    var ctx := {
        "key": display_key,
        "card": card,
        "icon": card.get_node("Layout/Header/Icon"),
        "name": card.get_node("Layout/Header/NameLabel"),
        "priority_btn": card.get_node("Layout/Header/PriorityButton"),
        "checkbox": card.get_node("Layout/Header/TradeCheckBox"),
        "stock": card.get_node("Layout/StockRow/StockValue"),
        "quality": card.get_node("Layout/StockRow/QualityLabel"),
        "price": card.get_node("Layout/DetailRow/PriceValue"),
        "consumers": card.get_node("Layout/DetailRow/ConsumersValue"),
        "consumption": card.get_node("Layout/DetailRow/ConsumptionValue"),
        "income": card.get_node("Layout/IncomeRow/IncomeValue"),
    }
    cards[display_key] = ctx
    var icon: TextureRect = ctx["icon"]
    var texture := _get_icon_texture(str(row.get("icon", "")))
    if texture != null:
        icon.texture = texture
    else:
        # The rate of the consumption per ONE buyer in the original form from
        # data/consumption.json: "10 units/1 sec", "10 units/10 sec". It is not allowed to show
        # the recalculated "210/sec" — that is already the sum over the city, and the player
        # configures the consumption in the data per ONE citizen: exactly these numbers he
        # must see, in order to understand what will happen when the population grows.
        icon.hide()
    # The formatting of the rate: the integer values without a fractional part, the fractional ones — with
    # one digit (the same convention as in ui_helpers._format_rate).
    # it sees a jug for "Alcohol" and does not understand where it came from.
    if texture != null:
        _set_icon_tooltip(icon, row, display_key)
    # Hover over the breakdown of the quality — the same tooltip as on the tab
    # "Resources" (ui_helpers.show_quality_tooltip). The ordinary tooltip_text on the
    # label is NOT set: next to this tooltip it gave a second, empty one
    # ("Breakdown of the storage by quality"), and the player saw two windows at once.
    var quality: RichTextLabel = ctx["quality"]
    quality.mouse_entered.connect(_on_quality_hover.bind(display_key))
    quality.mouse_exited.connect(_on_quality_exit)
    # The tooltips of the price, of the buyers, of the expense and of the income — the ordinary ones (their styling is
    # done by the theme in theme/) and are filled in _update_card. We track the hover
    # only for the sake of _hovered_tip: the shown window must not be touched. These
    # four nodes in the scene must have mouse_filter = 0 (STOP) —
    # otherwise the signals of the hover will not come (see the header of the file).
    for node_key in ["price", "consumers", "consumption", "income"]:
     var tip_node: Control = ctx[node_key]
     tip_node.mouse_entered.connect(_on_tip_enter.bind(tip_node))
     tip_node.mouse_exited.connect(_on_tip_exit.bind(tip_node))
    # The priority of the consumption — the same cycle as at the quality button of a building.
    var priority_btn: Button = ctx["priority_btn"]
    priority_btn.pressed.connect(_on_priority_pressed.bind(display_key))
    # The toggle of the permission of the consumption on the internal market.
    var checkbox: CheckBox = ctx["checkbox"]
    checkbox.toggled.connect(_on_checkbox_toggled.bind(display_key))
    _update_card(ctx, row)

# The tooltip of the icon: for a group it explains the source of the picture, for a single
# resource — just the name of the file. The source is needed in order to distinguish "the own icon
# of the group" from "it was taken from the first product that has an icon".
func _set_icon_tooltip(icon: TextureRect, row: Dictionary, display_key: String) -> void:
    var icon_file := str(row.get("icon", ""))
    if not bool(row.get("is_group", false)):
        _set_tooltip(icon, tr("Icon: %s") % icon_file)
        return
    var info: Dictionary = GameData.get_product_group_icon_info(display_key)
    if bool(info.get("own", false)):
        _set_tooltip(icon, tr("Icon of group \"%s\": %s (set in data/product_groups.json)") % [
            _row_title(row, display_key), icon_file])
    else:
        var source_pid := str(info.get("source_pid", ""))
        var source_name := str(GameData.products.get(source_pid, {}).get("name", source_pid))
        _set_tooltip(icon, tr("Icon of group \"%s\" taken from goods \"%s\"") % [
            _row_title(row, display_key), source_name])

# Updates the values of an existing card (without recreating the nodes).
func _update_card(ctx: Dictionary, row: Dictionary) -> void:
    var display_key: String = str(ctx["key"])
    var enabled := bool(row.get("enabled", true))
    var title: String = str(row.get("name", display_key))
    if bool(row.get("is_group", false)):
        title += tr(" (group)")
    var name_label: Label = ctx["name"]
    _set_text(name_label, title)
    var stock: Dictionary = row.get("stock", {})
    var stock_label: Label = ctx["stock"]
    _set_text(stock_label, str(int(stock.get("total", 0))))
    var quality: RichTextLabel = ctx["quality"]
    var quality_text := _format_quality(stock)
    quality.text = quality_text
    quality.visible = quality_text != ""
    var price: Label = ctx["price"]
    _set_text(price, str(row.get("price_text", "—")))
    var consumers: Label = ctx["consumers"]
    _set_text(consumers, str(int(row.get("consumers_total", 0))))
    # The expense per 1: the rate of one buyer straight from data/consumption.json
    # ("10 units/1 sec"), and not the sum over the city. A forbidden resource has
    # no expense at all.
    var consumption: Label = ctx["consumption"]
    if not enabled:
        _set_text(consumption, "—")
    else:
        _set_text(consumption, _format_unit_rate(
            int(row.get("per_consumer_amount", 0)),
            float(row.get("per_consumer_interval", 0.0))))
    # The income: the FACT over the display window — so many coins per second the internal
    # market has really brought to the treasury. The same source of data as the row
    # "Treasury: N [+X≈]" in the top bar, therefore the sum of the rows "Income" equals
    # the actual market profit of the treasury. The plan "the whole demand × the price" does not
    # fit into the row: it is not limited by the storage, and with a half-empty storage the card
    # showed 2730 coins/sec, which never happened in the treasury. The plan has remained
    # in the tooltip of the row — that is where it belongs.
    var income: Label = ctx["income"]
    var fact_income: Dictionary = row.get("actual_income", {})
    if not enabled:
        _set_text(income, "—")
    else:
        _set_text(income, tr("%s/sec") % _format_rate(float(fact_income.get("coins_per_sec", 0.0))))
    # A light update: only the texts and the states of the buttons change, the nodes
    # of the cards are reused (otherwise the tooltips under the cursor would flicker).
    var card: PanelContainer = ctx["card"]
    card.modulate = Color(1, 1, 1, 1) if enabled else COLOR_DISABLED
    name_label.add_theme_color_override("font_color", COLOR_TITLE if enabled else COLOR_DISABLED)
    price.add_theme_color_override("font_color", COLOR_PRICE if enabled else COLOR_DISABLED)
    consumption.add_theme_color_override("font_color", COLOR_CONSUMPTION if enabled else COLOR_DISABLED)
    income.add_theme_color_override("font_color", COLOR_INCOME if enabled else COLOR_DISABLED)
    _update_priority_button(ctx["priority_btn"], str(row.get("priority", "best")))
    _update_toggle(ctx["checkbox"], enabled)
        # The composition of the list has changed — a full rebuild is needed.
    _apply_tooltip(price, _price_tooltip_text(row))
    _apply_tooltip(consumers, _consumers_tooltip_text(row))
    _apply_tooltip(consumption, _consumption_tooltip_text(row))
    _apply_tooltip(income, _income_tooltip_text(row))

# The text and the hint of the button of the priority. The indication is the same as in the window
# of the details of a building (building_panel._update_quality_button): the stars of the best
# level for "best", of the worst — for "worst", a die for "random".
func _update_priority_button(button: Button, priority: String) -> void:
    var levels: Array = GameData.get_quality_levels()
    if priority == "worst" and levels.size() > 0:
        button.text = GameData.get_quality_stars(levels.front())
    elif priority == "best" and levels.size() > 0:
        button.text = GameData.get_quality_stars(levels.back())
    elif priority == "random":
        button.text = "🎲"
    else:
        button.text = "★"
    # The label of the composition of the list of the cards. It is assembled from the SORTED keys, and
    # therefore does not depend on the order of the walk of the dictionary: otherwise refresh() and
    _set_tooltip(button, tr("Consumption priority: %s (click to switch)") \
        % GameData.get_quality_priority_name(priority))

# Synchronises the toggle with the state of the market. The check of the change of the value
# is obligatory: a programmatic setting of button_pressed calls the signal toggled
# and would loop the edit, and without the check Godot would also redraw the button
# on every update of the screen.
func _update_toggle(checkbox: CheckBox, enabled: bool) -> void:
    if checkbox != null and is_instance_valid(checkbox) \
            and checkbox.button_pressed != enabled:
        checkbox.button_pressed = enabled

# --- THE TOGGLE OF THE PERMISSION OF THE CONSUMPTION ---
# One CheckBox (previously there were two variant-buttons: ColorRect and CheckBox).

# The toggle writes the state into CityData and immediately updates the card.
func _on_checkbox_toggled(pressed: bool, display_key: String) -> void:
    _set_enabled(display_key, pressed)

# The common toggle: we write the state into CityData and update the card.
func _set_enabled(display_key: String, enabled: bool) -> void:
    CityData.set_market_consumption_enabled(display_key, enabled)
    if not cards.has(display_key):
        return
    var ctx: Dictionary = cards[display_key]
    _update_toggle(ctx["checkbox"], enabled)
    # The click on the checkbox.
    var data: Dictionary = _collect_data()
    if data.has(display_key):
        _update_card(ctx, data[display_key])

# --- THE BUTTON OF THE PRIORITY OF THE CONSUMPTION ---
# The cycle best → worst → random → best (the order from data/qualities.json).
func _on_priority_pressed(display_key: String) -> void:
    var priority := CityData.cycle_consumption_priority(display_key)
    if not cards.has(display_key):
        return
    var ctx: Dictionary = cards[display_key]
    _update_priority_button(ctx["priority_btn"], priority)
    var row: Dictionary = _collect_data().get(display_key, {})
    _show_message(tr("%s: consumption priority — %s") % [
        _row_title(row, display_key), GameData.get_quality_priority_name(priority)])

# The common toggle: we write the state into CityData and update the card.
func _row_title(row: Dictionary, display_key: String) -> String:
    var title := str(row.get("name", display_key))
    if bool(row.get("is_group", false)):
        title += tr(" (group)")
    return title

    # The expense and the dimming are counted from the data — we update the card entirely.
func _on_quality_hover(display_key: String) -> void:
    _quality_key = display_key
    var row: Dictionary = _row_data(display_key)
    if row.is_empty() or ui_helpers == null or not is_instance_valid(ui_helpers):
        return
    var quality: Dictionary = row.get("stock", {}).get("quality", {})
    if quality.is_empty():
        return
    ui_helpers.show_quality_tooltip(
        get_viewport().get_mouse_position(),
        _row_title(row, display_key), quality)

func _on_quality_exit() -> void:
    _quality_key = ""
    if ui_helpers != null and is_instance_valid(ui_helpers):
        ui_helpers.hide_quality_tooltip()

# --- THE BUTTON OF THE PRIORITY OF THE CONSUMPTION ---
# The cycle best → worst → random → best (the order from data/qualities.json).
# The heading of the card for the messages (with the mark of the group, as in the card itself).
func _price_ladder_inline(member: String) -> String:
    var parts: Array = []
    for qid in GameData.get_quality_levels():
        var breakdown := GameData.get_price_breakdown_for_quality(member, str(qid))
        var total := int(breakdown.get("total", 0))
        if total > 0:
            parts.append(str(total))
    return " / ".join(parts)

# --- THE TOOLTIPS ---
# The breakdown of the storage by quality — the same tooltip as at the quality label on the
# tab "Resources" (ui_helpers.show_quality_tooltip). For a group
# the combined breakdown over all the members is shown.
# Previously the tooltip showed only the ladder of prices by the levels which LIE in the
# storage, which is why on an empty storage it was empty altogether, and the formula of the price
# remained a riddle. Now first comes the explanation, then the ladder by ALL
# the levels of the scale with a mark of the quantity in the storage, and as a separate row — that
# the presence of the goods does not change the price (the price per unit ≠ the revenue).
func _price_tooltip_text(row: Dictionary) -> String:
    if row.is_empty():
        return ""
    var lines: Array = []
    var market_mult := float(GameData.game_balance.get("internal_market_price_multiplier", 1.0))
    lines.append(tr("Price = base price of the goods ×%.2f (market) × quality multiplier") % market_mult)
    lines.append("")
    for pid in row.get("members", []):
        var member := str(pid)
        var member_name: String = str(GameData.products.get(member, {}).get("name", member))
        var base_price: float = GameData.get_base_price(member)
        if base_price <= 0.0:
            lines.append(tr("%s: goods without a price") % member_name)
            continue
        var stock_detail: Dictionary = CityData.get_quality_breakdown(member)
        var stock_total := 0
        for qid in stock_detail:
            stock_total += int(stock_detail[qid])
        # The full ladder — only for the goods which LIE in the storage: it is
        # the only one that is really sold. The other members of the group are one
        # row. Without this the tooltip of a group of 13 goods stretched over
        # half a screen, and the needed row drowned in the common list.
        if stock_total <= 0:
            lines.append(tr("%s (base %d): %s") % [
                member_name, int(round(base_price)), _price_ladder_inline(member)])
            continue
        lines.append(tr("%s (base %d):") % [member_name, int(round(base_price))])
        for qid in GameData.get_quality_levels():
            var tail := GameData.format_quality_price_tail(member, str(qid))
            if tail == "":
                continue
            var stars := GameData.get_quality_stars(str(qid))
            var in_stock := int(stock_detail.get(str(qid), 0))
            # The quantity in the storage is appended only when the level really
            # lies: otherwise every row of the ladder would carry a "0" and the tooltip
            # would turn into a table of zeros.
            var suffix := tr(" — in storage: %d") % in_stock if in_stock > 0 else ""
            lines.append("  %s%s%s" % [stars, tail, suffix])
    lines.append("")
    if bool(row.get("is_group", false)):
        lines.append(tr("A range is shown because the goods in the group have different base prices."))
    lines.append(tr("Price per unit: having it in storage does not change it. Storage affects income (the \"Income\" row)."))
    return "\n".join(lines)

# The buyers: who exactly buys the resource and in what quantity.
# The format "Fisherman: 1", "All citizens: 21" — exactly what the player is looking for, moving the mouse over
# "Buyers: N": not the rate of the consumption, but the COMPOSITION of the buyers. The names
# are taken from data/professions.json, therefore the pseudo-profession "All citizens"
# looks the same as in the rest of the interface.
func _consumers_tooltip_text(row: Dictionary) -> String:
    if row.is_empty():
        return ""
    var lines: Array = [tr("Buyers of the resource:")]
    var sources: Dictionary = row.get("sources", {})
    var entries: Array = []
    for source_id in sources:
        var entry: Dictionary = sources[source_id]
        entries.append({"name": GameData.get_source_display_name(str(source_id)), "count": int(entry.get("count", 0))})
    # By the descending number of the buyers: the main buyer goes on the first row.
    entries.sort_custom(func(a, b): return int(a["count"]) > int(b["count"]))
    for item in entries:
        lines.append("%s: %d" % [str(item["name"]), int(item["count"])])
    if lines.size() <= 1:
        return ""
    return "\n".join(lines)

# The expense: the rate per one buyer + how many times it is multiplied by
# the actual number of the buyers + the fact over the display window.
func _consumption_tooltip_text(row: Dictionary) -> String:
    if row.is_empty():
        return ""
    var lines: Array = [tr("Expenses by buyers:")]
    var sources: Dictionary = row.get("sources", {})
    for source_id in sources:
        var entry: Dictionary = sources[source_id]
        var count := int(entry.get("count", 0))
        var amount := int(entry.get("unit_amount", 0))
        var interval := float(entry.get("interval", 0))
        if amount <= 0 or count <= 0:
            continue
        # "the rate × the number of the buyers = the total": in this way one sees both one's own number from
        # the data, and the total over the city, without two identical "10 units/1 sec" in a row.
        lines.append(tr("%s: %d units every %s per person × %d = %d per cycle") % [
            GameData.get_source_display_name(str(source_id)), amount,
            (tr("%d sec") % int(round(interval))) if interval > 0.0 else tr("sec"),
            count, amount * count])
    var plan_per_sec := float(row.get("per_sec", 0.0))
    if plan_per_sec > 0.0:
        lines.append("")
        lines.append(tr("City total (plan): %s units/sec") % _format_rate(plan_per_sec))
    var fact := float(row.get("actual", 0.0))
    if fact > 0.0:
        lines.append(tr("Actual over the window: %s units/sec — that is what was really bought") % _format_rate(fact))
    if lines.size() <= 1:
        return ""
    return "\n".join(lines)

# The income to the treasury. The breakdown into TWO numbers, because they answer different
# questions, and previously they could be confused:
#   * the FACT — what the market has brought over the display window. Exactly this stands in
#     the row "Income" and in the row "Treasury: N [+X≈]", and exactly this gets
#     into the treasury for real.
#   * the PLAN — "how much it would have brought, if the whole demand could be sold".
#     It is not limited by the storage: 21 citizens × 10 units/sec × 13 coins gave
#     2730 coins/sec, although only 10 units lay in the storage. As a characteristic
#     of the demand potential it is useful, as an "income" — it is a deception.
func _income_tooltip_text(row: Dictionary) -> String:
    if row.is_empty():
        return ""
    if not bool(row.get("enabled", true)):
        return tr("Consumption on the domestic market is disabled — no income.")
    var fact_row: Dictionary = row.get("actual_income", {})
    var plan_row: Dictionary = row.get("planned_income", {})
    var fact := float(fact_row.get("coins_per_sec", 0.0))
    var plan := float(plan_row.get("coins_per_sec", 0.0))
    var per_sec := float(row.get("per_sec", 0.0))
    if fact <= 0.0 and plan <= 0.0 and per_sec <= 0.0:
        return ""
    # The length of the window in the first row: by it the player can cross-check the fact with the row
    # "Treasury: N [+X≈]" — it is also counted over this window.
    var lines: Array = [tr("Income to the treasury over %s sec: %s coins/sec") % [
        _format_rate(CityData.treasury_window_length_sec), _format_rate(fact)]]
    if plan > 0.0:
        lines.append(tr("Plan: demand %s units/sec × price %s = %s coins/sec") % [
            _format_rate(per_sec), str(row.get("price_text", "—")), _format_rate(plan)])
    # A zero fact with a non-zero demand is not an error, but a lack of goods:
    # there is nothing to sell. Without this row the player sees "0" and thinks that the
    # calculation is broken.
    if fact <= 0.0 and per_sec > 0.0:
        lines.append(tr("As long as the group has no goods in storage there is nothing to buy — no income."))
    elif fact > 0.0 and plan > fact * 1.5:
        lines.append(tr("Actual is below plan: buyers want more than what is in storage."))
    var by_source: Dictionary = fact_row.get("by_source", {})
    if by_source.size() > 0:
        lines.append("")
        lines.append(tr("By buyers (actual):"))
        var names: Array = by_source.keys()
        names.sort()
        for source_name in names:
            lines.append(tr("%s: %s coins/sec") % [
                str(source_name), _format_rate(float(by_source[source_name]))])
    return "\n".join(lines)

# Updates the open tooltip of the breakdown of the quality with the fresh data. It is called from
# city_ui on a change of the era of the display of the resources, while the cursor is on the label:
# the tooltip stays in place (the coordinates are taken from the mouse) and does not blink, but
# shows the actual storage.
func refresh_open_tooltip() -> void:
    if _quality_key.is_empty() or ui_helpers == null or not is_instance_valid(ui_helpers):
        return
    if ui_helpers.quality_tooltip_panel == null or not ui_helpers.quality_tooltip_panel.visible:
        return
    var row: Dictionary = _row_data(_quality_key)
    if row.is_empty():
        return
    var quality: Dictionary = row.get("stock", {}).get("quality", {})
    if quality.is_empty():
        return
    ui_helpers.show_quality_tooltip(
        get_viewport().get_mouse_position(),
        _row_title(row, _quality_key), quality)

# The row of the data of the card by the key (or an empty dictionary, if there is no card).
func _row_data(display_key: String) -> Dictionary:
    return _collect_data().get(display_key, {})

# A message to the bottom panel of the city (ui_helpers.set_message).
func _show_message(text: String) -> void:
    if ui_helpers != null and is_instance_valid(ui_helpers):
        ui_helpers.set_message(text)

# --- THE ICONS ---
# The icons are taken from the common registry IconRegistry (autoload): the index of the file names
# and the cache of the textures there are common for the whole project, therefore the tab "Trade"
# does not need its own walk of res://icons and its own cache.

func _get_icon_texture(icon_file: String) -> Texture2D:
    return IconRegistry.get_texture(icon_file)
